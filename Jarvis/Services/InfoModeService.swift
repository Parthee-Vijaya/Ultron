import CoreLocation
import Foundation
import Observation

/// Orchestrates the Info-mode panel: weather + DR top-3 + commute home + system info.
/// Heavy probes (speedtest, network scan) are exposed as explicit actions the panel
/// triggers on user demand.
@MainActor
@Observable
final class InfoModeService {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    /// Whether the active `trafficEvents` list is "nearby the user" or "on
    /// the route to the custom destination". Drives the tile header text.
    enum TrafficScope: Equatable { case nearby, route }

    // Top-level state
    private(set) var state: LoadState = .idle
    private(set) var lastRefresh: Date?

    // Data tiles
    private(set) var weather: WeatherSnapshot?
    private(set) var newsBySource: [NewsHeadline.Source: [NewsHeadline]] = [:]
    private(set) var commute: CommuteEstimate?
    private(set) var commuteError: String?
    /// Weather at the commute destination. Only populated when the user has set
    /// an ad-hoc destination via the Hjem tile; the default home commute doesn't
    /// fetch it because weather-at-home is already in the Vejr tile.
    private(set) var destinationWeather: WeatherSnapshot?
    /// Traffic events (accidents, animals, obstructions, …) from the
    /// Vejdirektoratet feed, filtered to either the user's current location
    /// (default home commute) or a buffer around the active route polyline
    /// (custom destination mode). Capped at 6 to keep the tile compact.
    private(set) var trafficEvents: [TrafficEvent] = []
    private(set) var trafficEventsScope: TrafficScope = .nearby
    private(set) var systemInfo: SystemInfoSnapshot = SystemInfoSnapshot()
    private(set) var claudeStats: ClaudeStatsSnapshot = .empty
    private(set) var airQuality: AirQualitySnapshot?
    private(set) var moon: MoonSnapshot = MoonService.current()
    private(set) var nextEvent: CalendarEventSnapshot?
    private(set) var calendarAccess: CalendarService.AccessState = .notDetermined

    /// Convenience: DR headlines. Kept for call sites that expect it.
    var drHeadlines: [NewsHeadline] { newsBySource[.dr] ?? [] }

    /// Latest known latitude from `LocationService`, exposed read-only for the
    /// Cockpit sun tile's solstice-delta math. `nil` until CoreLocation has
    /// delivered a fix (or the user has geocoded a manual city).
    var latitudeForCockpit: Double? {
        locationService.coordinate?.latitude
    }

    /// Latest known full coordinate. Used by the Himmel tile to compute
    /// ISS-to-user distance without every call site re-deriving it from
    /// `latitudeForCockpit` + hardcoded longitude.
    var userCoordinate: CLLocationCoordinate2D? {
        locationService.coordinate
    }

    // Async-action state for the manual buttons
    private(set) var isRunningSpeedtest = false
    private(set) var isRunningNetworkScan = false
    private(set) var isRunningCustomCommute = false
    /// Non-nil when the user has typed an ad-hoc destination into the Hjem tile.
    /// Displayed instead of the default home commute; cleared on "Nulstil" or
    /// next manual refresh.
    private(set) var customDestinationAddress: String?

    /// Commute estimates to the user's pinned destinations, computed in
    /// parallel on each refresh. Shown side-by-side in the Hjem tile when
    /// no ad-hoc custom destination is active. Keyed by the pinned entry so
    /// the UI can render them in `pinnedDestinations` order without losing
    /// track of partial failures (missing key => geocode/route failed).
    private(set) var pinnedCommutes: [PinnedDestination: CommuteEstimate] = [:]

    /// User-configurable list; defaults to two Tesla-friendly addresses.
    /// Persisted via UserDefaults as JSON so Settings can edit them later.
    private(set) var pinnedDestinations: [PinnedDestination] = PinnedDestination.defaults

    private static let pinnedDestinationsKey = "cockpit.pinnedDestinations"

