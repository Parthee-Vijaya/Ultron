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
    }

    struct Decision: Equatable {
        let provider: AIProviderType
        let reason: String
    }

    /// The rules, in priority order:
    /// 1. User explicitly picked a provider on the Mode → honour it.
    /// 2. Vision → must go cloud (Gemini) — no local vision model wired yet.
    /// 3. No Ollama daemon → cloud fallback. Default Gemini.
    /// 4. Complex tool-use + long prompt → prefer Claude (better agent loop).
    /// 5. On battery < 30% → prefer cloud to conserve battery.
    /// 6. Default → Ollama local-first.
    static func decide(_ inputs: Inputs) -> Decision {
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
}
