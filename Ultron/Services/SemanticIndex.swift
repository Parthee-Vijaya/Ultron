import Foundation
import NaturalLanguage

/// v1.4 Fase 3: on-device semantic search over saved conversations.
///
/// Uses Apple's `NLEmbedding.sentenceEmbedding(for:)` (shipped in every
/// macOS install — no extra download) to turn each conversation's first
/// user message into a 512-dim vector, then cosine-similarity-ranks those
/// against the user's query. No third-party SPM dep, no SQLite, just a
/// flat in-memory dictionary persisted to a single JSON file.
///
/// Scope trade-offs:
///  - We index only the first user message, not every turn. Keeps the
///    embeddings store tiny and makes query/match semantics intuitive
///    ("find the conversation where I asked about X").
///  - O(n) linear cosine per query. Fine for the realistic ≤1000
///    conversations this app will see. sqlite-vec lands in Fase 3.5 when
///    we actually benchmark past the comfort zone.
///  - Language pinned to danish first, english fallback. Most Ultron
///    prompts are Danish; the English embedder catches the mixed-language
///    case where `NLLanguageRecognizer` says non-Danish.
actor SemanticIndex {
    /// Single process-wide instance — the embedding vocabularies take ~20 MB
    /// of memory each, so we don't want to instantiate this per-caller.
    static let shared = SemanticIndex()

    struct Match: Sendable {
        let id: UUID
        let score: Double  // cosine similarity in [-1, 1]; higher = closer
    }

    /// In-memory store: conversation ID → embedding vector. Hydrated from
    /// disk on first `upsert` / `search` call.
    private var store: [UUID: [Double]] = [:]
    private var hydrated = false

    private let danishEmbedding = NLEmbedding.sentenceEmbedding(for: .danish)
    private let englishEmbedding = NLEmbedding.sentenceEmbedding(for: .english)

    private let persistenceURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ultron", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("semantic-index.json")
    }()

    // MARK: - Public API

    /// Insert or update the embedding for one conversation.
    /// - Parameters:
    ///   - id: conversation identifier.
    ///   - representativeText: the text to embed — typically the first user
    ///     message. Caller ensures it's non-empty; empty text is skipped.
    func upsert(id: UUID, representativeText: String) async {
        hydrateIfNeeded()
        let trimmed = representativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let vector = embed(trimmed) else { return }
        store[id] = vector
        persist()
        await MetricsService.shared.record(phase: .semanticSearch, durationMs: 0, transport: "upsert")
    }

    /// Search returns the top-k conversation IDs ranked by semantic similarity
    /// to the query, along with their scores. Callers typically filter to
    /// matches where `score ≥ 0.35` — below that, the match is weak enough
    /// that plain title substring search is usually better signal.
    func search(query: String, topK: Int = 8) async -> [Match] {
        hydrateIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let qvec = embed(trimmed) else { return [] }

        let start = ContinuousClock.now
        var results: [Match] = []
        results.reserveCapacity(store.count)
        for (id, vec) in store {
            let score = Self.cosine(qvec, vec)
            results.append(Match(id: id, score: score))
        }
        results.sort { $0.score > $1.score }
        let top = Array(results.prefix(topK))

        let elapsed = ContinuousClock.now - start
        let ms = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        await MetricsService.shared.record(phase: .semanticSearch, durationMs: ms, transport: "search")
        return top
    }

    /// Remove a conversation's embedding — called from ConversationStore's
    /// delete / deleteAll hooks so the semantic index doesn't outlive the
    /// conversation it describes.
    func remove(id: UUID) {
        hydrateIfNeeded()
        if store.removeValue(forKey: id) != nil {
            persist()
        }
    }

    func removeAll() {
        hydrateIfNeeded()
        store.removeAll()
        persist()
    }

    // MARK: - Embedding

    /// Try Danish first (most Ultron users); fall back to English on miss.
    /// Returns nil when both embedders fail on the input — typically a
    /// single short word the model can't place.
    private func embed(_ text: String) -> [Double]? {
        if let danishEmbedding, let vec = danishEmbedding.vector(for: text) {
            return vec
        }
        if let englishEmbedding, let vec = englishEmbedding.vector(for: text) {
            return vec
        }
        return nil
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Double = 0
        var magA: Double = 0
        var magB: Double = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = (magA.squareRoot()) * (magB.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Persistence

    private func hydrateIfNeeded() {
        guard !hydrated else { return }
        hydrated = true
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return }
        for (key, vec) in decoded {
            if let id = UUID(uuidString: key) {
                store[id] = vec
            }
        }
    }

    private func persist() {
        var serialisable: [String: [Double]] = [:]
        for (id, vec) in store {
            serialisable[id.uuidString] = vec
        }
        if let data = try? JSONEncoder().encode(serialisable) {
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }
}
