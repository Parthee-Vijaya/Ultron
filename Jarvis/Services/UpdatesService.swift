import Foundation
import Observation

/// Coordinates the Uptodate panel: multi-source news (DR/TV2/BBC/CNN + Reddit
/// r/news + Hacker News) + "denne dag i historien" from Wikipedia. Fires
/// everything in parallel so the panel pops in quickly. Caches in memory so
/// re-opening within 5 min is instant.
@MainActor
@Observable
final class UpdatesService {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var news: [NewsHeadline.Source: [NewsHeadline]] = [:]
    private(set) var history: [HistoryEvent] = []
    private(set) var lastRefresh: Date?

    // Parameter retained for API back-compat (AppDelegate wires the
    // locationService in before the weather tile was dropped); we no longer
    // use it but removing it would cascade into every call site.
    private let locationService: LocationService
    private let newsService = NewsService()
    private let historyService = HistoryService()
    private let cacheTTL: TimeInterval = 5 * 60

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    /// Refresh everything. `force=true` bypasses the in-memory cache.
    func refresh(force: Bool = false) async {
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < cacheTTL, state == .loaded {
            return
        }
        state = .loading

        async let newsTask = newsService.fetchAll()
        async let historyTask: [HistoryEvent] = (try? await historyService.fetchToday(limit: 5)) ?? []

        let (newsResult, historyResult) = await (newsTask, historyTask)

        // Don't clobber cached news with an all-empty response — keeps stale
        // headlines on screen if Reddit is temporarily throttling us, etc.
        if newsResult.values.contains(where: { !$0.isEmpty }) {
            self.news = newsResult
        }
        if !historyResult.isEmpty {
            self.history = historyResult
        }

        self.lastRefresh = Date()
        self.state = .loaded
    }
}
