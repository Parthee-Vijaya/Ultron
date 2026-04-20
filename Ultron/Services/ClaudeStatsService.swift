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

    struct ToolStat: Equatable, Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct ModelStat: Equatable, Identifiable {
        let name: String
        let tokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        var id: String { name }

        /// Cache-read share of total — how much of this model's usage was
        /// served from warm context vs. fresh input.
        var cacheRatio: Double {
            tokens > 0 ? Double(cacheReadTokens) / Double(tokens) : 0
        }
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
    /// Top tools used in the most-recently-modified session.
    let latestSessionTools: [ToolStat]
    /// Per-model split across all sessions — useful to see cache efficiency.
    let modelBreakdown: [ModelStat]
    /// Longest recorded session — from stats-cache `longestSession`.
    let longestSessionMessages: Int
    let longestSessionDate: Date?

    static let empty = ClaudeStatsSnapshot(
        totalTokens: 0, totalSessions: 0, totalMessages: 0,
        firstSessionDate: nil, latestSessionTokens: 0,
        latestSessionModel: nil, latestSessionProject: nil,
        todayTokens: 0, weekTokens: 0,
        todayMessages: 0, todaySessions: 0, todayToolCalls: 0,
        totalActiveHours: 0, recentProjects: [],
        latestSessionTools: [], modelBreakdown: [],
        longestSessionMessages: 0, longestSessionDate: nil
    )
}

