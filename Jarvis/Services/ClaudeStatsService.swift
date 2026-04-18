import Foundation

/// Aggregates Claude Code usage from the files it writes to `~/.claude/`.
///
/// Two data sources:
/// - `~/.claude/stats-cache.json` — all-time per-model totals + daily breakdowns
/// - `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` — per-session message log
///   with `message.usage` blocks we can sum for the "latest session" figure
struct ClaudeStatsSnapshot: Equatable {
    struct ProjectStat: Equatable, Identifiable {
        let label: String
        let tokens: Int
        let lastUsed: Date
        var id: String { label + "@" + String(lastUsed.timeIntervalSince1970) }
    }

    let totalTokens: Int
    let totalSessions: Int
    let totalMessages: Int
    let firstSessionDate: Date?
    /// Tokens used in the most-recently-modified session JSONL.
    let latestSessionTokens: Int
    let latestSessionModel: String?
    let latestSessionProject: String?
    /// Sum of today's dailyModelTokens entry (all models).
    let todayTokens: Int
    /// Sum of the most recent 7 dailyModelTokens entries.
    let weekTokens: Int
    /// Today's activity from stats-cache `dailyActivity`.
    let todayMessages: Int
    let todaySessions: Int
    let todayToolCalls: Int
    /// Summed first-to-last message timestamp across every session JSONL.
    /// Rough "active hours" — idle time within a session still counts.
    let totalActiveHours: Double
    /// Top 3 projects by most-recent modification time.
    let recentProjects: [ProjectStat]

    static let empty = ClaudeStatsSnapshot(
        totalTokens: 0, totalSessions: 0, totalMessages: 0,
        firstSessionDate: nil, latestSessionTokens: 0,
        latestSessionModel: nil, latestSessionProject: nil,
        todayTokens: 0, weekTokens: 0,
        todayMessages: 0, todaySessions: 0, todayToolCalls: 0,
        totalActiveHours: 0, recentProjects: []
    )
}

