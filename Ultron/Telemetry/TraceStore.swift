import Foundation

/// Append-only JSONL trace log at `~/Library/Logs/Ultron/trace.jsonl`.
///
/// Why JSONL and not SQLite:
/// - Zero dependencies, zero migration story, works on first launch
/// - Durable across crashes (append is atomic at the OS level for ≤ PIPE_BUF)
/// - Debuggable with `tail -f` and `jq`
/// - At ~200 bytes/entry an active user takes years to reach the 10 MB rotation threshold
///
/// Reads load the whole file into memory once per UI refresh — acceptable at
/// this scale. If the Læringsspor pane grows beyond showing raw entries
/// (aggregations, filters, search), swap to SQLite then.
@MainActor
final class TraceStore {
    static let shared = TraceStore()

    private static let rotationBytes: UInt64 = 10 * 1024 * 1024

    private let fileURL: URL
    /// Serial queue so concurrent appends from multiple provider calls don't
    /// interleave partial JSON lines. A single actor-isolated instance would
    /// be nicer but we want nonisolated append path so AIProvider wrappers
    /// don't need to be @MainActor.
    private let writeQueue = DispatchQueue(label: "pavi.Ultron.TraceStore", qos: .utility)

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ultron", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.fileURL = logsDir.appendingPathComponent("trace.jsonl")
    }

    /// Fire-and-forget. Never throws upward — trace failures log a warning
    /// but don't crash the call path.
    nonisolated func append(_ entry: TraceEntry) {
        writeQueue.async { [fileURL] in
            Self.rotateIfNeeded(url: fileURL)
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(entry)
                data.append(0x0A)  // newline

                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                // Fall back to stdout so dev builds still see the problem.
                print("TraceStore.append failed: \(error)")
            }
        }
    }

    /// Net rating for a provider on an optional task type, summed across the
    /// last `lookback` entries. Used by `RoutingPolicy` to deprioritise
    /// providers the user has thumbs-downed. `nil` taskType means "any task".
    ///
    /// Returns 0 when the trace file is missing — same signal as "no opinion yet".
    func ratingSum(provider: String, taskType: String? = nil, lookback: Int = 100) -> Int {
        recent(limit: lookback)
            .filter { $0.provider == provider }
            .filter { taskType == nil || $0.taskType.hasPrefix(taskType!) }
            .map { $0.rating }
            .reduce(0, +)
    }

    /// Read last `limit` entries in reverse-chronological order. Loads the
    /// whole file into memory — acceptable since we rotate at 10 MB.
    func recent(limit: Int = 200) -> [TraceEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [TraceEntry] = []
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(TraceEntry.self, from: lineData) {
                entries.append(entry)
            }
        }
        // Newest first. Take the last N then reverse.
        let tail = entries.suffix(limit)
        return Array(tail.reversed())
    }

    /// Update an existing entry's rating by id. Implemented as rewrite-whole-file
    /// since JSONL doesn't support in-place edits. Only used interactively from
    /// Settings → Læringsspor, so the rewrite cost is a non-issue.
    func rate(id: UUID, rating: Int) {
        writeQueue.async { [fileURL] in
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var rewritten = Data()
            for line in text.split(separator: "\n") {
                guard let lineData = String(line).data(using: .utf8) else { continue }
                if var entry = try? decoder.decode(TraceEntry.self, from: lineData) {
                    if entry.id == id {
                        entry = TraceEntry(
                            id: entry.id,
                            timestamp: entry.timestamp,
                            provider: entry.provider,
                            model: entry.model,
                            taskType: entry.taskType,
                            tokensIn: entry.tokensIn,
                            tokensOut: entry.tokensOut,
                            latencyMs: entry.latencyMs,
                            joulesEst: entry.joulesEst,
                            reason: entry.reason,
                            rating: rating,
                            errorDescription: entry.errorDescription
                        )
                    }
                    if let encoded = try? encoder.encode(entry) {
                        rewritten.append(encoded)
                        rewritten.append(0x0A)
                    }
                }
            }
            try? rewritten.write(to: fileURL, options: .atomic)
        }
    }

    private static func rotateIfNeeded(url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > rotationBytes else { return }
        let archive = url.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? fm.removeItem(at: archive)
        try? fm.moveItem(at: url, to: archive)
    }
}
