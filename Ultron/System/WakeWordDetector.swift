import Foundation

/// Abstract wake-word listener. Concrete implementation in `PorcupineWakeWordDetector`.
/// The protocol lets us swap engines later (e.g. openWakeWord) without touching callers.
protocol WakeWordDetecting: AnyObject {
    /// Begin listening. The handler fires on the main actor when the wake word is heard.
    func start(onWake: @escaping @MainActor () -> Void) throws
    /// Stop listening and release the audio tap.
    func stop()
    /// True while actively consuming mic frames.
    var isRunning: Bool { get }
}

/// Errors returned from wake-word detection setup.
enum WakeWordError: LocalizedError {
    case porcupineNotIntegrated
    case missingAccessKey
    case audioEngineFailed(underlying: Error)
    case initializationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .porcupineNotIntegrated:
            return "Porcupine SPM-pakken er ikke tilføjet til projektet endnu. Tilføj 'https://github.com/Picovoice/porcupine' via Xcode → File → Add Package Dependencies, og vælg Porcupine-produktet."
        case .missingAccessKey:
            return "Tilføj din Picovoice AccessKey i Settings → Wake Word. Hent en gratis nøgle på https://picovoice.ai/console/"
        case .audioEngineFailed(let error):
            return "Mikrofon-tap fejlede: \(error.localizedDescription)"
        case .initializationFailed(let error):
            return "Kunne ikke starte wake word detector: \(error.localizedDescription)"
        }
    }
}
