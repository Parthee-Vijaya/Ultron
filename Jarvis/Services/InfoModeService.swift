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

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func refresh(force: Bool = false) async {
        if !force, case .loaded = state, let last = lastRefresh, Date().timeIntervalSince(last) < 2 * 60 {
            return
        }
        state = .loading

        // Fire all tiles in parallel — no tile blocks another.
        async let sysBasics = systemInfoService.fetchBasics()
        async let weatherResult: WeatherSnapshot? = loadWeather()
        async let newsResult: [NewsHeadline.Source: [NewsHeadline]] =
            newsService.fetchAll(maxPerSource: 3)
        async let commuteResult = loadCommute()
        async let claudeResult = claudeStatsService.fetch()

        let (sys, w, news, com, claude) = await (sysBasics, weatherResult, newsResult, commuteResult, claudeResult)

        self.systemInfo = sys
        self.weather = w
        self.newsBySource = news
        self.claudeStats = claude
        switch com {
        case .success(let est): self.commute = est; self.commuteError = nil
        case .failure(let msg): self.commute = nil; self.commuteError = msg
        }
        self.lastRefresh = Date()
        self.state = .loaded
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
