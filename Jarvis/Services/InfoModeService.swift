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

    // Top-level state
    private(set) var state: LoadState = .idle
    private(set) var lastRefresh: Date?

    // Data tiles
    private(set) var weather: WeatherSnapshot?
    private(set) var newsBySource: [NewsHeadline.Source: [NewsHeadline]] = [:]
    private(set) var commute: CommuteEstimate?
    private(set) var commuteError: String?
    private(set) var systemInfo: SystemInfoSnapshot = SystemInfoSnapshot()
    private(set) var claudeStats: ClaudeStatsSnapshot = .empty
    private(set) var airQuality: AirQualitySnapshot?
    private(set) var moon: MoonSnapshot = MoonService.current()
    private(set) var nextEvent: CalendarEventSnapshot?
    private(set) var calendarAccess: CalendarService.AccessState = .notDetermined

    /// Convenience: DR headlines. Kept for call sites that expect it.
    var drHeadlines: [NewsHeadline] { newsBySource[.dr] ?? [] }

    // Async-action state for the manual buttons
    private(set) var isRunningSpeedtest = false
    private(set) var isRunningNetworkScan = false
    private(set) var isRunningCustomCommute = false
    /// Non-nil when the user has typed an ad-hoc destination into the Hjem tile.
    /// Displayed instead of the default home commute; cleared on "Nulstil" or
    /// next manual refresh.
    private(set) var customDestinationAddress: String?

    private let locationService: LocationService
    private let weatherService = WeatherService()
    private let newsService = NewsService()
    private let commuteService = CommuteService()
    private let systemInfoService = SystemInfoService()
    private let claudeStatsService = ClaudeStatsService()
    private let airQualityService = AirQualityService()
    private let calendarService = CalendarService()
    private let cache = InfoCache()

    /// Guards against concurrent `refresh` calls. The view calls `.task` on appear
    /// which can fire multiple times during SwiftUI state churn.
    private var refreshTask: Task<Void, Never>?

    init(locationService: LocationService) {
        self.locationService = locationService
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
                group.addTask { await self.loadAirQualityTile() }
                group.addTask { await self.loadCalendarTile() }
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

    private func loadClaudeTile() async {
        let snap = await claudeStatsService.fetch()
        self.claudeStats = snap
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
        await loadCommuteTile()
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
