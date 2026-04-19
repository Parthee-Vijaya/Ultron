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
            VStack(spacing: 12) {
                // Two 3-tile rows up top — Vejr/Sol/Nyheder and Luft/Måne/
                // Kalender. Per-row `.fixedSize(vertical: true)` means the
                // HStack's height = tallest child, so the other two tiles
                // stretch to match (via the `.frame(maxHeight: .infinity)`
                // in the tile shell). Safe here because the fixedSize is
                // scoped per row, not applied at the panel root — the
                // v1.2.3 crash was caused by the latter.
                tilesRow.fixedSize(horizontal: false, vertical: true)
                airAndMoonRow.fixedSize(horizontal: false, vertical: true)

                // Commute tile owns a full-width row: internally it now
                // splits horizontally (stats/chips/traffic/pinned/input on
                // the left, map + charger legend on the right), which keeps
                // the overall tile shorter than the old vertically-stacked
                // layout could.
                commuteTile.fixedSize(horizontal: false, vertical: true)

                // Claude-stats, system and network keep a 2-col pairing so
                // the panel reads symmetrically after the wide commute row.
                HStack(alignment: .top, spacing: 12) {
                    claudeStatsTile
                    systemTile
                }
                .fixedSize(horizontal: false, vertical: true)

                networkActions.fixedSize(horizontal: false, vertical: true)
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
        .jarvisChatBackdrop()
        .task { await service.refresh() }
    }

    // MARK: - Header (chat-family minimal chrome)

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            JarvisWordmark(fontSize: 13)
            Text("Cockpit")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(JarvisTheme.textPrimary)
                .padding(.leading, 4)
            if let last = service.lastRefresh {
                Text("opdateret \(timeAgo(last))")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textMuted)
            }
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

    /// Slim top-right icon button matching the one on `ChatView.chatTopBar`
    /// so Cockpit's chrome reads identically.
    private func topChromeButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JarvisTheme.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(JarvisTheme.surfaceElevated.opacity(0.55))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Tiles row (weather + news + commute)

    private var tilesRow: some View {
        HStack(alignment: .top, spacing: 12) {
            weatherTile
            sunTile
            newsTile
        }
    }

    private var airAndMoonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            airQualityTile
            moonTile
            calendarTile
        }
    }

    private var calendarTile: some View {
        tile(title: "Kalender", icon: "calendar") {
            switch service.calendarAccess {
            case .granted:
                if let event = service.nextEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(event.prettyStart)
                            .font(.caption)
                            .foregroundStyle(Color.white)
                        if let minutes = event.minutesUntilStart, minutes > 0 {
                            Text("om \(minutes) min")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                        if let location = event.location, !location.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.caption)
                                Text(location)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                } else {
                    Text("Ingen events de næste 7 dage")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            case .notDetermined:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Giv adgang til din kalender for at se næste event her.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Button("Giv adgang") {
                        Task { await service.requestCalendarAccess() }
                    }
                    .controlSize(.small)
                }
            case .denied, .writeOnly:
                Text("Kalender-adgang blokeret i System-indstillinger.")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }

    private var airQualityTile: some View {
        tile(title: "Luft & UV", icon: "aqi.medium") {
            if let air = service.airQuality {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(air.europeanAQI.map(String.init) ?? "—")
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("AQI")
                                    .font(.caption).foregroundStyle(Color.white.opacity(0.55))
                            }
                            Text(air.aqiBand.label)
                                .font(.caption)
                                .foregroundStyle(aqiColor(air.aqiBand))
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(air.uvIndex.map { String(format: "%.1f", $0) } ?? "—")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("UV")
                                    .font(.caption).foregroundStyle(Color.white.opacity(0.55))
                            }
                            Text(air.uvBand.label)
                                .font(.caption)
                                .foregroundStyle(uvColor(air.uvBand))
                        }
                    }
                    if let pm25 = air.pm25 {
                        Text(String(format: "PM2.5: %.1f µg/m³", pm25))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
            } else {
                placeholder("Henter luft…")
            }
        }
    }

    private var moonTile: some View {
        let m = service.moon
        return tile(title: "Måne", icon: "moon.fill") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: m.phase.symbol)
                    .font(.system(size: 36))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.white.opacity(0.6), radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.phase.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("\(m.illuminationPercent) % oplyst")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("Næste fuldmåne \(Self.fullMoonFormatter.string(from: m.nextFullMoon))")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func aqiColor(_ band: AirQualitySnapshot.AQIBand) -> Color {
        switch band {
        case .excellent, .good: return Color.white
        case .moderate:         return Color.white
        case .poor:             return JarvisTheme.warningGlow
        case .veryPoor, .extreme: return JarvisTheme.criticalGlow
        case .unknown:          return Color.white.opacity(0.55)
        }
    }

    private func uvColor(_ band: AirQualitySnapshot.UVBand) -> Color {
        switch band {
        case .low:              return Color.white
        case .moderate:         return Color.white
        case .high:             return JarvisTheme.warningGlow
        case .veryHigh, .extreme: return JarvisTheme.criticalGlow
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
            // Horizontal split, laid out per the user's sketch:
            //   Left  — Pinnede destinationer (stacked) + Live-trafik chip
            //           + Trafikinfo section + input row. Flexible width.
            //   Right — "0 min til X" stats on TOP, then the map below.
            //           Fixed 340pt wide so stats + map stay prominent.
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    pinnedDestinationsRow
                    commuteChipsRow
                    trafficEventsSection
                    destinationInputRow
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 10) {
                    commuteStatsColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    commuteMapColumn
                }
                .frame(width: 340)
            }
        }
    }

    /// Map + charger legend. Fixed 255pt tall (25% shorter than the
    /// previous 340pt so the whole tile fits on a laptop screen without
    /// scrolling) — the map is still zoomable, so lost area can be
    /// recovered interactively.
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
                .frame(height: 255)
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
            // Placeholder keeps the column reserved while the route is
            // still computing — otherwise the left column would reflow
            // to full-width mid-refresh.
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
                .frame(height: 255)
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
        case .accident:      return JarvisTheme.criticalGlow
        case .obstruction:   return JarvisTheme.warningGlow
        case .animal, .roadCondition: return JarvisTheme.warningGlow
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
        case .heavy:   return JarvisTheme.warningGlow
        case .severe:  return JarvisTheme.criticalGlow
        case .unknown: return Color.white.opacity(0.5)
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
                .padding(.top, 6)
            }

            if !s.latestSessionTools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top tools (seneste session)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    HStack(spacing: 6) {
                        ForEach(s.latestSessionTools) { tool in
                            HStack(spacing: 3) {
                                Image(systemName: toolIcon(tool.name))
                                    .font(.caption)
                                Text("\(tool.name)")
                                    .font(.caption)
                                Text("\(tool.count)")
                                    .font(.caption2.weight(.semibold).monospaced())
                                    .foregroundStyle(Color.white)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(JarvisTheme.surfaceBase.opacity(0.6))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                            )
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .padding(.top, 6)
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
                                .frame(width: 80, alignment: .leading)
                            modelBar(model: m)
                            Spacer(minLength: 6)
                            Text(formatTokens(m.tokens))
                                .font(.footnote.monospaced())
                                .foregroundStyle(Color.white)
                            Text(String(format: "cache %.0f%%", m.cacheRatio * 100))
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 6)
            }

            if s.longestSessionMessages > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("Længste session: \(s.longestSessionMessages) beskeder")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                    if let date = s.longestSessionDate {
                        Text("· \(firstSessionFormatter.string(from: date))")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .padding(.top, 4)
            }
        }
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
                .fill(JarvisTheme.surfaceBase.opacity(0.6))
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
            return Color.white
        }()
        // Bar width is pinned to the outer panel minus padding/other columns —
        // hardcoded to keep the hosting-controller's content size stable (see
        // InfoModeView.body comment on why GeometryReader is banned here).
        let barWidth: CGFloat = 640
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text(budgetRow(used: used, limit: limit))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(JarvisTheme.surfaceBase.opacity(0.8))
                Capsule()
                    .fill(barColor)
                    .frame(width: barWidth * CGFloat(fraction))
                    .shadow(color: barColor.opacity(0.6), radius: 3)
                    .animation(JarvisTheme.spring, value: fraction)
            }
            .frame(maxWidth: barWidth, maxHeight: 6)
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
                    .tint(Color.white)
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
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(JarvisTheme.surfaceBase.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !service.systemInfo.networkScan.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(service.systemInfo.networkScan.count) enheder fundet")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                        ForEach(service.systemInfo.networkScan.prefix(8)) { device in
                            HStack {
                                Text(device.ip)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text(device.mac)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        if service.systemInfo.networkScan.count > 8 {
                            Text("+ \(service.systemInfo.networkScan.count - 8) yderligere")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.5))
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
