import AVFoundation
import Foundation
import Observation

/// Phase 4d (v5.1 roadmap) — "Meeting Mode".
///
/// Toggle recording via ⌥⇧N (or menu bar / voice command "Ultron meeting").
/// On stop, WhisperKit transcribes the capture + ProviderRouter summarises
/// into a structured meeting-note chat message. No push-to-talk — the flow
/// is long-form: open, talk for minutes/hours, stop.
///
/// Design:
/// - Reuses the app's shared `AudioCaptureManager`. If push-to-talk is
///   already active we refuse to start (audio engine is single-tenant).
/// - Transcription + summary happen serially after stop, gated by
///   `isProcessing` so the Start/Stop button knows to disable.
/// - The summary itself goes through `TracedAIProvider` so meeting runs
///   show up in Læringsspor with a distinct `taskType=meeting.summary`.
@MainActor
@Observable
final class MeetingRecorderService {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case summarising
        case done(summary: String)
        case error(String)
    }

    private(set) var state: State = .idle

    private let audioCapture: AudioCaptureManager
    private let transcriber: any LocalTranscriber
    /// Injected from AppDelegate — same ProviderRouter used by the briefing
    /// flow so meeting summaries respect local-first routing.
    var providerFactory: (() -> AIProvider)?
    var modelProvider: (() -> String)?
    /// Closure to add the final summary to the chat session. Set by
    /// AppDelegate during wiring.
    var onSummary: ((_ summary: String, _ transcript: String) -> Void)?

    init(audioCapture: AudioCaptureManager, transcriber: any LocalTranscriber) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
    }

    // MARK: - Public

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isProcessing: Bool {
        switch state {
        case .transcribing, .summarising: return true
        default: return false
        }
    }

    /// Toggle recording. Called from hotkey / menu / voice. Safe to invoke
    /// while processing — the call is a no-op if we're not in `.idle` or
    /// `.recording`.
    func toggle() {
        switch state {
        case .idle, .done, .error:
            startRecording()
        case .recording:
            Task { await stopAndProcess() }
        case .transcribing, .summarising:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        do {
            try audioCapture.startRecording()
            state = .recording(startedAt: Date())
            LoggingService.shared.log("Meeting recording started")
        } catch {
            state = .error("Mic-fejl: \(error.localizedDescription)")
            LoggingService.shared.log("Meeting recording start failed: \(error)", level: .warning)
        }
    }

    private func stopAndProcess() async {
        guard case .recording = state else { return }
        let data = audioCapture.stopRecording()
        guard !data.isEmpty else {
            state = .error("Optagelsen var tom.")
            return
        }

        state = .transcribing
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(audioData: data, language: "da")
        } catch {
            state = .error("Transkription fejlede: \(error.localizedDescription)")
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .error("Ingen tale genkendt.")
            return
        }

        state = .summarising
        guard let providerFactory, let modelProvider else {
            // No LLM wired — still surface the raw transcript so the user
            // doesn't lose their notes.
            state = .done(summary: trimmed)
            onSummary?(trimmed, trimmed)
            return
        }

        let provider = providerFactory()
        let traced = TracedAIProvider(inner: provider, type: .auto, taskType: "meeting.summary")
        let model = modelProvider()

        let systemPrompt = """
        Du modtager en transkription fra et møde. Lav et struktureret referat på \
        samme sprog som transkriptionen:

        **Opsummering** — 1-2 sætninger der fanger essensen.
        **Beslutninger** — bullet points med konkrete beslutninger der blev truffet.
        **Action items** — bullet points med ansvar: "NAVN: opgave" hvis en person \
        nævnes; ellers "Ukendt: opgave".
        **Åbne spørgsmål** — ting der ikke blev afgjort.

        Hvis en sektion er tom, skriv "(ingen)" i stedet for at udelade den. Brug \
        markdown. Ingen indledende høfligheder.
        """

        var options = AIRequestOptions(systemPrompt: systemPrompt, maxTokens: 1500)
        options.temperature = 0.2

        do {
            let response = try await traced.send(
                model: model,
                messages: [.user("Transkription:\n\n" + trimmed)],
                options: options
            )
            let summary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                state = .error("LLM returnerede tomt svar.")
                return
            }
            state = .done(summary: summary)
            onSummary?(summary, trimmed)
        } catch {
            state = .error("Opsummering fejlede: \(error.localizedDescription)")
        }
    }
}
