import Foundation
import Observation

@Observable
class HUDState {
    enum Phase: Equatable {
        case recording(elapsed: TimeInterval)
        case processing
        case result(text: String)
        case confirmation(message: String)
        case error(message: String)
        case permissionError(permission: String, instructions: String)
        case chat
        case uptodate
        case infoMode

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.recording(let a), .recording(let b)): return a == b
            case (.processing, .processing): return true
            case (.result(let a), .result(let b)): return a == b
            case (.confirmation(let a), .confirmation(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            case (.permissionError(let p1, let i1), .permissionError(let p2, let i2)):
                return p1 == p2 && i1 == i2
            case (.chat, .chat): return true
            case (.uptodate, .uptodate): return true
            case (.infoMode, .infoMode): return true
            default: return false
            }
        }
    }

    var currentPhase: Phase = .processing
    var isVisible = false
    var isPinned = false
    /// v1.4 Fase 2b: the specific stage the voice pipeline is in right now.
    /// Nil means "not processing" — the HUD falls back to a generic
    /// "Behandler…" header. Set by RecordingPipeline + GeminiClient's
    /// grounded-search path.
    var currentStep: ProcessingStep?
    /// v1.4: whether the on-device Whisper model is loaded and ready. When
    /// true + we're in paste-output mode, dictation is fully local and never
    /// leaves the Mac — surfaced in the HUD as a small badge so the user has
    /// a clear "Offline-STT aktiv" signal instead of guessing.
    var localSTTReady: Bool = false
}