    private let locationService: LocationService
    private let weatherService = WeatherService()
    private let newsService = NewsService()
    private let commuteService = CommuteService()
    private let systemInfoService = SystemInfoService()
    private let claudeStatsService = ClaudeStatsService()
    private let airQualityService = AirQualityService()
    private let calendarService = CalendarService()
    private let trafficEventsService = TrafficEventsService()
    private let chargerService = ChargerService()
    private let aircraftService = AircraftService()
    private let issService = ISSService()
    private let cache = InfoCache()

    /// EV charger overlays for the Hjem map. 24 h cache in the service.
    /// Denmark-wide — MapKit clips to the visible rect automatically, so we
    /// don't do client-side filtering here.
    private(set) var chargers: [ChargerLocation] = []

    /// Nearest aircraft picked up by adsb.lol within ~50 NM of the user,
    /// sorted closest first. Capped at 8 in the service so the UI can
    /// slice whatever it needs without re-fetching.
    private(set) var aircraftNearby: [Aircraft] = []

    /// Planets currently above the user's horizon. Sorted brightest first;
    /// includes altitude/azimuth so the tile can render e.g. "Jupiter · SV 42°".
    private(set) var visiblePlanets: [PlanetVisibility] = []

    /// ISS current subpoint (lat/lon + altitude + velocity). Refreshed
    /// every 30 s via the live-metrics polling loop.
    private(set) var issPosition: ISSPosition?

    /// Guards against concurrent `refresh` calls. The view calls `.task` on appear
    /// which can fire multiple times during SwiftUI state churn.
    private var refreshTask: Task<Void, Never>?

    init(locationService: LocationService) {
        self.locationService = locationService
        self.pinnedDestinations = Self.loadPinnedDestinations()
    }

    /// Read the pinned destinations JSON blob from UserDefaults. Falls back
    /// to the seed list if the key is missing or decoding fails (e.g. after
    /// a schema change).
    private static func loadPinnedDestinations() -> [PinnedDestination] {
        guard let data = UserDefaults.standard.data(forKey: pinnedDestinationsKey) else {
            return PinnedDestination.defaults
        }
        let decoded = try? JSONDecoder().decode([PinnedDestination].self, from: data)
        return decoded ?? PinnedDestination.defaults
    }