actor ClaudeStatsService {
    func fetch() async -> ClaudeStatsSnapshot {
        let cache = loadStatsCache()
        async let projectsAgg = aggregateProjects()
        let latest = await findAndSumLatestSession()
        let (projects, activeHours) = await projectsAgg

        let allTimeTokens = cache.totalTokensAllTime
        let today = cache.tokens(for: Self.isoDay(Date()))
        let week = cache.tokensLastNDays(7)
        let todayAct = cache.activity(for: Self.isoDay(Date()))

        return ClaudeStatsSnapshot(
            totalTokens: allTimeTokens,
            totalSessions: cache.totalSessions,
            totalMessages: cache.totalMessages,
            firstSessionDate: cache.firstSessionDate,
            latestSessionTokens: latest.totalTokens,
            latestSessionModel: latest.model,
            latestSessionProject: latest.projectLabel,
            todayTokens: today,
            weekTokens: week,
            todayMessages: todayAct.messages,
            todaySessions: todayAct.sessions,
            todayToolCalls: todayAct.toolCalls,
            totalActiveHours: activeHours,
            recentProjects: projects
        )
    }

    // MARK: - stats-cache.json

    private struct StatsCache {
        struct DayActivity { let messages: Int; let sessions: Int; let toolCalls: Int }

        var totalSessions: Int
        var totalMessages: Int
        var firstSessionDate: Date?
        var dailyTokens: [String: Int]  // date (yyyy-MM-dd) -> sum across models
        var dailyActivity: [String: DayActivity]
        var totalTokensAllTime: Int
        var sortedDescending: [(String, Int)] {
            dailyTokens.sorted { $0.key > $1.key }
        }

        func tokens(for isoDate: String) -> Int { dailyTokens[isoDate] ?? 0 }

        func tokensLastNDays(_ n: Int) -> Int {
            Array(sortedDescending.prefix(n)).reduce(0) { $0 + $1.1 }
        }

        func activity(for isoDate: String) -> DayActivity {
            dailyActivity[isoDate] ?? DayActivity(messages: 0, sessions: 0, toolCalls: 0)
        }
    }

    private func loadStatsCache() -> StatsCache {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return StatsCache(totalSessions: 0, totalMessages: 0, firstSessionDate: nil,
                              dailyTokens: [:], dailyActivity: [:], totalTokensAllTime: 0)
        }

        let totalSessions = (root["totalSessions"] as? Int) ?? 0
        let totalMessages = (root["totalMessages"] as? Int) ?? 0
        var firstDate: Date?
        if let iso = root["firstSessionDate"] as? String {
            firstDate = Self.parseDate(iso)
        }

        // Daily breakdown: sum all models per day.
        var daily: [String: Int] = [:]
        if let entries = root["dailyModelTokens"] as? [[String: Any]] {
            for entry in entries {
                guard let date = entry["date"] as? String,
                      let models = entry["tokensByModel"] as? [String: Int] else { continue }
                daily[date] = models.values.reduce(0, +)
            }
        }

        // Daily activity (message/session/tool-call counts).
        var activity: [String: StatsCache.DayActivity] = [:]
        if let entries = root["dailyActivity"] as? [[String: Any]] {
            for entry in entries {
                guard let date = entry["date"] as? String else { continue }
                activity[date] = StatsCache.DayActivity(
                    messages: (entry["messageCount"] as? Int) ?? 0,
                    sessions: (entry["sessionCount"] as? Int) ?? 0,
                    toolCalls: (entry["toolCallCount"] as? Int) ?? 0
                )
            }
        }

        // All-time total: sum modelUsage fields (includes cache + I/O).
        var total = 0
        if let models = root["modelUsage"] as? [String: [String: Any]] {
            for (_, counts) in models {
                let fields = ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"]
                for field in fields {
                    total += (counts[field] as? Int) ?? 0
                }
            }
        }

        return StatsCache(
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            firstSessionDate: firstDate,
            dailyTokens: daily,
            dailyActivity: activity,
            totalTokensAllTime: total
        )
    }

    // MARK: - Project aggregation (top-3 recent + total active hours)

    /// Walks every `~/.claude/projects/*/`*.jsonl` file once, computing per-project
    /// token totals + most-recent mtime + summed first-to-last timestamp per session
    /// (the denominator for "total hours").
    private func aggregateProjects() async -> ([ClaudeStatsSnapshot.ProjectStat], Double) {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<([ClaudeStatsSnapshot.ProjectStat], Double), Never>) in
            DispatchQueue.global(qos: .utility).async {
                var perProject: [String: (tokens: Int, lastUsed: Date)] = [:]
                var totalSeconds: Double = 0

                for dir in dirs {
                    let label = Self.decodeProjectLabel(from: dir.lastPathComponent)
                    guard let files = try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for file in files where file.pathExtension == "jsonl" {
                        let attrs = (try? file.resourceValues(forKeys: [.contentModificationDateKey])) ?? URLResourceValues()
                        let mtime = attrs.contentModificationDate ?? .distantPast
                        let summary = Self.summarizeJSONL(file)
                        totalSeconds += summary.durationSeconds

                        if var existing = perProject[label] {
                            existing.tokens += summary.tokens
                            if mtime > existing.lastUsed { existing.lastUsed = mtime }
                            perProject[label] = existing
                        } else {
                            perProject[label] = (summary.tokens, mtime)
                        }
                    }
                }

                let top = perProject
                    .map { ClaudeStatsSnapshot.ProjectStat(label: $0.key, tokens: $0.value.tokens, lastUsed: $0.value.lastUsed) }
                    .sorted { $0.lastUsed > $1.lastUsed }
                    .prefix(3)

                continuation.resume(returning: (Array(top), totalSeconds / 3600.0))
            }
        }
    }

    /// Fast single-pass scan of a session JSONL file: sum usage tokens and compute
    /// first→last message-timestamp delta.
    private struct JSONLSummary { let tokens: Int; let durationSeconds: Double }
    private static func summarizeJSONL(_ url: URL) -> JSONLSummary {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return JSONLSummary(tokens: 0, durationSeconds: 0)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoBasic.date(from: s) }

        var tokens = 0
        var first: Date?
        var last: Date?

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let ts = obj["timestamp"] as? String, let d = parse(ts) {
                if first == nil { first = d }
                last = d
            }
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            for field in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                tokens += (usage[field] as? Int) ?? 0
            }
        }
        var duration: Double = 0
        if let f = first, let l = last, l > f {
            duration = l.timeIntervalSince(f)
        }
        return JSONLSummary(tokens: tokens, durationSeconds: duration)
    }

    // MARK: - Latest session JSONL

    private struct LatestSession {
        var totalTokens: Int
        var model: String?
        var projectLabel: String?
    }

    private func findAndSumLatestSession() async -> LatestSession {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return LatestSession(totalTokens: 0, model: nil, projectLabel: nil)
        }

        // Walk each project dir, collect all JSONL files with their mtime.
        var candidates: [(url: URL, mtime: Date, projectLabel: String)] = []
        for dir in projectDirs {
            let label = Self.decodeProjectLabel(from: dir.lastPathComponent)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let attrs = (try? file.resourceValues(forKeys: [.contentModificationDateKey])) ?? URLResourceValues()
                let mtime = attrs.contentModificationDate ?? .distantPast
                candidates.append((file, mtime, label))
            }
        }

        guard let newest = candidates.max(by: { $0.mtime < $1.mtime }) else {
            return LatestSession(totalTokens: 0, model: nil, projectLabel: nil)
        }

        let (total, model) = await parseJSONLUsage(url: newest.url)
        return LatestSession(totalTokens: total, model: model, projectLabel: newest.projectLabel)
    }

    /// Sum all `message.usage` fields in a JSONL file and grab the most-recent model name.
    private func parseJSONLUsage(url: URL) async -> (Int, String?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int, String?), Never>) in
            DispatchQueue.global(qos: .utility).async {
                var total = 0
                var latestModel: String?
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    continuation.resume(returning: (0, nil))
                    return
                }
                defer { try? handle.close() }

                // Read in reasonably-sized chunks and split on newlines.
                let data = handle.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: (0, nil))
                    return
                }
                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8) else { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                    guard let message = obj["message"] as? [String: Any] else { continue }
                    if let model = message["model"] as? String { latestModel = model }
                    guard let usage = message["usage"] as? [String: Any] else { continue }
                    let fields = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    for field in fields {
                        total += (usage[field] as? Int) ?? 0
                    }
                }
                continuation.resume(returning: (total, latestModel))
            }
        }
    }

    // MARK: - Helpers

    /// `.claude/projects/` uses `-Users-pavi-Claude-projects-Bad-Jarvis` as a dir
    /// name (slash → dash). Turn that back into something readable: "Bad/Jarvis".
    static func decodeProjectLabel(from encoded: String) -> String {
        // Strip the leading `-` and replace remaining `-` with `/`.
        var stripped = encoded
        if stripped.hasPrefix("-") { stripped.removeFirst() }
        let components = stripped.split(separator: "-").map(String.init)
        // Return the last two path components joined for brevity.
        if components.count <= 2 { return components.joined(separator: "/") }
        return components.suffix(2).joined(separator: "/")
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        return df
    }()

    private static func isoDay(_ date: Date) -> String { dateFormatter.string(from: date) }

    private static func parseDate(_ string: String) -> Date? {
        if let d = dateFormatter.date(from: string) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: string)
    }
}
