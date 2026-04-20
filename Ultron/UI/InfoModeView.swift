import AppKit
import CoreLocation
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
            VStack(spacing: 12) {
                // Top grid: 2×2 tiles on the LEFT (Vejr/Sol on top, Luft+Måne
                // and Nyheder on bottom) + tall Trafikinfo tile on the RIGHT
                // spanning both rows. Trafikinfo grows with its content, so
                // when there are many events the tall column carries them
                // without stretching the little weather tiles.
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            weatherTile
                            sunTile
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 12) {
                            airMoonTile
                            newsTile
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    trafficInfoTile
                        .frame(width: 280)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)

                // Rute + System share a row. System now bundles the
                // old Netværk actions (speedtest / scan buttons + their
                // results) so the two network sub-tiles collapse into one.
                HStack(alignment: .top, spacing: 12) {
                    commuteTile
                    VStack(spacing: 8) {
                        systemQuadrant
                        // Fill the right-column gap under the 2×2 with
                        // two small tiles — aircraft overhead + tonight's
                        // planets + ISS. Fixed-size so the row height is
                        // driven by content, not stretching into infinity.
                        HStack(alignment: .top, spacing: 8) {
                            flyTile
                            himmelTile
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                // Claude Code splits into two focused tiles so everything
                // fits without scrolling:
                //   LEFT  — Sessioner & Tokens (totals, budgets, længste)
                //   RIGHT — Projekter & Modeller (recent projects, top
                //           tools from the latest session, per-model split)
                HStack(alignment: .top, spacing: 12) {
                    claudeSessionsTile
                        .frame(maxWidth: .infinity)
                    claudeProjectsTile
                        .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                // Phase 4c: bottom briefing tile — raw Cockpit snapshot in
                // digest form, with a one-click "Åbn i chat" that pre-fills
                // the `/digest` command for LLM synthesis.
                briefingTile
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        // v1.4 Fase 2c: share the chat window's visual language — navy
        // gradient + material + hairline stroke. Cockpit, Briefing and the
        // corner HUD all wear the same shell now.
        //
        // Width 960pt (was 880pt) so the full-width commute tile has
        // breathing room for its internal horizontal split. Height is
        // still content-derived — HUDWindow clamps to screen height if
        // the user's display is shorter than the panel wants.
        .frame(width: 960, alignment: .topLeading)
        .ultronChatBackdrop()
        .task { await service.refresh() }
        // Keep Claude Code tile live — poll every 15 s while the panel is
        // visible so totals/projects/tools reflect the most recent session
        // without waiting on the 2-min full-panel refresh. Task cancels
        // automatically when the view disappears.
        .task {
            while !Task.isCancelled {
                await service.refreshClaudeStats()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        // Live performance probes every 5 s: CPU load, power draw,
        // thermal state, WiFi bytes, Bluetooth status. Short cadence so
        // Ydelse + Handlinger feel responsive without hammering the
        // slow probes that `refresh()` owns.
        .task {
            while !Task.isCancelled {
                await service.refreshLiveMetrics()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // Aircraft + ISS + planets every 30 s. adsb.lol allows ~1 req/s
        // so we're comfortably under the anonymous limit; wheretheiss.at
        // is similarly generous. Planet ephemeris is local math — free.
        .task {
            while !Task.isCancelled {
                await service.refreshAircraft()
                await service.refreshISS()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: - Header (chat-family minimal chrome)

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            UltronWordmark(fontSize: 13)
            Text("Cockpit")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(UltronTheme.textPrimary)
                .padding(.leading, 4)
            if let last = service.lastRefresh {
                Text("opdateret \(timeAgo(last))")
                    .font(.caption)
                    .foregroundStyle(UltronTheme.textMuted)
            }
            whisperPreloadChip
            Spacer()
            topChromeButton(system: service.state == .loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                            help: "Opdater") {
                Task { await service.refresh(force: true) }
            }
            topChromeButton(system: "xmark", help: "Luk", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - WhisperKit preload status chip

    /// Non-dominant status chip that surfaces the WhisperKit preload phase.
    /// Hidden when the model is ready (to keep the header uncluttered) and
    /// when no preload has kicked off yet. Always visible during download /
    /// warming / failure.
    #if canImport(WhisperKit)
    @ViewBuilder
    private var whisperPreloadChip: some View {
        let state = WhisperKitTranscriber.preloadState
        switch state.phase {
        case .idle, .ready:
            EmptyView()
        case .downloading:
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                Text("Henter offline STT… \(Int(state.progress * 100))%")
                    .font(.caption2)
            }
            .foregroundStyle(Color.white.opacity(0.55))
        case .warming:
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                Text("Varmer model…")
                    .font(.caption2)
            }
            .foregroundStyle(Color.white.opacity(0.55))
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .semibold))
                Text("Offline STT utilgængelig")
                    .font(.caption2)
            }
            .foregroundStyle(Color.white.opacity(0.55))
            .help(msg)
        }
    }
    #else
    @ViewBuilder private var whisperPreloadChip: some View { EmptyView() }
    #endif

    /// Slim top-right icon button matching the one on `ChatView.chatTopBar`
    /// so Cockpit's chrome reads identically.
    private func topChromeButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UltronTheme.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(UltronTheme.surfaceElevated.opacity(0.55))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Tiles

    /// Live Vejdirektoratet events, promoted out of the Hjem tile and
    /// given its own top-level slot in the 3-column grid. Shows up to 3
    /// events inside the compact tile footprint + a header row with
    /// source + "nær dig" / "på ruten" scope badge.
    private var trafficInfoTile: some View {
        tile(title: trafficTileTitle, icon: "exclamationmark.triangle.fill") {
            if !service.trafficEvents.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(service.trafficEvents.prefix(4)) { event in
                        trafficInfoRow(event)
                    }
                    if service.trafficEvents.count > 4 {
                        Text("+\(service.trafficEvents.count - 4) flere i nærheden")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    trafficNationalSummary
                    Text("Kilde: Vejdirektoratet · opdateres ~10 min")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.top, 2)
                }
            } else if service.lastRefresh != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.trafficEventsScope == .route
                         ? "Ingen aktuelle hændelser på ruten."
                         : "Ingen aktuelle hændelser i nærheden.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                    trafficNationalSummary
                    Text("Kilde: Vejdirektoratet · opdateres ~10 min")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            } else {
                placeholder("Henter trafikinfo…")
            }
        }
    }

    /// Variant of `trafficEventRow` tailored for the tall Trafikinfo tile —
    /// adds a relative-time chip ("for 2t 4m") under the header so the user
    /// can tell stale events from fresh ones at a glance, plus a muted
    /// kommune badge when the reporting body isn't the default
    /// Vejdirektoratet.
    private func trafficInfoRow(_ event: TrafficEvent) -> some View {
        Button {
            if let url = URL(string: "https://trafikkort.vejdirektoratet.dk/index.html") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: event.category.icon)
                    .font(.caption)
                    .foregroundStyle(trafficEventColor(event.category))
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        if let ago = event.timeAgoLabel() {
                            Text("· \(ago)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                    if !event.header.isEmpty {
                        Text(event.header)
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let kommuneLabel = trafficKommuneLabel(event) {
                        Text(kommuneLabel)
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .help(event.plainDescription.isEmpty ? event.header : event.plainDescription)
    }

    /// Skip the default "Vejdirektoratet" label — that's 95% of events and
    /// the source footer already credits them. Show only municipal ones.
    private func trafficKommuneLabel(_ event: TrafficEvent) -> String? {
        let k = event.kommune.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, k != "Vejdirektoratet" else { return nil }
        return "Rapporteret af \(k) kommune"
    }

    /// National-scope aggregate underneath the per-row list. Reads
    /// directly off the service's snapshot — no extra fetch.
    @ViewBuilder
    private var trafficNationalSummary: some View {
        if service.trafficEventsTotalCount > 0 {
            let total = service.trafficEventsTotalCount
            let topCats = service.trafficEventsCountByCategory.prefix(3)
            let breakdown = topCats
                .map { "\($0.1) \($0.0.label.lowercased())" }
                .joined(separator: " · ")
            VStack(alignment: .leading, spacing: 1) {
                Text("Hele DK: \(total) aktive hændelser")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                if !breakdown.isEmpty {
                    Text(breakdown)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.top, 4)
        }
    }

    private var trafficTileTitle: String {
        switch service.trafficEventsScope {
        case .nearby: return "Trafikinfo nær dig"
        case .route:  return "Trafikinfo på ruten"
        }
    }

    /// Merged Luft/UV + Måne tile. Horizontally split inside: air metrics
    /// left, moon phase right. Compact enough to fit a half-row slot but
    /// still shows the primary values (AQI, UV, moon phase) at a glance.
    private var airMoonTile: some View {
        tile(title: "Luft & Måne", icon: "aqi.medium") {
            HStack(alignment: .top, spacing: 12) {
                airSubBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                    .frame(width: 1)
                    .overlay(Color.white.opacity(0.12))
                moonSubBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var airSubBlock: some View {
        if let air = service.airQuality {
            VStack(alignment: .leading, spacing: 4) {
                airValueRow(label: "AQI",
                            value: air.europeanAQI.map(String.init) ?? "—",
                            band: air.aqiBand.label,
                            color: aqiColor(air.aqiBand))
                airValueRow(label: "UV",
                            value: air.uvIndex.map { String(format: "%.1f", $0) } ?? "—",
                            band: air.uvBand.label,
                            color: uvColor(air.uvBand))
                if let pm25 = air.pm25 {
                    Text(String(format: "PM2.5 · %.1f µg/m³", pm25))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        } else {
            placeholder("Henter luft…")
        }
    }

    private func airValueRow(label: String, value: String, band: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
            Text(band)
                .font(.caption2)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var moonSubBlock: some View {
        let m = service.moon
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: m.phase.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.white.opacity(0.5), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.phase.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(m.illuminationPercent) % oplyst")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            Text("Fuld \(Self.fullMoonFormatter.string(from: m.nextFullMoon))")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    private func aqiColor(_ band: AirQualitySnapshot.AQIBand) -> Color {
        switch band {
        case .excellent, .good: return Color.white
        case .moderate:         return Color.white
        case .poor:             return UltronTheme.warningGlow
        case .veryPoor, .extreme: return UltronTheme.criticalGlow
        case .unknown:          return Color.white.opacity(0.55)
        }
    }

    private func uvColor(_ band: AirQualitySnapshot.UVBand) -> Color {
        switch band {
        case .low:              return Color.white
        case .moderate:         return Color.white
        case .high:             return UltronTheme.warningGlow
        case .veryHigh, .extreme: return UltronTheme.criticalGlow
        case .unknown:          return Color.white.opacity(0.55)
        }
    }

    private static let fullMoonFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "d. MMM"
        df.locale = Locale(identifier: "da_DK")
        return df
    }()

    private var sunTile: some View {
        tile(title: "Sol", icon: "sun.horizon.fill") {
            if let sun = service.weather?.todaySun {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "sunrise.fill")
                            .foregroundStyle(Color.white)
                        Text(Self.hourMinute.string(from: sun.sunrise))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "sunset.fill")
                            .foregroundStyle(Color.white)
                        Text(Self.hourMinute.string(from: sun.sunset))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    if let daylight = service.weather?.daily.first?.daylight {
                        Text("Dagslys \(Self.prettyDaylight(daylight))")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .padding(.top, 2)
                    }
                    if let delta = solsticeDeltaText() {
                        Text(delta)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    if let holiday = nextHolidayText() {
                        Text(holiday)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
            } else {
                placeholder("Henter sol…")
            }
        }
    }

    /// Compare today's actual daylight (from the weather snapshot) to the
    /// daylight at the most recent solstice for the user's latitude, and
    /// format it as a human-readable Danish delta.
    ///
    /// - Returns: e.g. "Dagen er 4t 12m længere siden vintersolhverv", or nil
    ///   when the weather tile hasn't loaded yet.
    private func solsticeDeltaText() -> String? {
        guard let today = service.weather?.daily.first?.daylight else { return nil }
        // Copenhagen fallback when CoreLocation hasn't fixed yet — keeps the
        // tile useful on cold-open instead of vanishing for 10 s.
        let latitude = service.latitudeForCockpit ?? 55.67
        let last = SolarDateMath.lastSolstice(before: Date(), latitude: latitude)
        let delta = today - last.daylightSeconds
        let absDelta = abs(delta)
        let hours = Int(absDelta) / 3600
        let minutes = (Int(absDelta) % 3600) / 60
        let direction = delta >= 0 ? "længere" : "kortere"
        let since = last.isWinter ? "vintersolhverv" : "sommersolhverv"
        return "Dagen er \(hours)t \(minutes)m \(direction) siden \(since)"
    }

    /// Next upcoming Danish holiday + a human-readable countdown in days.
    private func nextHolidayText() -> String? {
        guard let holiday = DanishHolidays.next() else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: holiday.date)).day ?? 0
        if days == 0 { return "I dag: \(holiday.name)" }
        if days == 1 { return "Næste helligdag: \(holiday.name) i morgen" }
        return "Næste helligdag: \(holiday.name) om \(days) dage"
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: WeatherCode.symbol(for: weather.current.weatherCode))
                            .font(.system(size: 30))
                            .foregroundStyle(Color.white)
                            .shadow(color: Color.white.opacity(0.6), radius: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(weather.current.temperature.rounded()))°")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(weather.locationLabel)
                                .font(.caption).foregroundStyle(Color.white.opacity(0.7))
                            Text(WeatherCode.label(for: weather.current.weatherCode))
                                .font(.caption).foregroundStyle(Color.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                    }
                    // Secondary metrics line — feels-like, wind, humidity,
                    // today's high/low all on one compact row so the tile
                    // doesn't grow vertically. Uses caption2 so the extra
                    // info reads as metadata, not as primary signal.
                    weatherMetricsRow(weather)
                }
            } else {
                placeholder("Henter vejr…")
            }
        }
    }

    @ViewBuilder
    private func weatherMetricsRow(_ weather: WeatherSnapshot) -> some View {
        HStack(spacing: 10) {
            weatherMetric(icon: "thermometer.medium", text: "føles \(Int(weather.current.feelsLike.rounded()))°")
            weatherMetric(icon: "wind", text: "\(Int(weather.current.windSpeed.rounded())) m/s")
            weatherMetric(icon: "humidity", text: "\(weather.current.humidity)%")
            if let today = weather.daily.first {
                weatherMetric(
                    icon: "arrow.up.arrow.down",
                    text: "\(Int(today.tempMin.rounded()))°/\(Int(today.tempMax.rounded()))°"
                )
            }
        }
    }

    private func weatherMetric(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2).foregroundStyle(Color.white.opacity(0.65))
            Text(text)
                .font(.caption2).foregroundStyle(Color.white.opacity(0.8))
        }
        .fixedSize()
    }

    @State private var newsSource: NewsHeadline.Source = .dr

    private var newsTile: some View {
        tile(title: "Nyheder", icon: "newspaper.fill") {
            if service.newsBySource.values.allSatisfy({ $0.isEmpty }) {
                placeholder("Henter nyheder…")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Kilde", selection: $newsSource) {
                        ForEach(NewsHeadline.Source.infoPanelSources) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()

                    let items = service.newsBySource[newsSource] ?? []
                    if items.isEmpty {
                        Text("Ingen nyheder lige nu")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.55))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items.prefix(3)) { item in
                                Button {
                                    if let url = item.link { NSWorkspace.shared.open(url) }
                                } label: {
                                    HStack(alignment: .top, spacing: 6) {
                                        Circle()
                                            .fill(Color.white.opacity(0.6))
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

    @State private var customDestination: String = ""

    private var commuteTile: some View {
        tile(title: commuteTitle, icon: "house.fill", fullWidth: true) {
            // Half-width tile that sits next to System info. Internal
            // layout is now a straight vertical stack — no left/right
            // split — so the narrower tile width doesn't squeeze either
            // the stats or the map.
            commuteStatsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            commuteChipsRow
            motorwayAccidentsSection
            destinationInputRow
            commuteMapColumn
                .frame(maxWidth: .infinity)
        }
    }

    /// Events in `service.trafficEvents` that are accidents specifically on
    /// a motorway. Match either a European route code (E20, E45, …) or the
    /// literal "motorvej" anywhere in the header/description. The broader
    /// Trafikinfo tile at the top row still carries everything — this
    /// section is a tighter "pay attention, this affects your drive" list.
    private var motorwayAccidents: [TrafficEvent] {
        let pattern = #"\bE\d+\b|motorvej"#
        return service.trafficEvents.filter { event in
            guard event.category == .accident else { return false }
            let hay = "\(event.header) \(event.plainDescription)"
            return hay.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    @ViewBuilder
    private var motorwayAccidentsSection: some View {
        let accidents = motorwayAccidents
        if !accidents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(UltronTheme.criticalGlow)
                    Text("Ulykker på motorvejen (\(accidents.count))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                ForEach(accidents.prefix(3)) { event in
                    trafficEventRow(event)
                }
            }
        }
    }

    /// Map + charger legend. Sized to a compact 200pt height since the
    /// tile is now half-width — map is still zoomable + scrollable if
    /// the user needs more detail.
    @ViewBuilder
    private var commuteMapColumn: some View {
        if let commute = service.commute, !commute.routeCoordinates.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                CommuteMapView(
                    origin: commute.origin,
                    destination: commute.destination,
                    coordinates: commute.routeCoordinates,
                    chargers: service.chargers
                )
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.30), lineWidth: 1)
                )
                if !service.chargers.isEmpty {
                    chargerLegend
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Beregner rute…")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                )
                .frame(height: 160)
        }
    }

    /// Compact list of Vejdirektoratet events near the user or along the
    /// active route. When the filter returns empty but we've already done
    /// at least one refresh cycle, we show a "ingen hændelser" placeholder
    /// so the user can tell the integration is alive, it just has nothing
    /// to report.
    @ViewBuilder
    private var trafficEventsSection: some View {
        if !service.trafficEvents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                trafficEventsHeaderRow
                ForEach(service.trafficEvents.prefix(4)) { event in
                    trafficEventRow(event)
                }
            }
            .padding(.top, 8)
        } else if service.lastRefresh != nil {
            VStack(alignment: .leading, spacing: 4) {
                trafficEventsHeaderRow
                Text(service.trafficEventsScope == .route
                     ? "Ingen aktuelle hændelser på ruten."
                     : "Ingen aktuelle hændelser i nærheden.")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.top, 8)
        }
    }

    private var trafficEventsHeaderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.85))
            Text(trafficEventsHeader)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Spacer(minLength: 0)
            Text("Kilde: Vejdirektoratet")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    private var trafficEventsHeader: String {
        let count = service.trafficEvents.count
        switch service.trafficEventsScope {
        case .nearby:
            return count == 0 ? "Trafikinfo i nærheden" : "Trafikinfo i nærheden (\(count))"
        case .route:
            return count == 0 ? "Trafikinfo på ruten" : "Trafikinfo på ruten (\(count))"
        }
    }

    /// Compact row of commute cards for the user's pinned destinations.
    /// Visible only in home mode — once the user types an ad-hoc address the
    /// row hides so the tile stays focused on the single active route.
    /// Missing entries (geocode/routing failure) simply don't render; we
    /// never surface an error because the main commute row already owns
    /// that UI surface.
    @ViewBuilder
    private var pinnedDestinationsRow: some View {
        if service.customDestinationAddress == nil && !service.pinnedCommutes.isEmpty {
            let cards = service.pinnedDestinations.compactMap { dest -> (PinnedDestination, CommuteEstimate)? in
                guard let est = service.pinnedCommutes[dest] else { return nil }
                return (dest, est)
            }
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.85))
                        Text("Pinnede destinationer")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    // Stacked vertically so the cards fill the narrow right
                    // column — leaves room for the stats/traffic content on
                    // the left "next to them at the top".
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(cards, id: \.0.id) { (dest, est) in
                            pinnedDestinationCard(destination: dest, estimate: est)
                        }
                    }
                }
            }
        }
    }

    /// Single pinned-destination card. Styled like the translucent chip
    /// family used by `destinationWeatherChip` so it fits naturally inside
    /// the commute tile's visual language.
    private func pinnedDestinationCard(destination: PinnedDestination, estimate: CommuteEstimate) -> some View {
        let arrival = Self.etaFormatter.string(from: Date().addingTimeInterval(estimate.expectedTravelTime))
        let kronerEstimate = Int((estimate.teslaKWh * 3.5).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "mappin.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(destination.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(estimate.prettyTravelTime)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
                Text(estimate.prettyDistance)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.7))
                Text("Ankomst \(arrival)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            HStack(spacing: 4) {
                Image(systemName: "bolt.car.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(String(format: "~%.1f kWh · ~%d kr", estimate.teslaKWh, kronerEstimate))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .help("\(destination.name): \(destination.address)")
    }

    private func trafficEventRow(_ event: TrafficEvent) -> some View {
        // Distance is only useful in "nearby" mode — on a route, the events
        // are already filtered by proximity to the polyline, and measuring
        // from the origin would be misleading for events near the destination.
        let distanceText: String? = {
            guard service.trafficEventsScope == .nearby,
                  let origin = service.commute?.origin.clLocationCoordinate else {
                return nil
            }
            let km = event.distanceKm(from: origin)
            if km < 1 { return String(format: "%.0f m", km * 1000) }
            if km < 10 { return String(format: "%.1f km", km) }
            return "\(Int(km.rounded())) km"
        }()

        return Button {
            if let url = URL(string: "https://trafikkort.vejdirektoratet.dk/index.html") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: event.category.icon)
                    .font(.caption)
                    .foregroundStyle(trafficEventColor(event.category))
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        if let distanceText {
                            Text("· \(distanceText)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                    if !event.header.isEmpty {
                        Text(event.header)
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .help(event.plainDescription.isEmpty ? event.header : event.plainDescription)
    }

    /// Small legend under the map so "red pin = Tesla, blue pin = Clever"
    /// reads without a hover. Counts make it obvious if a network is empty
    /// (e.g. Clever needs an OCM API key in Settings).
    private var chargerLegend: some View {
        let tesla = service.chargers.filter { $0.network == .teslaSupercharger }.count
        let clever = service.chargers.filter { $0.network == .clever }.count
        return HStack(spacing: 10) {
            chargerLegendDot(color: Color(red: 0.910, green: 0.129, blue: 0.153),
                             label: "Tesla Supercharger",
                             count: tesla)
            if clever > 0 {
                chargerLegendDot(color: Color(red: 0.059, green: 0.435, blue: 1.0),
                                 label: "Clever",
                                 count: clever)
            } else {
                chargerLegendCleverPlaceholder
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func chargerLegendDot(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) · \(count)")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    /// When Clever has no entries (no OCM key configured yet) we show a
    /// muted placeholder pointing at the Settings toggle rather than silently
    /// omitting the network — otherwise a Tesla driver wonders why their
    /// Clever chargers aren't showing up.
    private var chargerLegendCleverPlaceholder: some View {
        HStack(spacing: 5) {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: 8, height: 8)
            Text("Clever · tilføj OCM-nøgle i Settings")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func trafficEventColor(_ category: TrafficEvent.Category) -> Color {
        switch category {
        case .accident:      return UltronTheme.criticalGlow
        case .obstruction:   return UltronTheme.warningGlow
        case .animal, .roadCondition: return UltronTheme.warningGlow
        case .publicEvent, .other: return Color.white.opacity(0.75)
        }
    }

    /// Live-traffic + destination-weather chips. Vejdirektoratet is always
    /// shown (it's a stable external resource); the weather chip only appears
    /// when the user has set an ad-hoc destination and we managed to fetch its
    /// weather snapshot.
    private var commuteChipsRow: some View {
        HStack(spacing: 8) {
            if let destWeather = service.destinationWeather {
                destinationWeatherChip(destWeather)
            }
            vejdirektoratetChip
            Spacer(minLength: 0)
        }
    }

    private func destinationWeatherChip(_ weather: WeatherSnapshot) -> some View {
        Button {
            // No-op on tap; the chip is purely informational. Future: open
            // the full weather tile scoped to destination coord.
        } label: {
            HStack(spacing: 5) {
                Image(systemName: WeatherCode.symbol(for: weather.current.weatherCode))
                    .font(.footnote)
                    .foregroundStyle(Color.white)
                Text("\(Int(weather.current.temperature.rounded()))° ved \(weather.locationLabel)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Vejret ved destinationen: \(WeatherCode.label(for: weather.current.weatherCode))")
    }

    private var vejdirektoratetChip: some View {
        Button {
            if let url = URL(string: "https://trafikkort.vejdirektoratet.dk/index.html") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "road.lanes")
                    .font(.footnote)
                    .foregroundStyle(Color.white)
                Text("Live trafik (Vejdirektoratet)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.85))
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Åbner trafikkort.vejdirektoratet.dk i browseren")
    }

    private var commuteTitle: String {
        service.customDestinationAddress == nil ? "Hjem" : "Rute"
    }

    @ViewBuilder
    private var commuteStatsColumn: some View {
        if let commute = service.commute {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(commute.prettyTravelTime)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("til \(commute.toLabel)")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                }
                // Secondary line: arrival ETA + distance inline
                HStack(spacing: 10) {
                    Label {
                        Text("Ankomst \(Self.etaFormatter.string(from: Date().addingTimeInterval(commute.expectedTravelTime)))")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.85))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.footnote).foregroundStyle(Color.white.opacity(0.7))
                    }
                    Text("· \(commute.prettyDistance)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                if commute.baselineTravelTime != nil {
                    HStack(spacing: 5) {
                        Image(systemName: trafficIcon(commute.trafficCondition))
                            .font(.footnote)
                            .foregroundStyle(trafficColor(commute.trafficCondition))
                        Text("\(commute.trafficCondition.label) · \(commute.prettyTrafficDelay)")
                            .font(.footnote)
                            .foregroundStyle(trafficColor(commute.trafficCondition))
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "bolt.car.fill")
                        .font(.footnote).foregroundStyle(Color.white)
                    Text(String(format: "Tesla ~%.2f kWh", commute.teslaKWh))
                        .font(.footnote).foregroundStyle(Color.white)
                    Text("· ~\(Int((commute.teslaKWh * 3.5).rounded())) kr")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .help("Ved 3,50 kr/kWh — ca. husholdnings-elpris")
                }
                Text("Fra \(commute.fromLabel)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.top, 2)
            }
        } else if let error = service.commuteError {
            Text(error)
                .font(.footnote).foregroundStyle(Color.white.opacity(0.75))
                .multilineTextAlignment(.leading)
        } else {
            placeholder("Beregner rute…")
        }
    }

    /// Short "HH:mm" formatter used for arrival-time text.
    private static let etaFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        df.locale = Locale(identifier: "da_DK")
        return df
    }()

    private var destinationInputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(Color.white.opacity(0.7))
                // Let the text field take the remaining horizontal space;
                // previous layout let the map + buttons squeeze it down to
                // ~20pt so you couldn't see what you were typing.
                TextField("Indtast adresse…", text: $customDestination)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(minWidth: 180)
                    .frame(maxWidth: .infinity)
                    .onSubmit(runCustomDestination)

                Button(action: runCustomDestination) {
                    if service.isRunningCustomCommute {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Beregn").font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white)
                .controlSize(.small)
                .disabled(customDestination.trimmingCharacters(in: .whitespaces).isEmpty
                          || service.isRunningCustomCommute)
                .fixedSize()

                if service.customDestinationAddress != nil {
                    Button {
                        customDestination = ""
                        Task { await service.resetCustomCommute() }
                    } label: {
                        Label("Nulstil", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if let active = service.customDestinationAddress {
                Text("Beregnet til: \(active)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }

    private func runCustomDestination() {
        let trimmed = customDestination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await service.recomputeCommute(to: trimmed) }
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
        case .free:    return Color.white
        case .light:   return Color.white
        case .heavy:   return UltronTheme.warningGlow
        case .severe:  return UltronTheme.criticalGlow
        case .unknown: return Color.white.opacity(0.5)
        }
    }

    // MARK: - Claude Code tiles (split)

    /// Left half — usage totals + today/weekly budgets. Numbers-first view.
    private var claudeSessionsTile: some View {
        let s = service.claudeStats
        return tile(title: "Claude · Sessioner & Tokens", icon: "sparkles", fullWidth: true) {
            // Single compact column — the budget bars below already carry
            // the Daily/Weekly percentage signal, so the old duplicate
            // infoRow pair was removed to bring tile height in line with
            // Projekter & Modeller on the right.
            VStack(alignment: .leading, spacing: 4) {
                infoRow("I dag", value: todayLine)
                infoRow("I alt", value: "\(formatTokens(s.totalTokens)) · \(s.totalSessions) sessioner")
                infoRow("Kørt", value: formatHours(s.totalActiveHours))
                infoRow("Seneste", value: latestSessionLine)
                if let first = s.firstSessionDate {
                    infoRow("Siden", value: firstSessionFormatter.string(from: first))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                budgetBar(label: "I dag", used: s.todayTokens, limit: claudeDailyLimit)
                budgetBar(label: "Denne uge", used: s.weekTokens, limit: claudeWeeklyLimit)
            }
            .padding(.top, 6)

            if s.longestSessionMessages > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.65))
                    Text("Længste: \(s.longestSessionMessages) beskeder")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.65))
                    if let date = s.longestSessionDate {
                        Text("· \(firstSessionFormatter.string(from: date))")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Right half — recent projects, top tools from the latest session,
    /// per-model breakdown with cache-hit ratio.
    private var claudeProjectsTile: some View {
        let s = service.claudeStats
        return tile(title: "Claude · Projekter & Modeller", icon: "folder.fill", fullWidth: true) {
            if !s.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seneste projekter")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    ForEach(s.recentProjects) { p in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                            Text(p.label)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(formatTokens(p.tokens))
                                .font(.footnote.monospaced())
                                .foregroundStyle(Color.white)
                            Text("· \(relativeDay(p.lastUsed))")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                }
            }

            if !s.latestSessionTools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top tools (seneste session)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    // Wrap tool chips so they don't overflow the narrower
                    // half-width tile. FlowLayout would be ideal; for now
                    // split into two horizontal rows if there are more
                    // than 4 tools.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(chunkedTools(s.latestSessionTools, perRow: 4).enumerated()), id: \.offset) { _, chunk in
                            HStack(spacing: 6) {
                                ForEach(chunk) { tool in
                                    claudeToolChip(tool)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }

            if !s.modelBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Modeller (all-time)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    ForEach(s.modelBreakdown.prefix(4)) { m in
                        HStack(spacing: 6) {
                            Text(prettyModel(m.name))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 76, alignment: .leading)
                                .lineLimit(1)
                            modelBar(model: m)
                            Spacer(minLength: 4)
                            Text(formatTokens(m.tokens))
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.white)
                            Text(String(format: "%.0f%%", m.cacheRatio * 100))
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    /// Split the latestSessionTools list into rows of `count` so the chips
    /// wrap inside the narrower half-width tile instead of overflowing.
    /// Free-standing extension helper would also work but this keeps the
    /// usage local to the Cockpit.
    private func chunkedTools(_ tools: [ClaudeStatsSnapshot.ToolStat], perRow: Int) -> [[ClaudeStatsSnapshot.ToolStat]] {
        guard !tools.isEmpty else { return [] }
        return stride(from: 0, to: tools.count, by: perRow).map {
            Array(tools[$0..<min($0 + perRow, tools.count)])
        }
    }

    private func claudeToolChip(_ tool: ClaudeStatsSnapshot.ToolStat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: toolIcon(tool.name))
                .font(.caption2)
            Text(tool.name)
                .font(.caption2)
            Text("\(tool.count)")
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(UltronTheme.surfaceBase.opacity(0.6))
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        )
        .foregroundStyle(.white.opacity(0.85))
    }

    /// Compact horizontal bar showing a model's share of total tokens.
    ///
    /// Width is hardcoded to 120pt so no GeometryReader is needed — GeometryReader
    /// inside an NSHostingController sized via .preferredContentSize caused a
    /// layout-feedback crash (see InfoModeView.body comment).
    private func modelBar(model: ClaudeStatsSnapshot.ModelStat) -> some View {
        let total = service.claudeStats.totalTokens
        let share = total > 0 ? Double(model.tokens) / Double(total) : 0
        let barWidth: CGFloat = 120
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(UltronTheme.surfaceBase.opacity(0.6))
            Capsule()
                .fill(Color.white)
                .frame(width: barWidth * CGFloat(share))
                .shadow(color: Color.white.opacity(0.5), radius: 2)
        }
        .frame(width: barWidth, height: 5)
    }

    private func toolIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "edit":            return "pencil"
        case "write":           return "square.and.pencil"
        case "read":            return "doc.text"
        case "bash":            return "terminal"
        case "grep":            return "magnifyingglass"
        case "glob":            return "doc.on.doc"
        case "taskcreate",
             "taskupdate":      return "checklist"
        case "agent":           return "sparkles"
        case "toolsearch":      return "rectangle.and.text.magnifyingglass"
        case "askuserquestion": return "questionmark.bubble"
        default:                return "wrench.adjustable"
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

    /// "620K / 1M (62%)" style string. Percentages are capped at 999% in
    /// the display — anything higher means the user's budget defaults
    /// are below their actual usage, and showing "90809%" just reads as
    /// broken. The bar still visualises the 100% clamp.
    private func budgetRow(used: Int, limit: Int) -> String {
        guard limit > 0 else { return formatTokens(used) }
        let pct = Int((Double(used) / Double(limit) * 100).rounded())
        let pctLabel = pct > 999 ? ">999%" : "\(pct)%"
        return "\(formatTokens(used)) / \(formatTokens(limit)) (\(pctLabel))"
    }

    private func budgetBar(label: String, used: Int, limit: Int) -> some View {
        let fraction = limit > 0 ? min(1.0, Double(used) / Double(limit)) : 0
        let barColor: Color = {
            if fraction >= 0.9 { return UltronTheme.criticalGlow }
            if fraction >= 0.7 { return UltronTheme.warningGlow }
            return Color.white
        }()
        // Width follows the parent tile — no hardcoded 640pt (which used
        // to push the whole Sessioner tile past the panel's 960pt frame
        // when the tile moved to half-width). GeometryReader is fine
        // here because the parent tile is a leaf with an explicit
        // maxWidth, so no layout-feedback loop.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer(minLength: 4)
                Text(budgetRow(used: used, limit: limit))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(UltronTheme.surfaceBase.opacity(0.8))
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(fraction))
                        .shadow(color: barColor.opacity(0.6), radius: 3)
                        .animation(UltronTheme.spring, value: fraction)
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
        // Once we cross 1 000 millioner we switch to the Danish "milliard"
        // label so "1.6 mia" reads natively instead of "1600M".
        if n >= 1_000_000_000 { return String(format: "%.1f mia", Double(n) / 1_000_000_000) }
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

    /// 2×2 grid of four equal-sized system/network sub-tiles, sitting
    /// inside the same half-row slot the old monolithic System tile used.
    /// Each sub-tile is a focused domain (System / Netværk / Ydelse /
    /// Handlinger) which makes the info scannable without scrolling.
    private var systemQuadrant: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                systemBasicsSubTile
                networkSubTile
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                performanceSubTile
                actionsSubTile
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var systemBasicsSubTile: some View {
        subTile(title: "System", icon: "cpu.fill") {
            infoRow("Batteri", value: batteryLine)
            infoRow("macOS", value: service.systemInfo.osVersion)
            infoRow("Host", value: service.systemInfo.hostname)
            infoRow("Uptime", value: uptimeLine)
            infoRow("Hardware", value: hardwareLine)
        }
    }

    private var networkSubTile: some View {
        subTile(title: "Netværk", icon: "network") {
            infoRow("Lokal IP", value: service.systemInfo.localIP)
            infoRow("DNS", value: service.systemInfo.dnsServers.first)
            infoRow("WiFi", value: wifiSSIDLine)
            infoRow("Signal", value: wifiSignalLine)
            infoRow("Rate", value: wifiRateLine)
        }
    }

    private var performanceSubTile: some View {
        subTile(title: "Ydelse", icon: "speedometer") {
            // CPU first — most dynamic number on the tile.
            if let cpu = service.systemInfo.cpuLoadPercent {
                infoRow("CPU", value: String(format: "%.0f %%", cpu * 100))
                miniUsageBar(label: "CPU", percent: cpu)
            } else {
                infoRow("CPU", value: "måler…")
            }
            infoRow("RAM", value: ramLine)
            if let ramPct = ramUsedPercent {
                miniUsageBar(label: "RAM", percent: ramPct)
            }
            infoRow("Disk", value: diskLine)
            if let diskPct = diskUsedPercent {
                miniUsageBar(label: "Disk", percent: diskPct)
            }
            if let watts = service.systemInfo.powerDrawWatts {
                infoRow("Strøm", value: String(format: "%.1f W", watts))
            } else {
                // When plugged in the draw isn't available from
                // AppleSmartBattery; tell the user instead of showing —.
                infoRow("Strøm", value: "tilsluttet")
            }
            infoRow("Termisk", value: thermalLabel)
        }
    }

    private var actionsSubTile: some View {
        subTile(title: "Handlinger", icon: "bolt.fill") {
            HStack(spacing: 6) {
                Button {
                    Task { await service.runSpeedtest() }
                } label: {
                    Label(service.isRunningSpeedtest ? "Kører…" : "Speedtest",
                          systemImage: "speedometer")
                        .font(.caption2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white)
                .controlSize(.mini)
                .disabled(service.isRunningSpeedtest)

                Button {
                    Task { await service.runNetworkScan() }
                } label: {
                    Label(service.isRunningNetworkScan ? "Scan…" : "Scan LAN",
                          systemImage: "dot.radiowaves.up.forward")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(service.isRunningNetworkScan)
            }

            // WiFi quality + cumulative RX/TX bytes on the WiFi interface.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.caption2)
                        .foregroundStyle(wifiQualityColor)
                    Text("WiFi · \(service.systemInfo.wifi?.qualityLabel ?? "ingen")")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                if let rx = service.systemInfo.wifiBytesReceived,
                   let tx = service.systemInfo.wifiBytesSent {
                    Text("↓ \(formatBytes(rx)) · ↑ \(formatBytes(tx))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(.top, 4)

            // Bluetooth: on/off + count + up to 2 device names.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: service.systemInfo.bluetoothPoweredOn ? "bolt.horizontal.fill" : "bolt.horizontal")
                        .font(.caption2)
                        .foregroundStyle(service.systemInfo.bluetoothPoweredOn
                                         ? Color.white : Color.white.opacity(0.45))
                    Text(bluetoothStatusLine)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                if !service.systemInfo.bluetoothConnectedDevices.isEmpty {
                    ForEach(service.systemInfo.bluetoothConnectedDevices.prefix(2), id: \.self) { name in
                        Text("· \(name)")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    if service.systemInfo.bluetoothConnectedDevices.count > 2 {
                        Text("+ \(service.systemInfo.bluetoothConnectedDevices.count - 2)")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
            }
            .padding(.top, 2)

            if let speedtest = service.systemInfo.speedtestSummary {
                Text(speedtest)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }

            if !service.systemInfo.networkScan.isEmpty {
                Text("\(service.systemInfo.networkScan.count) enheder på LAN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Fly + Himmel tiles (bottom-right filler)

    /// "Fly over dig" — 3 nearest aircraft from adsb.lol, showing
    /// callsign + altitude (FL) + compass direction from user + distance.
    /// Hidden entirely when the feed returns nothing (anywhere really rural
    /// at 3am — unlikely in daylight Denmark).
    private var flyTile: some View {
        subTile(title: "Fly over dig", icon: "airplane") {
            if service.aircraftNearby.isEmpty {
                Text("Ingen fly i nærheden")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(service.aircraftNearby.prefix(4)) { a in
                        flyRow(a)
                    }
                }
            }
        }
    }

    private func flyRow(_ a: Aircraft) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let heading = a.headingDeg {
                Image(systemName: "airplane")
                    .font(.caption2)
                    .rotationEffect(.degrees(heading - 90))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 10)
            } else {
                Image(systemName: "airplane")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 10)
            }
            // Route (origin → destination IATA codes) when known; the
            // callsign or registration is the fallback while the route
            // lookup is pending or when adsbdb doesn't know the flight.
            Text(a.routeLabel)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(a.origin == nil ? Color.white.opacity(0.7) : .white)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
                .help(flyRowTooltip(for: a))
            if let fl = a.altitudeFL {
                Text(fl)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.white.opacity(0.8))
            } else if a.onGround {
                Text("GND")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Text(Compass.label(for: a.bearingDeg))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.8))
            Spacer(minLength: 0)
            Text("\(Int(a.distanceKm.rounded())) km")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    /// Hover tooltip shows the "noisier" metadata — callsign, aircraft
    /// type, origin + destination city names — so the compact row itself
    /// stays scannable.
    private func flyRowTooltip(for a: Aircraft) -> String {
        var parts: [String] = []
        if let sign = a.callsign { parts.append(sign) }
        if let t = a.aircraftType { parts.append(t) }
        if let origin = a.origin, let dest = a.destination {
            parts.append("\(origin.municipality) → \(dest.municipality)")
        }
        return parts.joined(separator: " · ")
    }

    /// "Himmel" — synlige planeter + ISS current subpoint. Planets come
    /// from the local `PlanetEphemeris` helper; ISS sub-point from the
    /// wheretheiss.at API. Everything degrades gracefully when offline or
    /// when no planet is currently above the horizon.
    private var himmelTile: some View {
        subTile(title: "Himmel", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 3) {
                if service.visiblePlanets.isEmpty {
                    Text("Ingen planeter over horisonten")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                } else {
                    ForEach(service.visiblePlanets.prefix(3)) { planet in
                        himmelPlanetRow(planet)
                    }
                }
                if let iss = service.issPosition {
                    Divider()
                        .frame(height: 0.5)
                        .overlay(Color.white.opacity(0.12))
                        .padding(.vertical, 2)
                    issRow(iss)
                }
            }
        }
    }

    private func himmelPlanetRow(_ planet: PlanetVisibility) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(planet.kind.glyph)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 12)
            Text(planet.kind.danishName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .leading)
            Text(planet.compass)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.75))
            Spacer(minLength: 0)
            Text(String(format: "%.0f°", planet.altitudeDeg))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private func issRow(_ iss: ISSPosition) -> some View {
        // Fall back to Copenhagen when CoreLocation hasn't fixed yet so
        // the tile still renders useful distance for cold-open.
        let userCoord = service.userCoordinate
            ?? CLLocationCoordinate2D(latitude: 55.67, longitude: 12.57)
        let km = Int(iss.distanceKmFrom(userCoord).rounded())
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 12)
            Text("ISS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .leading)
            Text("\(Int(iss.altitudeKm)) km op")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.75))
            Spacer(minLength: 0)
            Text("\(km) km væk")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    /// Smaller-than-`tile()` glass surface used by the 4-up quadrant. The
    /// main difference: tighter padding + slightly muted title so the 4
    /// sub-tiles don't shout over the big Rute map next door.
    @ViewBuilder
    private func subTile<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Color.white)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    private func miniUsageBar(label: String, percent: Double) -> some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, percent))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: clamped))
                    .frame(width: geo.size.width * CGFloat(clamped))
            }
        }
        .frame(height: 4)
        .padding(.vertical, 2)
    }

    private func barColor(for percent: Double) -> Color {
        if percent >= 0.9 { return UltronTheme.criticalGlow }
        if percent >= 0.75 { return UltronTheme.warningGlow }
        return Color.white.opacity(0.7)
    }

    // MARK: - Shared tile shell

    @ViewBuilder
    private func tile<Content: View>(
        title: String,
        icon: String,
        fullWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        // v1.4 Fase 2c — translucent card, white content. `Color.white.opacity(0.06)`
        // over the navy chat backdrop reads as a subtle glass card without
        // clashing with the shell's gradient. Hairline is also white so
        // nothing cyan/amber leaks into the tile layer.
        //
        // Symmetry: maxHeight: .infinity makes every tile inside its
        // per-row `.fixedSize(vertical: true)` HStack stretch to the
        // tallest sibling's height. All tiles in a row therefore share a
        // height and don't look staggered, which was the v1.4-alpha visual
        // bug on the Cockpit grid.
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    private func infoRow(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 70, alignment: .leading)
            Text(value ?? "—")
                .font(.footnote.monospaced())
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(2)
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.footnote).foregroundStyle(Color.white.opacity(0.6))
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

    /// Split the WiFi info into SSID / signal / rate sub-lines so each
    /// infoRow in the Netværk sub-tile shows one focused fact instead of
    /// a long "SSID · RSSI · Mbps" blob.
    private var wifiSSIDLine: String? {
        guard let ssid = service.systemInfo.wifi?.ssid, !ssid.isEmpty else { return nil }
        return ssid
    }

    private var wifiSignalLine: String? {
        guard let wifi = service.systemInfo.wifi, let rssi = wifi.rssi else { return nil }
        return "\(rssi) dBm · \(wifi.qualityLabel)"
    }

    private var wifiRateLine: String? {
        guard let rate = service.systemInfo.wifi?.transmitRate else { return nil }
        return String(format: "%.0f Mbps", rate)
    }

    /// System uptime as "Xd Yt" / "Xt Ym" / "N min". Derived from the
    /// kernel — no service round-trip needed, so it updates every time
    /// the view re-renders (and the Cockpit re-renders on every tile
    /// refresh + the 15-second Claude poll).
    private var uptimeLine: String? {
        let uptime = Int(ProcessInfo.processInfo.systemUptime)
        let days = uptime / 86_400
        let hours = (uptime % 86_400) / 3600
        let minutes = (uptime % 3600) / 60
        if days > 0 { return "\(days)d \(hours)t" }
        if hours > 0 { return "\(hours)t \(minutes)m" }
        return "\(minutes) min"
    }

    /// Used/total for the boot volume, formatted as "X / Y GB".
    private var diskLine: String? {
        guard let (used, total) = diskUsageGB() else { return nil }
        return String(format: "%.0f / %.0f GB", used, total)
    }

    private var ramUsedPercent: Double? {
        let s = service.systemInfo
        guard let total = s.ramTotalGB, total > 0, let used = s.ramUsedGB else { return nil }
        return used / total
    }

    private var diskUsedPercent: Double? {
        guard let (used, total) = diskUsageGB(), total > 0 else { return nil }
        return used / total
    }

    private func diskUsageGB() -> (used: Double, total: Double)? {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        guard let attrs,
              let total = (attrs[.systemSize] as? NSNumber)?.doubleValue,
              let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue
        else { return nil }
        let gb = 1_000_000_000.0
        return ((total - free) / gb, total / gb)
    }

    /// Danish label for `ProcessInfo.ThermalState` so the Ydelse tile reads
    /// naturally. "Nominel" covers the 95% of the time case.
    private var thermalLabel: String {
        switch service.systemInfo.thermalState {
        case .nominal:  return "Nominel"
        case .fair:     return "Let belastet"
        case .serious:  return "Høj belastning"
        case .critical: return "Kritisk"
        @unknown default: return "Ukendt"
        }
    }

    /// Signal-strength glyph color for the WiFi row in the Handlinger tile.
    private var wifiQualityColor: Color {
        guard let rssi = service.systemInfo.wifi?.rssi else { return Color.white.opacity(0.35) }
        if rssi >= -55 { return Color.white }
        if rssi >= -65 { return Color.white.opacity(0.85) }
        if rssi >= -75 { return UltronTheme.warningGlow }
        return UltronTheme.criticalGlow
    }

    /// Human-readable Bluetooth state + connected count, e.g.
    /// "Bluetooth · 2 enheder" or "Bluetooth · slukket".
    private var bluetoothStatusLine: String {
        guard service.systemInfo.bluetoothPoweredOn else { return "Bluetooth · slukket" }
        let count = service.systemInfo.bluetoothConnectedDevices.count
        if count == 0 { return "Bluetooth · tændt, ingen forbundet" }
        if count == 1 { return "Bluetooth · 1 enhed" }
        return "Bluetooth · \(count) enheder"
    }

    /// Short-form byte count: 1.2 GB, 540 MB, 8.4 KB. Uses decimal (SI) units
    /// because network counters are reported in those by convention.
    private func formatBytes(_ n: UInt64) -> String {
        let value = Double(n)
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000     { return String(format: "%.0f MB", value / 1_000_000) }
        if value >= 1_000         { return String(format: "%.0f KB", value / 1_000) }
        return "\(n) B"
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

    // MARK: - Phase 4c briefing tile

    /// Bottom Cockpit tile that renders the same text `/digest` feeds to the
    /// LLM, so the user can eyeball the context before committing to an AI
    /// round-trip. "Åbn i chat" pre-fills `/digest` via the ultron:// URL
    /// scheme, which AppDelegate's handler drops into the chat command bar.
    @ViewBuilder
    private var briefingTile: some View {
        let context = service.digestContext()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Briefing-kladde", systemImage: "newspaper")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let url = URL(string: "ultron://chat?prompt=/digest")!
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Åbn i chat som /digest", systemImage: "arrowshape.turn.up.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await service.refresh() }
                } label: {
                    Label("Opdater", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(context)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}
