import Darwin
import Foundation

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
