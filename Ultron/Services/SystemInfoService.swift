import Darwin
import Foundation
import IOKit
import IOKit.ps
#if canImport(IOBluetooth)
import IOBluetooth
#endif

/// A snapshot of everything system-info panel shows in Info mode. Values are optional
/// so a slow/failed probe doesn't take the whole panel down with it.
struct SystemInfoSnapshot: Equatable {
    var batteryPercent: Int?
    var batteryState: String?         // "charging", "discharging", "charged"
    var batteryTimeRemaining: String? // "5:23" or "beregner" or nil
    var osVersion: String?            // "macOS 15.2 (24C101)"
    var hostname: String?             // local hostname
    var localIP: String?              // primary IPv4
    var ramTotalGB: Double?
    var ramUsedGB: Double?
    var dnsServers: [String] = []     // primary resolvers
    var hostinfo: String?             // raw /usr/bin/hostinfo output
    var hardwareSummary: String?      // abbreviated system_profiler output
    var wifi: WiFiInfo?               // current WiFi SSID + signal, if available

    /// Produced by the optional manual buttons.
    var speedtestSummary: String?     // e.g. "↓ 485 Mb/s, ↑ 42 Mb/s, idle 12 ms"
    var networkScan: [NetworkDevice] = []

    // MARK: - Live performance / handling metrics
    //
    // These are populated by `SystemInfoService.fetchLiveMetrics()` on a fast
    // (~10 s) cadence so the Cockpit Ydelse + Handlinger sub-tiles can render
    // real-time values without waiting for the slow `fetchBasics()` pass.
    // All optional / defaulted so a failed probe never blanks the whole tile.

    /// 0.0–1.0. Requires two samples of host CPU load ticks, so the first probe
    /// after launch will return nil. Subsequent probes are deltas.
    var cpuLoadPercent: Double?
    /// Battery discharge rate in watts. nil when plugged in / not discharging
    /// or when IOKit doesn't surface a readable `InstantAmperage`.
    var powerDrawWatts: Double?
    /// `.nominal` / `.fair` / `.serious` / `.critical`. Pulled from
    /// `ProcessInfo.thermalState` which reflects macOS thermal pressure.
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// Cumulative bytes received on the primary WiFi interface (en0) since
    /// boot. Caller is expected to compute deltas for a per-interval rate.
    var wifiBytesReceived: UInt64?
    /// Cumulative bytes sent on en0 since boot.
    var wifiBytesSent: UInt64?
    /// Whether the system Bluetooth controller is powered on.
    var bluetoothPoweredOn: Bool = false
    /// Display names of currently-connected paired Bluetooth devices.
    var bluetoothConnectedDevices: [String] = []
}

struct WiFiInfo: Equatable {
    let ssid: String?
    let rssi: Int?           // dBm, typically -30 (excellent) to -90 (poor)
    let transmitRate: Double? // Mbps

    var qualityLabel: String {
        guard let rssi else { return "ukendt" }
        if rssi >= -55 { return "fremragende" }
        if rssi >= -65 { return "god" }
        if rssi >= -75 { return "okay" }
        return "svag"
    }
}

struct NetworkDevice: Identifiable, Equatable {
    var id: String { ip }
    let ip: String
    let mac: String
    let name: String?
}

