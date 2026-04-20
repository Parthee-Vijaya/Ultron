import Foundation

/// Pure-function policy: given a set of inputs, decide which provider should
/// answer. No side effects, no state — trivial to test + to reason about.
///
/// Phase 3d scope: simple "local first" rule with escalation triggers.
/// Phase 3e will add `TraceStore`-driven weighting (if the user consistently
/// thumbs-down Ollama on a task type, prefer cloud next time).
struct RoutingPolicy {
    struct Inputs {
        let taskType: String           // "chat", "digest", "agent", "vision"
        let hasVision: Bool            // request contains image parts
        let hasToolUse: Bool           // options.tools is non-empty
        let estimatedTokens: Int       // input size heuristic (system prompt + user text)
        let ollamaAvailable: Bool      // probed recently; false → skip local
        let onBattery: Bool
        let batteryPercent: Double?    // nil on desktops → treat as high
        let userPreference: AIProviderType?  // explicit override from Mode settings
        /// Phase 3e feedback loop: net ratings per provider from TraceStore
        /// for this task type. Positive = user liked, negative = user disliked.
        /// Providers with a rating ≤ `penaltyThreshold` are skipped in favour
        /// of the next option in the chain.
        let ratingByProvider: [AIProviderType: Int]
    }

    struct Decision: Equatable {
        let provider: AIProviderType
        let reason: String
    }

    /// Providers whose accumulated rating is <= this value get passed over
    /// in favour of the next eligible option.
    static let penaltyThreshold = -2

    /// The rules, in priority order:
    /// 1. User explicitly picked a provider on the Mode → honour it.
    /// 2. Vision → must go cloud (Gemini) — no local vision model wired yet.
    /// 3. No Ollama daemon → cloud fallback. Default Gemini.
    /// 4. Complex tool-use + long prompt → prefer Claude (better agent loop).
    /// 5. On battery < 30% → prefer cloud to conserve battery.
    /// 6. Default → Ollama local-first.
    ///
    /// After rule selection, any pick with `ratingByProvider[pick] <= -2` is
    /// replaced with the next-best option from the escalation chain Ollama →
    /// Anthropic → Gemini (skipping whichever the user has down-voted).
    static func decide(_ inputs: Inputs) -> Decision {
        let initial = initialDecision(inputs)
        // Honour user override + vision fast-paths verbatim — feedback on
        // those categories should be handled at the rating-UI layer (e.g. a
        // "disable vision routing" toggle), not by silent escalation.
        if initial.reason == "user override" || initial.reason == "vision capability required" {
            return initial
        }

        if penalised(initial.provider, inputs: inputs) {
            for fallback in escalationChain(excluding: initial.provider, inputs: inputs) {
                if !penalised(fallback, inputs: inputs) {
                    return Decision(
                        provider: fallback,
                        reason: "escalated from \(initial.provider.rawValue) (user rating ≤ \(penaltyThreshold))"
                    )
                }
            }
        }
        return initial
    }

    private static func initialDecision(_ inputs: Inputs) -> Decision {
        if let pref = inputs.userPreference {
            return Decision(provider: pref, reason: "user override")
        }
        if inputs.hasVision {
            return Decision(provider: .gemini, reason: "vision capability required")
        }
        if !inputs.ollamaAvailable {
            return Decision(provider: .gemini, reason: "Ollama daemon not running")
        }
        if inputs.hasToolUse && inputs.estimatedTokens > 4000 {
            return Decision(provider: .anthropic, reason: "long tool-use session (Claude)")
        }
        if inputs.onBattery, let pct = inputs.batteryPercent, pct < 0.30 {
            return Decision(provider: .gemini, reason: "low battery — conserve cycles")
        }
        return Decision(provider: .ollama, reason: "local-first")
    }

    private static func penalised(_ provider: AIProviderType, inputs: Inputs) -> Bool {
        (inputs.ratingByProvider[provider] ?? 0) <= penaltyThreshold
    }

    /// Escalation order for "routing away from X". Skips the excluded provider
    /// + providers that would violate prerequisites (no Ollama when the daemon
    /// is down).
    private static func escalationChain(excluding initial: AIProviderType, inputs: Inputs) -> [AIProviderType] {
        var chain: [AIProviderType] = [.ollama, .anthropic, .gemini]
        chain.removeAll { $0 == initial }
        if !inputs.ollamaAvailable { chain.removeAll { $0 == .ollama } }
        return chain
    }
}
