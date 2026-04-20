import Foundation
import IOKit.ps

/// Coarse energy estimator for LLM calls. Reads battery state via IOKit power
/// sources and returns a joules-per-call estimate keyed off token counts + a
/// conservative per-token energy model.
///
/// Accuracy is intentionally rough — the goal is relative comparison ("Ollama
/// saved ~X joules vs cloud on the last 20 calls") not wall-power audit.
/// Refining the model (measuring real draw via `powermetrics`) is tracked
/// for a later phase.
@MainActor
final class EnergyMonitor {
    static let shared = EnergyMonitor()

    struct BatteryState {
        /// 0.0 – 1.0. `nil` on desktops or when the IOKit query fails.
        let chargePercent: Double?
        /// True when the machine is plugged in.
        let onAC: Bool
    }

    private init() {}

    /// Current battery state. Cheap enough (~microseconds) to call per LLM
    /// request, no need to cache.
    func currentState() -> BatteryState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryState(chargePercent: nil, onAC: true)
        }
        var percent: Double?
        var onAC = true
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Double(capacity) / Double(max)
            }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                onAC = (state == kIOPSACPowerValue)
            }
        }
        return BatteryState(chargePercent: percent, onAC: onAC)
    }

    /// Joules estimate for a completed LLM call. Non-zero only for local
    /// providers — cloud calls have their energy cost accounted for by the
    /// provider's infrastructure, not ours.
    ///
    /// Constants come from published Apple Silicon M-series power measurements:
    /// a 3B-parameter Q4 model draws ~8 W during sustained inference and
    /// produces ~60 tokens/s, giving ~0.13 J/token. Larger models scale roughly
    /// linearly with parameter count.
    func estimateJoules(provider: AIProviderType, model: String, tokensOut: Int) -> Double {
        guard provider.isLocal, tokensOut > 0 else { return 0 }
        let perTokenJoules = Self.perTokenJoules(model: model)
        return Double(tokensOut) * perTokenJoules
    }

    private static func perTokenJoules(model: String) -> Double {
        let lower = model.lowercased()
        // Rough buckets by parameter size. Keep conservative — under-reporting
        // is less harmful than over-reporting the "you saved X joules" story.
        if lower.contains("70b") || lower.contains("20b") { return 0.8 }
        if lower.contains("13b") || lower.contains("14b") { return 0.35 }
        if lower.contains("7b")  || lower.contains("8b")  { return 0.2  }
        if lower.contains("3b")  || lower.contains("llama3.2") { return 0.13 }
        if lower.contains("1b") || lower.contains("0.5b") { return 0.06 }
        return 0.25  // fallback for unknown local models
    }
}