/// Runs the lightweight system probes in parallel and exposes heavier ones as
/// explicit `run...` methods called by UI buttons.
actor SystemInfoService {
    /// Last `host_statistics64(HOST_CPU_LOAD_INFO)` reading. CPU load is the
    /// delta of user+system+nice ticks divided by total ticks between two
    /// samples, so we keep the previous sample on the actor between calls.
    private var previousCPULoad: host_cpu_load_info?

    func fetchBasics() async -> SystemInfoSnapshot {
        async let battery = probeBattery()
        async let osVer   = probeOSVersion()
        async let host    = probeHostname()
        async let ip      = probeLocalIP()
        async let ram     = probeRAM()
        async let dns     = probeDNS()
        async let hi      = probeHostinfo()
        async let hw      = probeHardware()

        var snap = SystemInfoSnapshot()
        let (bat, os, h, i, r, d, hinfo, hware) = await (battery, osVer, host, ip, ram, dns, hi, hw)
        snap.batteryPercent = bat.percent
        snap.batteryState = bat.state
        snap.batteryTimeRemaining = bat.timeRemaining
        snap.osVersion = os
        snap.hostname = h
        snap.localIP = i
        snap.ramTotalGB = r.total
        snap.ramUsedGB = r.used
        snap.dnsServers = d
        snap.hostinfo = hinfo
        snap.hardwareSummary = hware
        snap.wifi = WiFiInfoService.current()
        return snap
    }

    /// Run the built-in `networkQuality` tool. Slow (~15-25s). Caller must await.
    func runSpeedtest() async -> String? {
        let output = await Self.shell(path: "/usr/bin/networkQuality", args: ["-s"])
        return output?
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.contains("==") }
            .joined(separator: " · ")
    }

    /// Parse `arp -an` into a list of IP + MAC pairs for devices on the local network.
    func runNetworkScan() async -> [NetworkDevice] {
        guard let output = await Self.shell(path: "/usr/sbin/arp", args: ["-an"]) else { return [] }
        var devices: [NetworkDevice] = []
        for line in output.components(separatedBy: .newlines) {
            // Format: "? (192.168.1.1) at xx:xx:xx:xx:xx:xx on en0 ifscope [ethernet]"
            guard line.contains("at ") else { continue }
            let openParen = line.firstIndex(of: "(")
            let closeParen = line.firstIndex(of: ")")
            guard let openParen, let closeParen else { continue }
            let ip = String(line[line.index(after: openParen)..<closeParen])
            guard let atIndex = line.range(of: " at ")?.upperBound else { continue }
            let mac = String(line[atIndex...]).prefix(while: { $0 != " " })
            guard !mac.contains("incomplete") else { continue }
            devices.append(NetworkDevice(ip: ip, mac: String(mac), name: nil))
        }
        return devices
    }

    /// Reverse-DNS lookup for an IP, used by the "DNS reverse"-button in Info mode.
    func reverseDNS(for ip: String) async -> String? {
        let output = await Self.shell(path: "/usr/bin/dig", args: ["-x", ip, "+short"])
        let lines = output?.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        return lines.first
    }

    // MARK: - Live metrics (fast probe, 10-s cadence)

    /// Fast probe of the performance-oriented fields only. Called on a 10-s
    /// timer from the Cockpit so CPU / power / bytes update live while the
    /// slower `fetchBasics()` runs on the panel refresh cadence.
    ///
    /// Returns a snapshot where ONLY the live-metric fields are populated;
    /// other fields left at their default/nil values. Callers merge this into
    /// the main snapshot rather than replacing it outright.
    func fetchLiveMetrics() async -> SystemInfoSnapshot {
        var snap = SystemInfoSnapshot()

        snap.cpuLoadPercent = probeCPULoad()
        snap.powerDrawWatts = probePowerDraw()
        snap.thermalState = ProcessInfo.processInfo.thermalState

        let (rx, tx) = probeWiFiBytes()
        snap.wifiBytesReceived = rx
        snap.wifiBytesSent = tx

        let bt = await probeBluetooth()
        snap.bluetoothPoweredOn = bt.poweredOn
        snap.bluetoothConnectedDevices = bt.devices

        return snap
    }

    // MARK: - Individual probes

    private func probeBattery() async -> (percent: Int?, state: String?, timeRemaining: String?) {
        guard let out = await Self.shell(path: "/usr/bin/pmset", args: ["-g", "batt"]) else {
            return (nil, nil, nil)
        }
        // Sample:
        //  "Now drawing from 'AC Power'"
        //  " -InternalBattery-0 (id=0)	87%; charging; 0:45 remaining present: true"
        var percent: Int?
        var state: String?
        var remaining: String?
        for line in out.components(separatedBy: .newlines) {
            if let match = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                percent = Int(line[match].dropLast())
            }
            let lower = line.lowercased()
            if lower.contains("discharging") { state = "Afladning" }
            else if lower.contains("charging") { state = "Oplader" }
            else if lower.contains("charged") { state = "Fuldt opladt" }
            else if lower.contains("ac attached") || lower.contains("ac power") { state = state ?? "Tilsluttet" }

            if let match = line.range(of: #"(\d+:\d+)"#, options: .regularExpression) {
                let value = String(line[match])
                // Only treat as "time remaining" when preceded by a state verb
                if lower.contains("discharg") || lower.contains("charg") {
                    remaining = value
                }
            }
            if lower.contains("no estimate") { remaining = "beregner…" }
            if lower.contains("not charging") { state = "Tilsluttet, oplader ikke" }
        }
        return (percent, state, remaining)
    }

    private func probeOSVersion() async -> String? {
        let name = await Self.shell(path: "/usr/bin/sw_vers", args: ["-productName"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "macOS"
        let ver  = await Self.shell(path: "/usr/bin/sw_vers", args: ["-productVersion"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = await Self.shell(path: "/usr/bin/sw_vers", args: ["-buildVersion"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(name) \(ver) (\(build))"
    }

    private func probeHostname() async -> String? {
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private func probeLocalIP() async -> String? {
        // Prefer ipconfig's primary-interface value — works whether Wi-Fi or Ethernet is active.
        if let primary = await Self.shell(path: "/usr/sbin/ipconfig", args: ["getifaddr", "en0"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !primary.isEmpty {
            return primary
        }
        if let fallback = await Self.shell(path: "/usr/sbin/ipconfig", args: ["getifaddr", "en1"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private func probeRAM() async -> (total: Double?, used: Double?) {
        // Total RAM in bytes via sysctl.
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        let totalGB = Double(size) / 1_073_741_824

        // Used = total − free, where "free" is free + inactive from vm_stat.
        guard let vmstat = await Self.shell(path: "/usr/bin/vm_stat", args: []) else {
            return (totalGB, nil)
        }
        var freePages: Double = 0
        var inactivePages: Double = 0
        var pageSize: Double = 4096
        if let m = vmstat.range(of: #"page size of (\d+)"#, options: .regularExpression) {
            let parsed = vmstat[m]
                .components(separatedBy: .whitespaces)
                .compactMap { Double($0) }
                .last
            if let parsed {
                pageSize = parsed
            }
        }
        for line in vmstat.components(separatedBy: .newlines) {
            if line.hasPrefix("Pages free:"),
               let n = Double(line.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).joined()) {
                freePages = n
            } else if line.hasPrefix("Pages inactive:"),
                      let n = Double(line.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).joined()) {
                inactivePages = n
            }
        }
        let freeGB = ((freePages + inactivePages) * pageSize) / 1_073_741_824
        let usedGB = max(0, totalGB - freeGB)
        return (totalGB, usedGB)
    }

    private func probeDNS() async -> [String] {
        guard let out = await Self.shell(path: "/usr/sbin/scutil", args: ["--dns"]) else { return [] }
        var servers: [String] = []
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Lines look like "nameserver[0] : 192.168.1.1"
            if trimmed.hasPrefix("nameserver["), let colon = trimmed.firstIndex(of: ":") {
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !servers.contains(value) {
                    servers.append(value)
                }
            }
        }
        return servers
    }

    private func probeHostinfo() async -> String? {
        let out = await Self.shell(path: "/usr/bin/hostinfo", args: [])
        return out?.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "\n")
    }

    private func probeHardware() async -> String? {
        let out = await Self.shell(path: "/usr/sbin/system_profiler", args: ["SPHardwareDataType", "-detailLevel", "mini"])
        guard let out else { return nil }
        // Keep just the model + chip lines to avoid flooding the UI.
        let wanted = ["Model Name:", "Model Identifier:", "Chip:", "Total Number of Cores:", "Memory:"]
        return out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in wanted.contains(where: { line.hasPrefix($0) }) }
            .joined(separator: "\n")
    }

    // MARK: - Live-metric probes

    /// Compute the CPU load as (user+system+nice)/(total) between the last
    /// call and now. Returns nil on the very first call (no baseline yet)
    /// and on `host_statistics64` failure.
    private func probeCPULoad() -> Double? {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let kerr = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }

        defer { previousCPULoad = cpuInfo }
        guard let previous = previousCPULoad else { return nil }

        // CPU_STATE_USER / SYSTEM / IDLE / NICE ticks are a rolling counter.
        // Compute deltas and divide active by total.
        let user = Double(cpuInfo.cpu_ticks.0) - Double(previous.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1) - Double(previous.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2) - Double(previous.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3) - Double(previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let active = user + system + nice
        return max(0, min(1, active / total))
    }

    /// Read battery current + voltage from IOKit's `AppleSmartBattery` node
    /// and return instantaneous discharge power in watts. nil when plugged
    /// in, fully charged, or IOKit doesn't report a usable reading.
    private func probePowerDraw() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard
            let amperageRef = IORegistryEntryCreateCFProperty(
                service,
                "InstantAmperage" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue(),
            let voltageRef = IORegistryEntryCreateCFProperty(
                service,
                "Voltage" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else { return nil }

        // Values come back as CFNumber. Use NSNumber bridging to stay
        // Swift 5 friendly while preserving sign on amperage.
        guard
            let amperage = (amperageRef as? NSNumber)?.doubleValue,
            let voltage = (voltageRef as? NSNumber)?.doubleValue
        else { return nil }

        // Negative amperage means discharging. Zero or positive means we're
        // not pulling from the battery — surface nil so the UI can say "—".
        guard amperage < 0 else { return nil }
        let watts = abs(amperage) * voltage / 1_000_000 // mA * mV / 1e6
        return watts
    }

    /// Sum of cumulative `ifi_ibytes` / `ifi_obytes` counters on the primary
    /// WiFi interface (en0). Returns (nil, nil) when getifaddrs fails or
    /// en0 is absent.
    private func probeWiFiBytes() -> (UInt64?, UInt64?) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return (nil, nil)
        }
        defer { freeifaddrs(ifaddrPtr) }

        var rx: UInt64?
        var tx: UInt64?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let name = String(cString: current.pointee.ifa_name)
            let family = current.pointee.ifa_addr?.pointee.sa_family
            // AF_LINK entries carry the if_data counters; the AF_INET entry
            // for the same interface has only the IP address.
            if name.hasPrefix("en0"),
               family == UInt8(AF_LINK),
               let dataRaw = current.pointee.ifa_data {
                let data = dataRaw.assumingMemoryBound(to: if_data.self).pointee
                rx = UInt64(data.ifi_ibytes)
                tx = UInt64(data.ifi_obytes)
                break
            }
            cursor = current.pointee.ifa_next
        }
        return (rx, tx)
    }

    /// Ask IOBluetooth for controller state + list of currently connected
    /// paired devices. The IOBluetooth APIs touch AppKit-ish state so we
    /// hop to the main actor. Compiled out entirely when the framework
    /// isn't available (e.g. a stripped-down sandboxed build target).
    private func probeBluetooth() async -> (poweredOn: Bool, devices: [String]) {
        #if canImport(IOBluetooth)
        return await MainActor.run {
            let powered = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
            let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            let connected = paired
                .filter { $0.isConnected() }
                .map { $0.name ?? "ukendt" }
            return (powered, connected)
        }
        #else
        return (false, [])
        #endif
    }

    // MARK: - Shell helper

    private static func shell(path: String, args: [String]) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
