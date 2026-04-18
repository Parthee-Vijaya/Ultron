import AppKit
import SwiftUI

struct InfoModeView: View {
    @Bindable var service: InfoModeService
    let onClose: () -> Void

    @AppStorage(Constants.Defaults.claudeDailyLimitTokens)
    private var claudeDailyLimit: Int = Constants.ClaudeStats.defaultDailyLimit
    @AppStorage(Constants.Defaults.claudeWeeklyLimitTokens)
    private var claudeWeeklyLimit: Int = Constants.ClaudeStats.defaultWeeklyLimit

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(JarvisTheme.neonCyan.opacity(0.2))
            VStack(spacing: 12) {
                tilesRow
                claudeStatsTile
                systemTile
                networkActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .task { await service.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(JarvisTheme.neonCyan)
                .shadow(color: JarvisTheme.neonCyan.opacity(0.7), radius: 4)
            Text("Info")
                .font(.headline)
                .foregroundStyle(JarvisTheme.brightCyan)
            if let last = service.lastRefresh {
                Text("· opdateret \(timeAgo(last))")
                    .font(.caption2)
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
            }
            Spacer()
            Button {
                Task { await service.refresh(force: true) }
            } label: {
                Image(systemName: service.state == .loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Opdater")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tiles row (weather + news + commute)

    private var tilesRow: some View {
        HStack(alignment: .top, spacing: 12) {
            weatherTile
            sunTile
            newsTile
        }
    }

    private var sunTile: some View {
        tile(title: "Sol", icon: "sun.horizon.fill") {
            if let sun = service.weather?.todaySun {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "sunrise.fill")
                            .foregroundStyle(JarvisTheme.brightCyan)
                        Text(Self.hourMinute.string(from: sun.sunrise))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "sunset.fill")
                            .foregroundStyle(JarvisTheme.neonCyan)
                        Text(Self.hourMinute.string(from: sun.sunset))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    if let daylight = service.weather?.daily.first?.daylight {
                        Text("Dagslys \(Self.prettyDaylight(daylight))")
                            .font(.caption2)
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.6))
                            .padding(.top, 2)
                    }
                }
            } else {
                placeholder("Henter sol…")
            }
        }
    }

    private static let hourMinute: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        df.locale = Locale(identifier: "da_DK")
        return df
    }()

    private static func prettyDaylight(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return "\(hours)t \(minutes) min"
    }

    private var weatherTile: some View {
        tile(title: "Vejr", icon: "cloud.sun.fill") {
            if let weather = service.weather {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: WeatherCode.symbol(for: weather.current.weatherCode))
                        .font(.system(size: 30))
                        .foregroundStyle(JarvisTheme.brightCyan)
                        .shadow(color: JarvisTheme.neonCyan.opacity(0.6), radius: 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(weather.current.temperature.rounded()))°")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(weather.locationLabel)
                            .font(.caption).foregroundStyle(JarvisTheme.neonCyan.opacity(0.7))
                        Text(WeatherCode.label(for: weather.current.weatherCode))
                            .font(.caption2).foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                }
            } else {
                placeholder("Henter vejr…")
            }
        }
    }

    @State private var newsSource: NewsHeadline.Source = .dr

    private var newsTile: some View {
        tile(title: "Nyheder", icon: "newspaper.fill") {
            if service.newsBySource.values.allSatisfy({ $0.isEmpty }) {
                placeholder("Henter nyheder…")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Kilde", selection: $newsSource) {
                        ForEach(NewsHeadline.Source.allCases) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()

                    let items = service.newsBySource[newsSource] ?? []
                    if items.isEmpty {
                        Text("Ingen nyheder lige nu")
                            .font(.caption2)
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items.prefix(3)) { item in
                                Button {
                                    if let url = item.link { NSWorkspace.shared.open(url) }
                                } label: {
                                    HStack(alignment: .top, spacing: 6) {
                                        Circle()
                                            .fill(JarvisTheme.neonCyan.opacity(0.6))
                                            .frame(width: 4, height: 4).padding(.top, 5)
                                        Text(item.title)
                                            .font(.caption).foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading).lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var commuteTile: some View {
        tile(title: "Hjem", icon: "house.fill") {
            if let commute = service.commute {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(commute.prettyTravelTime)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("til \(commute.toLabel)")
                            .font(.caption).foregroundStyle(JarvisTheme.neonCyan.opacity(0.65))
                    }
                    Text(commute.prettyDistance)
                        .font(.caption).foregroundStyle(JarvisTheme.neonCyan.opacity(0.7))
                    if commute.baselineTravelTime != nil {
                        HStack(spacing: 4) {
                            Image(systemName: trafficIcon(commute.trafficCondition))
                                .font(.caption2).foregroundStyle(trafficColor(commute.trafficCondition))
                            Text("\(commute.trafficCondition.label) · \(commute.prettyTrafficDelay)")
                                .font(.caption2).foregroundStyle(trafficColor(commute.trafficCondition))
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.car.fill")
                            .font(.caption2).foregroundStyle(JarvisTheme.brightCyan)
                        Text(String(format: "Tesla ~%.1f kWh", commute.teslaKWh))
                            .font(.caption2).foregroundStyle(JarvisTheme.brightCyan)
                    }
                }
            } else if let error = service.commuteError {
                Text(error)
                    .font(.caption2).foregroundStyle(JarvisTheme.neonCyan.opacity(0.65))
                    .multilineTextAlignment(.leading)
            } else {
                placeholder("Beregner rute…")
            }
        }
    }

    private func trafficIcon(_ condition: CommuteEstimate.TrafficCondition) -> String {
        switch condition {
        case .free:    return "checkmark.circle.fill"
        case .light:   return "car.fill"
        case .heavy:   return "exclamationmark.triangle.fill"
        case .severe:  return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func trafficColor(_ condition: CommuteEstimate.TrafficCondition) -> Color {
        switch condition {
        case .free:    return JarvisTheme.brightCyan
        case .light:   return JarvisTheme.neonCyan
        case .heavy:   return JarvisTheme.warningGlow
        case .severe:  return JarvisTheme.criticalGlow
        case .unknown: return JarvisTheme.neonCyan.opacity(0.5)
        }
    }

    // MARK: - Claude Code tile

    private var claudeStatsTile: some View {
        let s = service.claudeStats
        return tile(title: "Claude Code", icon: "sparkles", fullWidth: true) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("I dag", value: todayLine)
                    infoRow("I alt", value: "\(formatTokens(s.totalTokens)) · \(s.totalSessions) sessioner")
                    infoRow("Kørt", value: formatHours(s.totalActiveHours))
                    if let first = s.firstSessionDate {
                        infoRow("Siden", value: firstSessionFormatter.string(from: first))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("Seneste", value: latestSessionLine)
                    infoRow("Daily", value: budgetRow(used: s.todayTokens, limit: claudeDailyLimit))
                    infoRow("Weekly", value: budgetRow(used: s.weekTokens, limit: claudeWeeklyLimit))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                budgetBar(label: "I dag", used: s.todayTokens, limit: claudeDailyLimit)
                budgetBar(label: "Denne uge", used: s.weekTokens, limit: claudeWeeklyLimit)
            }
            .padding(.top, 6)

            if !s.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seneste projekter")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.7))
                    ForEach(s.recentProjects) { p in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                                .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
                            Text(p.label)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(formatTokens(p.tokens))
                                .font(.caption.monospaced())
                                .foregroundStyle(JarvisTheme.brightCyan)
                            Text("· \(relativeDay(p.lastUsed))")
                                .font(.caption2)
                                .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var todayLine: String {
        let s = service.claudeStats
        var parts: [String] = [formatTokens(s.todayTokens)]
        if s.todayMessages > 0 {
            parts.append("\(s.todayMessages) beskeder")
        }
        if s.todaySessions > 0 {
            parts.append("\(s.todaySessions) sessioner")
        }
        return parts.joined(separator: " · ")
    }

    private func formatHours(_ h: Double) -> String {
        if h < 1 { return String(format: "%.0f min", h * 60) }
        if h < 24 { return String(format: "%.1f t", h) }
        let days = Int(h / 24)
        let rem = h.truncatingRemainder(dividingBy: 24)
        return "\(days)d \(String(format: "%.0ft", rem))"
    }

    private func relativeDay(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 3600 { return "for \(Int(seconds / 60)) min siden" }
        if seconds < 86_400 { return "for \(Int(seconds / 3600))t siden" }
        let days = Int(seconds / 86_400)
        return "\(days)d siden"
    }

    /// "620K / 1M" style string used inside the two-column infoRow.
    private func budgetRow(used: Int, limit: Int) -> String {
        guard limit > 0 else { return formatTokens(used) }
        let pct = Int((Double(used) / Double(limit) * 100).rounded())
        return "\(formatTokens(used)) / \(formatTokens(limit))  (\(pct)%)"
    }

    private func budgetBar(label: String, used: Int, limit: Int) -> some View {
        let fraction = limit > 0 ? min(1.0, Double(used) / Double(limit)) : 0
        let barColor: Color = {
            if fraction >= 0.9 { return JarvisTheme.criticalGlow }
            if fraction >= 0.7 { return JarvisTheme.warningGlow }
            return JarvisTheme.neonCyan
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.7))
                Spacer()
                Text(budgetRow(used: used, limit: limit))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(JarvisTheme.surfaceBase.opacity(0.8))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(fraction), height: 6)
                        .shadow(color: barColor.opacity(0.6), radius: 3)
                        .animation(.easeOut(duration: 0.4), value: fraction)
                }
            }
            .frame(height: 6)
        }
    }

    private var latestSessionLine: String {
        let s = service.claudeStats
        var parts: [String] = [formatTokens(s.latestSessionTokens)]
        if let model = s.latestSessionModel {
            parts.append(prettyModel(model))
        }
        if let project = s.latestSessionProject {
            parts.append("· \(project)")
        }
        return parts.joined(separator: " ")
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return String(n)
    }

    private func prettyModel(_ model: String) -> String {
        // Turn "claude-opus-4-7" into "Opus 4.7"
        let lower = model.lowercased()
        if let match = lower.range(of: #"(opus|sonnet|haiku)-(\d+)-(\d+)"#, options: .regularExpression) {
            let chunk = String(lower[match])
            let parts = chunk.split(separator: "-")
            if parts.count >= 3 {
                return "\(parts[0].capitalized) \(parts[1]).\(parts[2])"
            }
        }
        return model
    }

    private var firstSessionFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "d. MMM yyyy"
        df.locale = Locale(identifier: "da_DK")
        return df
    }

    // MARK: - System tile

    private var systemTile: some View {
        tile(title: "System", icon: "cpu.fill", fullWidth: true) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("Batteri", value: batteryLine)
                    infoRow("macOS", value: service.systemInfo.osVersion)
                    infoRow("Host", value: service.systemInfo.hostname)
                    infoRow("IP", value: service.systemInfo.localIP)
                }
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("RAM", value: ramLine)
                    infoRow("WiFi", value: wifiLine)
                    infoRow("DNS", value: service.systemInfo.dnsServers.first)
                    infoRow("Hardware", value: hardwareLine)
                }
            }
            // Commute tucked into System so the layout balances on narrower screens
            HStack(spacing: 12) {
                commuteTile
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Network actions

    private var networkActions: some View {
        tile(title: "Netværk", icon: "network", fullWidth: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { await service.runSpeedtest() }
                    } label: {
                        Label(service.isRunningSpeedtest ? "Kører speedtest…" : "Kør speedtest",
                              systemImage: "speedometer")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(JarvisTheme.neonCyan)
                    .controlSize(.small)
                    .disabled(service.isRunningSpeedtest)

                    Button {
                        Task { await service.runNetworkScan() }
                    } label: {
                        Label(service.isRunningNetworkScan ? "Scanner…" : "Scan lokalt netværk",
                              systemImage: "dot.radiowaves.up.forward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.isRunningNetworkScan)
                }

                if let speedtest = service.systemInfo.speedtestSummary {
                    Text(speedtest)
                        .font(.caption.monospaced())
                        .foregroundStyle(JarvisTheme.brightCyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(JarvisTheme.surfaceBase.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !service.systemInfo.networkScan.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(service.systemInfo.networkScan.count) enheder fundet")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.7))
                        ForEach(service.systemInfo.networkScan.prefix(8)) { device in
                            HStack {
                                Text(device.ip)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text(device.mac)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
                            }
                        }
                        if service.systemInfo.networkScan.count > 8 {
                            Text("+ \(service.systemInfo.networkScan.count - 8) yderligere")
                                .font(.caption2)
                                .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared tile shell

    @ViewBuilder
    private func tile<Content: View>(
        title: String,
        icon: String,
        fullWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.neonCyan)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JarvisTheme.brightCyan)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(JarvisTheme.surfaceElevated.opacity(0.65))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(JarvisTheme.neonCyan.opacity(0.25), lineWidth: 1))
        }
    }

    private func infoRow(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(JarvisTheme.neonCyan.opacity(0.7))
                .frame(width: 60, alignment: .leading)
            Text(value ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived strings

    private var batteryLine: String? {
        let s = service.systemInfo
        if let percent = s.batteryPercent {
            var parts: [String] = ["\(percent)%"]
            if let state = s.batteryState { parts.append(state) }
            if let remaining = s.batteryTimeRemaining { parts.append(remaining) }
            return parts.joined(separator: " · ")
        }
        return nil
    }

    private var ramLine: String? {
        let s = service.systemInfo
        guard let total = s.ramTotalGB else { return nil }
        if let used = s.ramUsedGB {
            return String(format: "%.1f GB fri / %.0f GB", max(0, total - used), total)
        }
        return String(format: "%.0f GB", total)
    }

    private var wifiLine: String? {
        guard let wifi = service.systemInfo.wifi else { return nil }
        var parts: [String] = []
        if let ssid = wifi.ssid, !ssid.isEmpty {
            parts.append(ssid)
        }
        if let rssi = wifi.rssi {
            parts.append("\(rssi) dBm · \(wifi.qualityLabel)")
        }
        if let rate = wifi.transmitRate {
            parts.append(String(format: "%.0f Mbps", rate))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hardwareLine: String? {
        guard let hw = service.systemInfo.hardwareSummary else { return nil }
        // Pull out the "Chip:" line if present, else the first interesting line.
        for line in hw.components(separatedBy: .newlines) {
            if line.hasPrefix("Chip:") {
                return String(line.dropFirst("Chip:".count)).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("Model Name:") {
                return String(line.dropFirst("Model Name:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return hw.components(separatedBy: .newlines).first
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)t"
    }
}
