import Foundation

/// Stale-while-revalidate disk cache for Info-mode tiles. Weather and news each
/// get a JSON snapshot under `~/Library/Caches/Jarvis/`. On Info-mode open we
/// paint from cache immediately, then let the network race in.
actor InfoCache {
    struct WeatherEntry: Codable {
        let snapshot: WeatherSnapshot
        let storedAt: Date
    }

    struct NewsEntry: Codable {
        let bySource: [String: [NewsHeadline]]
        let storedAt: Date
    }

    private let weatherTTL: TimeInterval = 15 * 60
    private let newsTTL: TimeInterval = 10 * 60

    private lazy var cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var weatherURL: URL { cacheDir.appendingPathComponent("weather.json") }
    private var newsURL: URL { cacheDir.appendingPathComponent("news.json") }

    // MARK: - Weather

    /// Returns the cached snapshot if it exists and is still within the TTL.
    /// Set `fresh: false` to accept expired cache as "stale but better than nothing".
    func loadWeather(fresh: Bool = false) -> WeatherSnapshot? {
        guard let data = try? Data(contentsOf: weatherURL),
              let entry = try? JSONDecoder.iso8601.decode(WeatherEntry.self, from: data) else {
            return nil
        }
        if fresh, Date().timeIntervalSince(entry.storedAt) > weatherTTL { return nil }
        return entry.snapshot
    }

    func storeWeather(_ snapshot: WeatherSnapshot) {
        let entry = WeatherEntry(snapshot: snapshot, storedAt: Date())
        guard let data = try? JSONEncoder.iso8601.encode(entry) else { return }
        try? data.write(to: weatherURL, options: .atomic)
    }

    // MARK: - News

    func loadNews(fresh: Bool = false) -> [NewsHeadline.Source: [NewsHeadline]]? {
        guard let data = try? Data(contentsOf: newsURL),
              let entry = try? JSONDecoder.iso8601.decode(NewsEntry.self, from: data) else {
            return nil
        }
        if fresh, Date().timeIntervalSince(entry.storedAt) > newsTTL { return nil }
        var out: [NewsHeadline.Source: [NewsHeadline]] = [:]
        for (key, items) in entry.bySource {
            if let source = NewsHeadline.Source(rawValue: key) { out[source] = items }
        }
        return out
    }

    func storeNews(_ bySource: [NewsHeadline.Source: [NewsHeadline]]) {
        let keyed = Dictionary(uniqueKeysWithValues: bySource.map { ($0.key.rawValue, $0.value) })
        let entry = NewsEntry(bySource: keyed, storedAt: Date())
        guard let data = try? JSONEncoder.iso8601.encode(entry) else { return }
        try? data.write(to: newsURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
