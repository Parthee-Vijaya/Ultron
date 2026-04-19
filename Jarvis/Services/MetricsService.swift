import Foundation

/// Per-phase latency + event metrics for the voice pipeline. New in v1.3 as
/// groundwork for Fase 1 (Instant Voice) — gives us visible P50/P95/P99 for
/// each step of the record → transcribe → model → paste loop so we can measure
/// the impact of switching from Gemini audio-transcription to local Whisper.
///
/// Samples are kept in memory (ring buffer, last 1000 per phase) and appended
/// to `~/Library/Logs/Jarvis/metrics.jsonl` so they survive restarts for post-
/// hoc analysis. Nothing is sent off-device.
actor MetricsService {
    static let shared = MetricsService()

    /// Each phase the voice/chat pipeline moves through. String-backed so new
    /// phases can be added without breaking historical JSONL parsing.
    enum Phase: String, Codable, Sendable {
        case record          // mic tap open → user released hotkey
        case transcribe      // audio blob → text (local or remote)
        case modelCall       // text → AI response (Gemini or Anthropic)
        case paste           // response → text inserted at cursor
        case screenCapture   // active-window screenshot (Vision mode)
        case searchWeb       // WebSearchService round-trip
        case semanticSearch  // Fase 3: embedding query → top-k matches
    }

    struct Sample: Codable, Sendable {
        let phase: Phase
        let durationMs: Int
        let mode: String?       // mode.name if known
        let transport: String?  // "local-whisper" | "gemini-audio" | "sfspeech" | …
        let timestamp: Date
    }

    struct Histogram: Sendable {
        let phase: Phase
        let count: Int
        let p50: Int
        let p95: Int
        let p99: Int
        let mean: Int
    }

    /// In-memory rolling window, newest-first. Capped per phase so an always-on
    /// session doesn't grow unboundedly.
    private var buffer: [Phase: [Sample]] = [:]
    private let maxPerPhase = 1000

    private let jsonlURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metrics.jsonl")
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private init() {}

    // MARK: - Record

    /// Record a single sample. Fire-and-forget from callers — the actor
    /// serialises the disk append so callers never block on I/O.
    func record(phase: Phase, durationMs: Int, mode: String? = nil, transport: String? = nil) {
        let sample = Sample(phase: phase, durationMs: durationMs, mode: mode, transport: transport, timestamp: Date())
        var bucket = buffer[phase] ?? []
        bucket.insert(sample, at: 0)
        if bucket.count > maxPerPhase { bucket.removeLast(bucket.count - maxPerPhase) }
        buffer[phase] = bucket

        appendJSONL(sample)
    }

    /// Convenience for the common "time this block" pattern. Both success
    /// and failure durations are recorded so we can see transcribe P95 even
    /// when some calls throw (e.g. Gemini 503).
    ///
    /// ```swift
    /// let text = try await MetricsService.shared.time(.transcribe, transport: "whisper-kit") {
    ///     try await whisper.transcribe(audioData: audio)
    /// }
    /// ```
    func time<T>(_ phase: Phase, mode: String? = nil, transport: String? = nil, _ op: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try await op()
            recordElapsed(phase, from: start, mode: mode, transport: transport)
            return result
        } catch {
            recordElapsed(phase, from: start, mode: mode, transport: transport)
            throw error
        }
    }

    private func recordElapsed(_ phase: Phase, from start: ContinuousClock.Instant, mode: String?, transport: String?) {
        let elapsed = ContinuousClock.now - start
        let ms = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        record(phase: phase, durationMs: ms, mode: mode, transport: transport)
    }

    // MARK: - Query

    func histogram(_ phase: Phase) -> Histogram? {
        let samples = buffer[phase] ?? []
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.durationMs).sorted()
        let n = sorted.count
        func percentile(_ p: Double) -> Int {
            let idx = min(n - 1, Int(Double(n - 1) * p))
            return sorted[idx]
        }
        let mean = sorted.reduce(0, +) / n
        return Histogram(phase: phase, count: n, p50: percentile(0.50), p95: percentile(0.95), p99: percentile(0.99), mean: mean)
    }

    /// Snapshot every phase we've seen — useful for Cockpit tile rendering.
    func allHistograms() -> [Histogram] {
        buffer.keys.compactMap { histogram($0) }.sorted { $0.phase.rawValue < $1.phase.rawValue }
    }

    // MARK: - Disk

    private func appendJSONL(_ sample: Sample) {
        guard let data = try? encoder.encode(sample) else { return }
        guard var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { return }

        // Bootstrap: create the file on the first write. Once it exists, any
        // transient FileHandle failure is logged and the sample dropped —
        // we never want a partial write fallback to *replace* the existing
        // log with one row, which the naive .atomic write above used to do.
        let fm = FileManager.default
        if !fm.fileExists(atPath: jsonlURL.path) {
            try? bytes.write(to: jsonlURL, options: .atomic)
            return
        }

        // v1.4: rotate at 10 MB — matches the pattern in LoggingService
        // (which rolls at 5 MB). Metrics are more verbose per-entry so a
        // higher cap keeps a month of typical usage in a single file before
        // rolling. One level of .1 retention is enough for post-hoc analysis.
        rotateIfNeeded()

        guard let handle = try? FileHandle(forWritingTo: jsonlURL) else {
            LoggingService.shared.log("MetricsService: could not open \(jsonlURL.lastPathComponent) for append; dropping sample", level: .warning)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
    }

    private func rotateIfNeeded() {
        let cap: UInt64 = 10 * 1_024 * 1_024
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: jsonlURL.path),
              let size = attrs[.size] as? UInt64,
              size >= cap else { return }

        let rotatedURL = jsonlURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: jsonlURL, to: rotatedURL)
    }
}
