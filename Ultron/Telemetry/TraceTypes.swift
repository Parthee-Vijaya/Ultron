import Foundation

/// One row in the trace log. Emitted by `TracedAIProvider` whenever an LLM
/// call completes (success or failure). The trace is append-only JSONL so it
/// survives crashes and can be inspected after the fact.
///
/// The schema is forward-compatible: new fields must be optional, existing
/// fields must never change type. Consumers decode on a best-effort basis —
/// unknown keys are ignored by JSONDecoder.
struct TraceEntry: Codable, Identifiable {
    /// Monotonic UUID so entries stay unique across concurrent writers.
    let id: UUID
    /// Wall-clock time the entry was finalised.
    let timestamp: Date
    /// Which concrete provider answered ("anthropic", "gemini", "ollama").
    let provider: String
    /// Model identifier passed to the provider.
    let model: String
    /// Free-form label from the call site ("chat", "agent", "digest", "vision").
    let taskType: String
    let tokensIn: Int
    let tokensOut: Int
    let latencyMs: Int
    /// Rough joules estimate — non-zero for local models, 0 for cloud calls
    /// (cloud cost is tracked via UsageTracker in dollars, not energy).
    let joulesEst: Double
    /// Why the router picked this provider (e.g. "local-first", "vision capability",
    /// "user override"). Blank when the call came through a direct (non-routed)
    /// provider.
    let reason: String
    /// User feedback: 1 = thumbs-up, -1 = thumbs-down, 0 = unrated. Mutated
    /// in place by the Læringsspor UI via TraceStore.rate(id:rating:).
    var rating: Int
    /// Populated only when the call failed — localized error description.
    let errorDescription: String?
}
