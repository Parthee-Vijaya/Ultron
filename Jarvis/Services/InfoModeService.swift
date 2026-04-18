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

    /// Convenience: DR headlines. Kept for call sites that expect it.
    var drHeadlines: [NewsHeadline] { newsBySource[.dr] ?? [] }

    // Async-action state for the manual buttons
    private(set) var isRunningSpeedtest = false
    private(set) var isRunningNetworkScan = false

    private let locationService: LocationService
    private let weatherService = WeatherService()
    private let newsService = NewsService()
    private let commuteService = CommuteService()
    private let systemInfoService = SystemInfoService()
    private let claudeStatsService = ClaudeStatsService()
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
        let task = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadSystemTile() }
                group.addTask { await self.loadClaudeTile() }
                group.addTask { await self.loadWeatherTile() }
                group.addTask { await self.loadNewsTile() }
                group.addTask { await self.loadCommuteTile() }
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

    private func loadCommuteTile() async {
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

    // MARK: - Internals

    private func loadWeather() async -> WeatherSnapshot? {
        if let manual = locationService.manualCity, !manual.isEmpty {
            if let (coord, label) = await locationService.geocodeManual(manual) {
                return try? await weatherService.fetch(for: coord, locationLabel: label)
            }
        }
        // Await reverse geocode so the tile shows "Næstved" instead of "Din lokation".
        if let (coord, label) = await locationService.refreshWithCity() {
            return try? await weatherService.fetch(for: coord, locationLabel: label)
        }
        return nil
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
