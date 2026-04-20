import AVFoundation
import Foundation
import Observation
import Speech

/// On-device live transcription for the HUD. v5.0.0-alpha.4 onward this reads
/// audio from `SharedAudioEngine` instead of owning its own AVAudioEngine,
/// which cuts the start-up latency from ~500 ms to ~100 ms and eliminates the
/// dual-mic tap we had in v4.x.
///
/// Privacy: `requiresOnDeviceRecognition = true` forces recognition to stay on
/// the Mac.
@MainActor
@Observable
final class SpeechRecognitionService {
    /// Current rolling transcription. Updates as the user speaks; cleared on stop.
    var transcript: String = ""

    /// True once authorization is granted and on-device recognition is supported.
    private(set) var isAvailable: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var subscriberToken: UUID?

    /// Request SFSpeech authorization up front; pick a locale supported by
    /// on-device recognition. Safe to call repeatedly.
    func requestAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            LoggingService.shared.log("Speech recognition authorization: \(status.rawValue)", level: .info)
            isAvailable = false
            return
        }
        let locale = bestSupportedLocale()
        recognizer = SFSpeechRecognizer(locale: locale)
        isAvailable = recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true
        LoggingService.shared.log("Speech recognition ready (locale=\(locale.identifier), onDevice=\(isAvailable))")

        // Pre-warm by running a trivial 100 ms silent buffer through the recognizer.
        // Avoids the first real transcription dropping the user's opening word.
        await preWarm()
    }

    /// Start live transcription. Safe to call without authorization — no-ops.
    func start() {
        guard isAvailable, let recognizer else { return }
        stop()  // defensive — clean slate

        transcript = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true

        let engine = SharedAudioEngine.shared
        do {
            try engine.start()
        } catch {
            LoggingService.shared.log("Shared engine start failed for speech: \(error)", level: .warning)
            return
        }

        // Each buffer arrives on the audio thread — SFSpeechAudioBufferRecognitionRequest
        // is safe to append from there per Apple docs.
        subscriberToken = engine.addSubscriber { buffer in
            req.append(buffer)
        }
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let token = subscriberToken {
            SharedAudioEngine.shared.removeSubscriber(token)
            subscriberToken = nil
        }
    }

    func reset() {
        transcript = ""
    }

    // MARK: - Pre-warm

    private func preWarm() async {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        req.requiresOnDeviceRecognition = true

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600) else {
            return
        }
        silentBuffer.frameLength = 1600

        req.append(silentBuffer)
        req.endAudio()

        // Short-lived warm task; ignore result.
        _ = recognizer.recognitionTask(with: req) { _, _ in }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func bestSupportedLocale() -> Locale {
        let preferred = Locale.current
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(preferred) { return preferred }
        if let da = supported.first(where: { $0.identifier.hasPrefix("da") }) { return da }
        return Locale(identifier: "en_US")
    }
}