    /// Persist the current pinned-destinations list to UserDefaults. Called
    /// from Settings (future) when the user edits the list.
    func setPinnedDestinations(_ list: [PinnedDestination]) {
        self.pinnedDestinations = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.pinnedDestinationsKey)
        }
        // Re-fill with fresh estimates if we're in home mode.
        Task { await self.loadPinnedCommutesTile() }
    }

    func refresh(force: Bool = false) async {
        if !force, case .loaded = state, let last = lastRefresh, Date().timeIntervalSince(last) < 2 * 60 {
            return
        }

        // Cancel any in-flight refresh so we don't double-paint.
        refreshTask?.cancel()

        // Paint from cache immediately so the panel feels instant on cold opens.
        if !force {
            if let cachedWeather = await cache.loadWeather(fresh: true) {
                self.weather = cachedWeather
            }
            if let cachedNews = await cache.loadNews(fresh: true) {
                self.newsBySource = cachedNews
            }
        }

        state = .loading

        // Each tile runs as its own Task and mutates its own published property
        // as soon as its data is ready. The view (which observes each property
        // individually) paints tile-by-tile instead of waiting on the slowest.
        // Moon phase is a pure local computation — refresh synchronously.
        self.moon = MoonService.current()

        let task = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadSystemTile() }
                group.addTask { await self.loadClaudeTile() }
                group.addTask { await self.loadWeatherTile() }
                group.addTask { await self.loadNewsTile() }
                group.addTask { await self.loadCommuteTile() }
                group.addTask { await self.loadPinnedCommutesTile() }
                group.addTask { await self.loadAirQualityTile() }
                group.addTask { await self.loadCalendarTile() }
                group.addTask { await self.loadTrafficEventsTile() }
                group.addTask { await self.loadChargersTile() }
                group.addTask { await self.loadAircraftTile() }
                group.addTask { await self.loadSkyTile() }
            }
            await MainActor.run {
                self.lastRefresh = Date()
                self.state = .loaded
            }
        }
        refreshTask = task
        await task.value
    }

    // Per-tile loaders. Each mutates exactly one published property, off the
    // critical path of the others.

    private func loadSystemTile() async {
        let snap = await systemInfoService.fetchBasics()
        self.systemInfo = snap
    }

    /// Fast refresh for just the live performance / handling metrics (CPU,
    /// power, thermal, WiFi bytes, Bluetooth). Called from the Cockpit on a
    /// ~10-second loop while visible so the Ydelse + Handlinger sub-tiles
    /// render real-time values. Merges the returned fields into `systemInfo`
    /// so the slower `fetchBasics()` values (battery, RAM, hardware summary,
    /// etc.) aren't clobbered.
    func refreshLiveMetrics() async {
        let live = await systemInfoService.fetchLiveMetrics()
        self.systemInfo.cpuLoadPercent = live.cpuLoadPercent
        self.systemInfo.powerDrawWatts = live.powerDrawWatts
        self.systemInfo.thermalState = live.thermalState
        self.systemInfo.wifiBytesReceived = live.wifiBytesReceived
        self.systemInfo.wifiBytesSent = live.wifiBytesSent
        self.systemInfo.bluetoothPoweredOn = live.bluetoothPoweredOn
        self.systemInfo.bluetoothConnectedDevices = live.bluetoothConnectedDevices
    }

    private func loadClaudeTile() async {
        let snap = await claudeStatsService.fetch()
        self.claudeStats = snap
    }

    /// Lightweight refresh for just the Claude Code tile — bypasses the
    /// 2-minute refresh throttle. The Cockpit view calls this on a 15-second
    /// loop while visible so totals / projects / tools always reflect the
    /// latest `~/.claude/stats-cache.json` state.
    func refreshClaudeStats() async {
        let snap = await claudeStatsService.fetch()
        self.claudeStats = snap
    }

    /// Fly-over-dig + ISS sub-point. Called on a 30-second poll while the
    /// Cockpit is visible so the tiles feel live without hammering the
    /// slow probes on the main 2-min refresh cycle.
    func refreshAircraft() async {
        await loadAircraftTile()
    }

    func refreshISS() async {
        guard let coord = locationService.coordinate else { return }
        let pos = await issService.fetch()
        self.issPosition = pos
        if pos != nil {
            // Recompute visible planets opportunistically on the same
            // cadence so the Himmel tile always reflects "now".
            self.visiblePlanets = PlanetEphemeris.visiblePlanets(
                latitude: coord.latitude,
                longitude: coord.longitude
            )
        }
    }

    private func loadAircraftTile() async {
        guard let coord = locationService.coordinate else {
            self.aircraftNearby = []
            return
        }
        let list = await aircraftService.fetch(near: coord, radiusNM: 50)
        self.aircraftNearby = Array(list.prefix(8))
    }

    /// Combined loader for the Himmel tile — planets are pure local
    /// computation so this is nearly free; ISS is a single cheap GET.
    private func loadSkyTile() async {
        if let coord = locationService.coordinate {
            self.visiblePlanets = PlanetEphemeris.visiblePlanets(
                latitude: coord.latitude,
                longitude: coord.longitude
            )
        }
        self.issPosition = await issService.fetch()
    }

    private func loadWeatherTile() async {
        guard let snap = await loadWeather() else { return }
        self.weather = snap
        await cache.storeWeather(snap)
    }

    private func loadNewsTile() async {
        let news = await newsService.fetchAll(maxPerSource: 3)
        // Don't overwrite cached-good news with a network-failure empty map.
        if news.values.contains(where: { !$0.isEmpty }) {
            self.newsBySource = news
            await cache.storeNews(news)
        }
    }

    private func loadAirQualityTile() async {
        // Reuse whatever coordinate the weather tile settled on.
        let coord: CLLocationCoordinate2D
        if let manual = locationService.manualCity, !manual.isEmpty,
           let (c, _) = await locationService.geocodeManual(manual) {
            coord = c
        } else if let (c, _) = await locationService.refreshWithCity() {
            coord = c
        } else if let home = locationService.homeAddress, !home.isEmpty,
                  let (c, _) = await locationService.geocodeManual(home) {
            coord = c
        } else {
            coord = LocationService.naestvedCoordinate
        }
        self.airQuality = try? await airQualityService.fetch(for: coord)
    }

    private func loadCalendarTile() async {
        self.calendarAccess = calendarService.accessState
        guard calendarService.accessState == .granted else { return }
        self.nextEvent = await calendarService.nextEvent()
    }

    /// Called from the Cockpit UI when the user taps the "Giv adgang"
    /// button on the Kalender tile. Writes the resolved state back so the
    /// tile either shows the next event or a persistent denial message.
    func requestCalendarAccess() async {
        self.calendarAccess = await calendarService.requestAccess()
        if calendarService.accessState == .granted {
            self.nextEvent = await calendarService.nextEvent()
        }
    }

    private func loadCommuteTile() async {
        // If the user has an ad-hoc custom destination active, don't clobber
        // it on the periodic refresh — they'll hit "Nulstil" when they want
        // the default home commute back.
        if customDestinationAddress != nil { return }

        let result = await loadCommute()
        switch result {
        case .success(let est): self.commute = est; self.commuteError = nil
        case .failure(let msg): self.commute = nil; self.commuteError = msg
        }
    }

    /// Compute commute estimates for each `pinnedDestinations` entry in
    /// parallel and publish the successful ones. Partial failures are fine —
    /// the map key simply won't exist for that destination, which the UI
    /// renders as "no card". Only runs when the user is in default home mode;
    /// otherwise we hide the pinned row to keep the tile focused on the
    /// ad-hoc route.
    private func loadPinnedCommutesTile() async {
        guard customDestinationAddress == nil else {
            self.pinnedCommutes = [:]
            return
        }
        guard !pinnedDestinations.isEmpty else {
            self.pinnedCommutes = [:]
            return
        }

        // Resolve origin once — live location if granted, else the same home
        // fallback `recomputeCommute(to:)` uses, so all N fan-out calls share
        // a single starting point.
        let resolvedOrigin: (CLLocationCoordinate2D, String)?
        if let live = await locationService.refreshWithCity() {
            resolvedOrigin = live
        } else {
            resolvedOrigin = await originFallback()
        }
        guard let (coord, label) = resolvedOrigin else {
            self.pinnedCommutes = [:]
            return
        }

        let destinations = pinnedDestinations
        let service = commuteService
        // Run all N estimates concurrently. Each task returns an optional
        // (destination, estimate) pair — nil when that particular route
        // failed, which we silently drop.
        let results: [(PinnedDestination, CommuteEstimate)] = await withTaskGroup(
            of: (PinnedDestination, CommuteEstimate)?.self
        ) { group in
            for dest in destinations {
                group.addTask {
                    do {
                        let est = try await service.estimate(
                            from: coord,
                            originLabel: label,
                            toAddress: dest.address
                        )
                        return (dest, est)
                    } catch {
                        return nil
                    }
                }
            }
            var collected: [(PinnedDestination, CommuteEstimate)] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        var map: [PinnedDestination: CommuteEstimate] = [:]
        for (dest, est) in results { map[dest] = est }
        self.pinnedCommutes = map
    }

    /// Load EV charger overlays (Tesla Superchargers + Clever if the user
    /// has supplied an OCM API key). The service caches for 24 h so even
    /// though we fire this on every refresh, the actual network call is
    /// rare. Failures are swallowed — missing chargers aren't an error
    /// state worth exposing on the main Cockpit surface.
    private func loadChargersTile() async {
        self.chargers = await chargerService.fetchAll()
    }

    /// Fetch Vejdirektoratet's live events feed and re-filter it for the
    /// current context — events near the user by default, or along the
    /// custom-destination route when one is set. Fires on normal refresh
    /// plus on commute recompute.
    private func loadTrafficEventsTile() async {
        do {
            let all = try await trafficEventsService.fetch()
            await applyTrafficFilter(events: all)
        } catch {
            // Feed failures are non-fatal — the tile just hides.
            self.trafficEvents = []
        }
    }

    /// Decide which filter to apply based on whether a custom route is
    /// active and we have a polyline to buffer against.
    private func applyTrafficFilter(events: [TrafficEvent]) async {
        if let commute, !commute.routeCoordinates.isEmpty, customDestinationAddress != nil {
            let filtered = events.alongRoute(commute.routeCoordinates, bufferKm: 1.0)
            self.trafficEvents = Array(filtered.prefix(6))
            self.trafficEventsScope = .route
            return
        }
        // Default: "near me". Origin = live location if available, else the
        // commute origin (which falls back to the home address or Næstved).
        let origin: CLLocationCoordinate2D
        if let live = locationService.coordinate {
            origin = live
        } else if let commute = self.commute {
            origin = commute.origin.clLocationCoordinate
        } else {
            origin = LocationService.naestvedCoordinate
        }
        // 50 km radius so events in the next town over still surface on the
        // Hjem tile. Denmark is small — this still ends up as a focused list
        // because the underlying feed usually only carries 50–100 active
        // events across the whole country.
        let filtered = events.nearby(origin, withinKm: 50)
        self.trafficEvents = Array(filtered.prefix(6))
        self.trafficEventsScope = .nearby
    }

    // MARK: - Manual actions

    func runSpeedtest() async {
        guard !isRunningSpeedtest else { return }
        isRunningSpeedtest = true
        defer { isRunningSpeedtest = false }
        let result = await systemInfoService.runSpeedtest()
        systemInfo.speedtestSummary = result ?? "Kunne ikke køre speedtest."
    }

    func runNetworkScan() async {
        guard !isRunningNetworkScan else { return }
        isRunningNetworkScan = true
        defer { isRunningNetworkScan = false }
        systemInfo.networkScan = await systemInfoService.runNetworkScan()
    }

    /// Recompute the commute row for an ad-hoc address typed into the Hjem
    /// tile. Stays in place until the user hits "Nulstil" or the next forced
    /// refresh — then we revert to the default home commute.
    func recomputeCommute(to address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isRunningCustomCommute else { return }
        isRunningCustomCommute = true
        defer { isRunningCustomCommute = false }

        self.customDestinationAddress = trimmed
        // Ad-hoc route takes over the Hjem tile; drop pinned-destination
        // cards so the user's old numbers don't linger alongside the new
        // focused route.
        self.pinnedCommutes = [:]

        let resolvedOrigin: (CLLocationCoordinate2D, String)?
        if let live = await locationService.refreshWithCity() {
            resolvedOrigin = live
        } else {
            resolvedOrigin = await originFallback()
        }
        guard let (coord, label) = resolvedOrigin else {
            self.commute = nil
            self.commuteError = "Kunne ikke bestemme startpunkt."
            return
        }

        do {
            let estimate = try await commuteService.estimate(
                from: coord,
                originLabel: label,
                toAddress: trimmed
            )
            self.commute = estimate
            self.commuteError = nil
            // Fetch weather at destination as a secondary, best-effort task so
            // the commute tile can show "hvordan er vejret hvor jeg skal hen".
            // Failure is silent — commute text is still useful without it.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await self.weatherService.fetch(
                        for: estimate.destination.clLocationCoordinate,
                        locationLabel: estimate.toLabel
                    )
                    await MainActor.run { self.destinationWeather = snapshot }
                } catch {
                    // Swallow — surface nothing instead of a confusing error.
                }
            }
            // Re-filter the traffic-events feed against the new polyline so
            // the tile switches from "events nearby" to "events on route".
            Task { [weak self] in
                guard let self else { return }
                do {
                    let all = try await self.trafficEventsService.fetch()
                    await self.applyTrafficFilter(events: all)
                } catch {
                    // Non-fatal — leave trafficEvents as-is.
                }
            }
        } catch let error as CommuteError {
            self.commute = nil
            self.commuteError = error.localizedDescription ?? "Ukendt ruteberegningsfejl"
        } catch {
            self.commute = nil
            self.commuteError = error.localizedDescription
        }
    }

    /// Reset to the default home commute. Re-fires the normal loader.
    func resetCustomCommute() async {
        customDestinationAddress = nil
        destinationWeather = nil
        await loadCommuteTile()
        // Re-scope traffic events back to "near me" now the route is gone.
        await loadTrafficEventsTile()
        // Refill pinned-destination cards now we're back in home mode.
        await loadPinnedCommutesTile()
    }

    /// Geocode fallback for when CoreLocation has no fix. Uses the home address
    /// itself so a custom-destination query still produces a result.
    private func originFallback() async -> (CLLocationCoordinate2D, String)? {
        guard let home = locationService.homeAddress, !home.isEmpty,
              let (coord, label) = await locationService.geocodeManual(home) else {
            return nil
        }
        return (coord, label)
    }

    // MARK: - Internals

    private func loadWeather() async -> WeatherSnapshot? {
        // 1. Manual city override from Settings — always wins.
        if let manual = locationService.manualCity, !manual.isEmpty {
            if let (coord, label) = await locationService.geocodeManual(manual) {
                return try? await weatherService.fetch(for: coord, locationLabel: label)
            }
        }
        // 2. Live device location (+ reverse-geocoded city name). Requires
        //    user to have granted Location access at least once.
        if let (coord, label) = await locationService.refreshWithCity() {
            return try? await weatherService.fetch(for: coord, locationLabel: label)
        }
        // 3. Fallback: geocode the home address so the Vejr + Sol tiles still
        //    populate when Location access is absent or in-flight. Without this
        //    the tiles sit on "Henter vejr…" forever on first launch.
        if let home = locationService.homeAddress, !home.isEmpty,
           let (coord, label) = await locationService.geocodeManual(home) {
            return try? await weatherService.fetch(for: coord, locationLabel: label)
        }
        // 4. Last-resort: hit the open-meteo API with Næstved's hardcoded
        //    coordinate. Geocoding may have hung/failed/been rate-limited,
        //    but the weather API itself has no such dependency.
        return try? await weatherService.fetch(
            for: LocationService.naestvedCoordinate,
            locationLabel: LocationService.naestvedLabel
        )
    }

    enum CommuteLoadResult {
        case success(CommuteEstimate)
        case failure(String)
    }

    private func loadCommute() async -> CommuteLoadResult {
        guard let home = locationService.homeAddress, !home.isEmpty else {
            return .failure(CommuteError.missingHomeAddress.localizedDescription ?? "Mangler hjemadresse")
        }
        guard let (coord, label) = await locationService.refreshWithCity() else {
            return .failure(CommuteError.missingCurrentLocation.localizedDescription ?? "Ingen lokation")
        }
        do {
            let estimate = try await commuteService.estimate(
                from: coord,
                originLabel: label,
                toAddress: home
            )
            return .success(estimate)
        } catch let error as CommuteError {
            return .failure(error.localizedDescription ?? "Ukendt ruteberegningsfejl")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