actor ClaudeStatsService {
    func fetch() async -> ClaudeStatsSnapshot {
        // `~/.claude/stats-cache.json` is a *snapshot* — `lastComputedDate`
        // can lag by a day or more, so totals + today's row silently go
        // stale. We keep the cache for the fields Claude Code already
        // curates (session count, firstSessionDate, longestSession), and
        // derive totals / daily / per-model from a live sweep of the
        // per-session JSONL files instead.
        let cache = loadStatsCache()
        async let aggAsync = aggregateProjects()
        let latest = await findAndSumLatestSession()
        let agg = await aggAsync

        let todayKey = Self.isoDay(Date())
        let todayTokens = agg.dailyTokens[todayKey] ?? 0
        let weekTokens = Self.tokensLastNDays(agg.dailyTokens, count: 7)
        let todayAct = cache.activity(for: todayKey)
        let modelBreakdown = Self.mergedModelBreakdown(
            cacheBreakdown: cache.modelBreakdown,
            liveByModel: agg.modelTokens
        )

        return ClaudeStatsSnapshot(
            totalTokens: agg.totalTokens,
            totalSessions: cache.totalSessions,
            totalMessages: cache.totalMessages,
            firstSessionDate: cache.firstSessionDate,
            latestSessionTokens: latest.totalTokens,
            latestSessionModel: latest.model,
            latestSessionProject: latest.projectLabel,
            todayTokens: todayTokens,
            weekTokens: weekTokens,
            todayMessages: todayAct.messages,
            todaySessions: todayAct.sessions,
            todayToolCalls: todayAct.toolCalls,
            totalActiveHours: agg.activeHours,
            recentProjects: agg.projects,
            latestSessionTools: latest.toolCalls,
            modelBreakdown: modelBreakdown,
            longestSessionMessages: cache.longestSessionMessages,
            longestSessionDate: cache.longestSessionDate
        )
    }

    private static func tokensLastNDays(_ daily: [String: Int], count: Int) -> Int {
        daily.keys.sorted(by: >).prefix(count).reduce(0) { $0 + (daily[$1] ?? 0) }
    }

    /// Prefer JSONL-derived per-model numbers when available (always
    /// fresh). Fall back to the stats-cache entry for models where the
    /// JSONL walk hasn't yet reported data (edge case).
    private static func mergedModelBreakdown(
        cacheBreakdown: [ClaudeStatsSnapshot.ModelStat],
        liveByModel: [String: ModelCounts]
    ) -> [ClaudeStatsSnapshot.ModelStat] {
        var merged: [ClaudeStatsSnapshot.ModelStat] = []
        var seen = Set<String>()
        for (name, counts) in liveByModel {
            let total = counts.input + counts.output + counts.cacheRead + counts.cacheCreate
            merged.append(ClaudeStatsSnapshot.ModelStat(
                name: name,
                tokens: total,
                inputTokens: counts.input,
                outputTokens: counts.output,
                cacheReadTokens: counts.cacheRead
            ))
            seen.insert(name)
        }
        for stat in cacheBreakdown where !seen.contains(stat.name) {
            merged.append(stat)
        }
        return merged.sorted { $0.tokens > $1.tokens }
    }

    struct ModelCounts: Sendable {
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheCreate: Int = 0
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
        // v1.2.1: new surfaces for the Cockpit tile
        var modelBreakdown: [ClaudeStatsSnapshot.ModelStat]
        var longestSessionMessages: Int
        var longestSessionDate: Date?

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
                              dailyTokens: [:], dailyActivity: [:], totalTokensAllTime: 0,
                              modelBreakdown: [], longestSessionMessages: 0, longestSessionDate: nil)
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
        // At the same time, build the per-model breakdown for the Cockpit tile.
        var total = 0
        var modelBreakdown: [ClaudeStatsSnapshot.ModelStat] = []
        if let models = root["modelUsage"] as? [String: [String: Any]] {
            for (model, counts) in models {
                let input = (counts["inputTokens"] as? Int) ?? 0
                let output = (counts["outputTokens"] as? Int) ?? 0
                let cacheRead = (counts["cacheReadInputTokens"] as? Int) ?? 0
                let cacheCreate = (counts["cacheCreationInputTokens"] as? Int) ?? 0
                let modelTotal = input + output + cacheRead + cacheCreate
                total += modelTotal
                modelBreakdown.append(ClaudeStatsSnapshot.ModelStat(
                    name: model,
                    tokens: modelTotal,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead
                ))
            }
            modelBreakdown.sort { $0.tokens > $1.tokens }
        }

        // Longest session — from `longestSession` top-level object.
        var longestMessages = 0
        var longestDate: Date?
        if let longest = root["longestSession"] as? [String: Any] {
            longestMessages = (longest["messageCount"] as? Int) ?? 0
            if let iso = longest["timestamp"] as? String {
                longestDate = Self.parseDate(iso)
            }
        }

        return StatsCache(
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            firstSessionDate: firstDate,
            dailyTokens: daily,
            dailyActivity: activity,
            totalTokensAllTime: total,
            modelBreakdown: modelBreakdown,
            longestSessionMessages: longestMessages,
            longestSessionDate: longestDate
        )
    }

    // MARK: - Project aggregation (top-3 recent + total active hours)

    struct ProjectAggregate: Sendable {
        var projects: [ClaudeStatsSnapshot.ProjectStat]
        var activeHours: Double
        var totalTokens: Int
        var dailyTokens: [String: Int]          // yyyy-MM-dd (local) → tokens
        var modelTokens: [String: ModelCounts]  // "claude-opus-4-7" → split
    }

    /// Walks every `~/.claude/projects/*/*.jsonl` file once, computing:
    /// - per-project token total + most-recent mtime
    /// - summed first-to-last timestamp per session (the "active hours" denom)
    /// - per-day token rollup (today / last 7 days)
    /// - per-model token split (input / output / cache read / cache create)
    ///
    /// Authoritative — stats-cache.json is read for session counts only,
    /// everything else comes from this sweep so totals + today are fresh
    /// the moment Claude Code writes a new JSONL line.
    private func aggregateProjects() async -> ProjectAggregate {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ProjectAggregate(projects: [], activeHours: 0, totalTokens: 0,
                                    dailyTokens: [:], modelTokens: [:])
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<ProjectAggregate, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var perProject: [String: (tokens: Int, lastUsed: Date)] = [:]
                var totalSeconds: Double = 0
                var grandTotalTokens = 0
                var daily: [String: Int] = [:]
                var models: [String: ModelCounts] = [:]

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
                        grandTotalTokens += summary.tokens
                        for (day, t) in summary.dailyTokens {
                            daily[day, default: 0] += t
                        }
                        for (model, counts) in summary.modelTokens {
                            var acc = models[model] ?? ModelCounts()
                            acc.input += counts.input
                            acc.output += counts.output
                            acc.cacheRead += counts.cacheRead
                            acc.cacheCreate += counts.cacheCreate
                            models[model] = acc
                        }

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

                continuation.resume(returning: ProjectAggregate(
                    projects: Array(top),
                    activeHours: totalSeconds / 3600.0,
                    totalTokens: grandTotalTokens,
                    dailyTokens: daily,
                    modelTokens: models
                ))
            }
        }
    }

    /// Fast single-pass scan of a session JSONL file: sum usage tokens,
    /// compute first→last message-timestamp delta, bucket tokens by local
    /// calendar day + by model.
    private struct JSONLSummary {
        let tokens: Int
        let durationSeconds: Double
        let dailyTokens: [String: Int]
        let modelTokens: [String: ModelCounts]
    }

    private static func summarizeJSONL(_ url: URL) -> JSONLSummary {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return JSONLSummary(tokens: 0, durationSeconds: 0, dailyTokens: [:], modelTokens: [:])
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoBasic.date(from: s) }

        var totalTokens = 0
        var first: Date?
        var last: Date?
        var daily: [String: Int] = [:]
        var models: [String: ModelCounts] = [:]

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            var lineDate: Date?
            if let ts = obj["timestamp"] as? String, let d = parse(ts) {
                if first == nil { first = d }
                last = d
                lineDate = d
            }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let model = (message["model"] as? String) ?? "unknown"
            guard let usage = message["usage"] as? [String: Any] else { continue }
            let input      = (usage["input_tokens"] as? Int) ?? 0
            let output     = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead  = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let lineTotal  = input + output + cacheRead + cacheCreate
            totalTokens += lineTotal

            var m = models[model] ?? ModelCounts()
            m.input += input
            m.output += output
            m.cacheRead += cacheRead
            m.cacheCreate += cacheCreate
            models[model] = m

            if let d = lineDate {
                let dayKey = Self.dateFormatter.string(from: d)
                daily[dayKey, default: 0] += lineTotal
            }
        }
        var duration: Double = 0
        if let f = first, let l = last, l > f {
            duration = l.timeIntervalSince(f)
        }
        return JSONLSummary(tokens: totalTokens, durationSeconds: duration,
                            dailyTokens: daily, modelTokens: models)
    }

    // MARK: - Latest session JSONL

    private struct LatestSession {
        var totalTokens: Int
        var model: String?
        var projectLabel: String?
        var toolCalls: [ClaudeStatsSnapshot.ToolStat]
    }

    private func findAndSumLatestSession() async -> LatestSession {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return LatestSession(totalTokens: 0, model: nil, projectLabel: nil, toolCalls: [])
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
            return LatestSession(totalTokens: 0, model: nil, projectLabel: nil, toolCalls: [])
        }

        let parsed = await parseJSONLUsage(url: newest.url)
        return LatestSession(
            totalTokens: parsed.tokens,
            model: parsed.model,
            projectLabel: newest.projectLabel,
            toolCalls: parsed.toolCalls
        )
    }

    private struct JSONLUsageParse {
        let tokens: Int
        let model: String?
        let toolCalls: [ClaudeStatsSnapshot.ToolStat]
    }

    /// Sum all `message.usage` fields in a JSONL file, grab the most-recent
    /// model name, and tally `tool_use` blocks in `message.content` arrays.
    /// v1.2.1: returns the top 5 tools so the Cockpit can render them.
    private func parseJSONLUsage(url: URL) async -> JSONLUsageParse {
        await withCheckedContinuation { (continuation: CheckedContinuation<JSONLUsageParse, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var total = 0
                var latestModel: String?
                var toolCounts: [String: Int] = [:]

                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: JSONLUsageParse(tokens: 0, model: nil, toolCalls: []))
                    return
                }
                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let message = obj["message"] as? [String: Any] else { continue }
                    if let model = message["model"] as? String { latestModel = model }
                    if let usage = message["usage"] as? [String: Any] {
                        for field in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                            total += (usage[field] as? Int) ?? 0
                        }
                    }
                    if let content = message["content"] as? [[String: Any]] {
                        for block in content {
                            if (block["type"] as? String) == "tool_use",
                               let name = block["name"] as? String {
                                toolCounts[name, default: 0] += 1
                            }
                        }
                    }
                }

                let topTools = toolCounts
                    .map { ClaudeStatsSnapshot.ToolStat(name: $0.key, count: $0.value) }
                    .sorted { $0.count > $1.count }
                    .prefix(5)
                    .map { $0 }

                continuation.resume(returning: JSONLUsageParse(
                    tokens: total, model: latestModel, toolCalls: topTools
                ))
            }
        }
    }

    // MARK: - Helpers

    /// `.claude/projects/` uses `-Users-pavi-Claude-projects-Bad-Ultron` as a dir
    /// name (slash → dash). Turn that back into something readable: "Bad/Ultron".
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
