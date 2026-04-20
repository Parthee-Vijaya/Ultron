import AVFoundation
import Foundation
import Observation
import Speech

/// Continuous on-device voice-command listener. When enabled it keeps a
/// `SFSpeechRecognizer` stream running over `SharedAudioEngine` and dispatches
/// to the matching action when the user says something like "Ultron info" or
/// "Ultron update".
///
/// Runs locally — audio never leaves the Mac. Opt-in via Settings toggle, off
/// by default because continuous recognition draws more power than Porcupine.
@MainActor
@Observable
final class VoiceCommandService {
    /// The callback fired on a recognised command. UI layer maps this to the
    /// relevant `HUDWindowController` method.
    enum Command: Equatable {
        case info
        case uptodate
        case chat
        case qna
        case translate
        case summarize
        /// v1.5 Phase 4c: trigger AI-briefing regeneration.
        case digest
    }

    var onCommand: ((Command) -> Void)?
    private(set) var isActive: Bool = false
    private(set) var latestPartial: String = ""
    /// When true the partial-match pipeline is silenced but the recognizer
    /// keeps running in the background. Used during active recording windows
    /// so the recognizer's rolling buffer can't fire a *second* command from
    /// the user's continued speech (e.g. "Ultron spørg hvem er kongen" —
    /// after dispatch of .qna, we don't want the tail "hvem er kongen" to
    /// match another command key).
    private(set) var isSuspended: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var subscriberToken: UUID?

    /// Debounce against repeating a command for a phrase that's still in the
    /// recognizer's rolling buffer.
    private var lastCommand: Command?
    private var lastCommandAt: Date = .distantPast
    private let debounce: TimeInterval = 2.5

    // MARK: - Lifecycle

    /// Ask for speech auth + resolve the best locale. Idempotent.
    func prepare() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            LoggingService.shared.log("VoiceCommand: speech auth not granted (\(status.rawValue))", level: .info)
            return
        }

        let locale = bestSupportedLocale()
        recognizer = SFSpeechRecognizer(locale: locale)
        LoggingService.shared.log("VoiceCommand ready (locale=\(locale.identifier), onDevice=\(recognizer?.supportsOnDeviceRecognition == true))")
    }

    func start() {
        guard !isActive, let recognizer else { return }
        isActive = true

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req

        let engine = SharedAudioEngine.shared
        engine.keepAlive = true
        do {
            try engine.start()
        } catch {
            LoggingService.shared.log("VoiceCommand: engine start failed — \(error)", level: .warning)
            isActive = false
            return
        }

        subscriberToken = engine.addSubscriber { buffer in
            req.append(buffer)
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.latestPartial = text
                    self.handle(partial: text)
                }
                if error != nil {
                    LoggingService.shared.log("VoiceCommand recognition error: \(error?.localizedDescription ?? "unknown")", level: .warning)
                    self.restart()
                }
            }
        }

        LoggingService.shared.log("VoiceCommand listening started")
    }

    func stop() {
        isActive = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let token = subscriberToken {
            SharedAudioEngine.shared.removeSubscriber(token)
            subscriberToken = nil
        }
        SharedAudioEngine.shared.keepAlive = false
        SharedAudioEngine.shared.stopIfIdle()
        latestPartial = ""
    }

    /// Cycle the recognition task — SFSpeechRecognizer has a ~1-minute per-task
    /// cap, so we restart every time we hit an end-of-audio.
    private func restart() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if isActive {
            isActive = false
            start()
        }
    }

    // MARK: - Suspend / resume

    /// Temporarily stop dispatching commands. Call this when the user's current
    /// utterance is already being handled (e.g. a push-to-talk window launched
    /// via voice command) so continued speech doesn't fire another command.
    func suspend() {
        isSuspended = true
    }

    func resume() {
        isSuspended = false
        latestPartial = ""
        // Reset the debounce so the next "ultron X" command isn't held off
        // by the one we just handled.
        lastCommand = nil
        lastCommandAt = .distantPast
    }

    // MARK: - Pattern matching

    private func handle(partial: String) {
        guard !isSuspended else { return }
        let lowered = partial.lowercased()
        guard lowered.contains("ultron") else { return }

        // Slice after the last occurrence of "ultron" so stale prefix text doesn't
        // interfere when the recogniser returns a growing partial transcript.
        guard let range = lowered.range(of: "ultron", options: .backwards) else { return }
        let tail = String(lowered[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return }

        let command: Command?
        switch true {
        case tail.hasPrefix("cockpit"),
             tail.hasPrefix("info"):                     command = .info
        case tail.hasPrefix("briefing"),
             tail.hasPrefix("update"),
             tail.hasPrefix("uptodate"),
             tail.hasPrefix("nyheder"),
             tail.hasPrefix("vejr"):                     command = .uptodate
        case tail.hasPrefix("chat"):                     command = .chat
        case tail.hasPrefix("spørg"),
             tail.hasPrefix("question"),
             tail.hasPrefix("q and a"),
             tail.hasPrefix("qa"):                       command = .qna
        case tail.hasPrefix("oversæt"),
             tail.hasPrefix("translate"):                command = .translate
        case tail.hasPrefix("opsummer"),
             tail.hasPrefix("summarize"):                command = .summarize
        case tail.hasPrefix("digest"),
             tail.hasPrefix("opsamling"),
             tail.hasPrefix("morgenbriefing"):           command = .digest
        default:                                          command = nil
        }

        guard let command else { return }

        let now = Date()
        if lastCommand == command && now.timeIntervalSince(lastCommandAt) < debounce {
            return
        }
        lastCommand = command
        lastCommandAt = now
        LoggingService.shared.log("VoiceCommand: dispatch \(command)")
        onCommand?(command)
    }

    private func bestSupportedLocale() -> Locale {
        let preferred = Locale.current
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(preferred) { return preferred }
        if let da = supported.first(where: { $0.identifier.hasPrefix("da") }) { return da }
        return Locale(identifier: "en_US")
    }
}
