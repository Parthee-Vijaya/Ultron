import AppKit

class RecordingPipeline {
    // MARK: - Dependencies
    private let audioCapture: AudioCaptureManager
    private let geminiClient: GeminiClient
    private let textInsertion: TextInsertionService
    private let screenCapture: ScreenCaptureService
    private let permissions: PermissionsManager
    private let hudController: HUDWindowController
    private let ttsService: TTSService
    private let modeManager: ModeManager
    /// v1.3: local speech-to-text via WhisperKit (when the SPM package is
    /// wired up) or a no-op fallback otherwise. When `isReady` is false the
    /// pipeline silently uses the legacy Gemini audio path.
    private let localTranscriber: any LocalTranscriber

    // MARK: - Pipeline State
    private var recordingState: RecordingState = .idle
    private var activePipelineMode: Mode?
    private var pendingScreenshot: Data?
    private var isPreparing = false
    private var pendingStartTask: Task<Void, Never>?

    var onStateChanged: ((RecordingState) -> Void)?

    init(
        audioCapture: AudioCaptureManager,
        geminiClient: GeminiClient,
        textInsertion: TextInsertionService,
        screenCapture: ScreenCaptureService,
        permissions: PermissionsManager,
        hudController: HUDWindowController,
        ttsService: TTSService,
        modeManager: ModeManager,
        localTranscriber: (any LocalTranscriber)? = nil
    ) {
        self.audioCapture = audioCapture
        self.geminiClient = geminiClient
        self.textInsertion = textInsertion
        self.screenCapture = screenCapture
        self.permissions = permissions
        self.hudController = hudController
        self.ttsService = ttsService
        self.modeManager = modeManager
        self.localTranscriber = localTranscriber ?? LocalTranscribers.makeDefault()

        setupHUDCallbacks()
        checkCrashRecovery()

        // Kick off model preload in the background so the first real
        // transcription doesn't wait for ANE compilation. If WhisperKit isn't
        // wired up, `preload()` is a no-op on the NoOp transcriber. Errors
        // are logged, not swallowed — we'd rather see a failed preload in
        // ultron.log than silently fall back to the Gemini audio path forever.
        Task { [transcriber = self.localTranscriber, hud = self.hudController] in
            do {
                try await transcriber.preload()
                let ready = await transcriber.isReady
                await MainActor.run { hud.hudState.localSTTReady = ready }
            } catch {
                LoggingService.shared.log("LocalTranscriber preload failed, falling back to Gemini audio: \(error)", level: .error)
            }
        }
    }

    // MARK: - Public API

    func handleRecordStart(mode: Mode?, captureScreen: Bool) {
        // Reject re-entry during active record/process/prepare phases.
        guard recordingState == .idle, !isPreparing else {
            LoggingService.shared.log("Record start ignored — pipeline busy (state=\(recordingState), preparing=\(isPreparing))", level: .warning)
            return
        }

        let pipelineMode = mode ?? modeManager.activeMode
        activePipelineMode = pipelineMode

        // Check microphone permission
        guard permissions.checkMicrophone() else {
            hudController.showPermissionError(
                permission: "Mikrofon",
                instructions: "Ultron har brug for mikrofonadgang. Åbn Systemindstillinger → Privatliv → Mikrofon og aktivér Ultron."
            )
            hudController.onPermissionAction = { [weak self] in
                self?.permissions.openMicrophoneSettings()
            }
            Task {
                let granted = await AudioPermissionHelper.requestMicrophonePermission()
                if !granted {
                    LoggingService.shared.log("Microphone permission denied", level: .error)
                }
            }
            resetPipeline()
            return
        }

        // Check accessibility for paste modes
        if pipelineMode.outputType == .paste && !permissions.checkAccessibility() {
            hudController.showPermissionError(
                permission: "Tilgængelighed",
                instructions: "Ultron har brug for tilgængelighedsadgang for at indsætte tekst. Åbn Systemindstillinger → Privatliv → Tilgængelighed."
            )
            hudController.onPermissionAction = { [weak self] in
                self?.permissions.openAccessibilitySettings()
            }
            resetPipeline()
            return
        }

        // Update HUD metadata before presenting — mode badge + clear any stale transcript.
        hudController.activeModeName = pipelineMode.name
        hudController.speechService.reset()
        hudController.speechService.start()

        // Always show HUD when hotkey pressed
        hudController.showRecording()

        // Capture screenshot for Vision mode before recording starts
        if captureScreen {
            isPreparing = true
            pendingStartTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.isPreparing = false
                    self.pendingStartTask = nil
                }
                do {
                    let screenshot = try await captureScreenWithFallback()
                    guard !Task.isCancelled else { return }
                    self.pendingScreenshot = screenshot
                    LoggingService.shared.log("Vision screenshot captured (\(screenshot.count) bytes)")
                    self.startAudioRecording()
                } catch {
                    if Task.isCancelled { return }
                    LoggingService.shared.log("Screenshot failed: \(error)", level: .error)
                    self.hudController.showError("Kunne ikke tage screenshot: \(error.localizedDescription)")
                    self.resetPipeline()
                }
            }
        } else {
            startAudioRecording()
        }
    }

    func handleRecordStop() {
        // If user released hotkey before the preparation (screenshot) finished,
        // cancel the pending start and clean up — treat as a cancellation, not an error.
        if isPreparing, let task = pendingStartTask {
            LoggingService.shared.log("Record stop during prepare — cancelling pending start")
            task.cancel()
            pendingStartTask = nil
            isPreparing = false
            hudController.speechService.stop()
            hudController.close()
            resetPipeline()
            return
        }

        guard recordingState == .recording else { return }

        let audioData = audioCapture.stopRecording()
        hudController.speechService.stop()
        recordingState = .processing
        onStateChanged?(.processing)

        // Show processing state in HUD
        hudController.showProcessing()

        guard let pipelineMode = activePipelineMode else {
            resetPipeline()
            return
        }

        let screenshot = pendingScreenshot

        // Persist state for crash recovery
        savePipelineState()

        Task {
            await processRecording(audioData: audioData, screenshot: screenshot, mode: pipelineMode)
        }
    }

    // MARK: - Audio Recording

    private func startAudioRecording() {
        do {
            try audioCapture.startRecording()
            recordingState = .recording
            onStateChanged?(.recording)
        } catch {
            LoggingService.shared.log("Audio recording failed: \(error)", level: .error)
            hudController.showError("Mikrofonoptagelse fejlede: \(error.localizedDescription)")
            resetPipeline()
        }
    }

    // MARK: - Processing

    private func processRecording(audioData: Data, screenshot: Data?, mode: Mode) async {
        // v1.3 two-path flow.
        //
        // Paste-output modes (Dictation / VibeCode / Professional / Translate):
        // try local Whisper first. If the user wants text at their cursor,
        // WhisperKit-tiny's occasional tyde-fejl is recoverable (they can
        // proofread) and the latency saved is huge.
        //
        // HUD-output modes (Q&A / Vision) ALWAYS go through Gemini audio.
        // Gemini's built-in STT is far better than whisper-tiny, and a bad
        // local transcript here cascades into web-search hits on the wrong
        // query → refuse-to-answer failures. This preserves v1.2 behaviour
        // for those modes.
        let result: Result<String, Error>
        // v1.4: explicit flag beats "outputType == .paste" proxy. Falls back
        // to the old proxy for legacy Mode JSON that was decoded before the
        // flag existed — older custom modes still behave identically.
        let preferLocal = mode.preferLocalTranscription || mode.outputType == .paste

        if preferLocal, let text = await transcribeLocally(audioData), !text.isEmpty {
            LoggingService.shared.log("Local transcript (\(text.count) chars) [\(mode.name)]: \(text.prefix(80))…")
            result = await callModel(prompt: text, screenshot: screenshot, mode: mode, transport: "text-after-local-stt")
        } else {
            if preferLocal {
                LoggingService.shared.log("Local STT unavailable or empty — using Gemini audio [\(mode.name)]", level: .info)
            }
            result = await callModelWithAudio(audioData: audioData, screenshot: screenshot, mode: mode)
        }

        switch result {
        case .success(let text):
            LoggingService.shared.log("Model response: \(text.prefix(100))...")
            deliverResult(text, mode: mode)
        case .failure(let error):
            LoggingService.shared.log("Model error: \(error)", level: .error)
            // v1.4 Fase 2b.5: offer a retry handler on transient failures
            // (network blips, server 5xx, timeout). Non-transient errors —
            // missing API key, bad request, safety-block — don't get a
            // retry button because replaying the same input won't help.
            let retry = Self.isTransient(error) ? { [weak self, audioData, screenshot, mode] in
                guard let self else { return }
                Task { await self.processRecording(audioData: audioData, screenshot: screenshot, mode: mode) }
            } : nil
            hudController.showError("Fejl: \(error.localizedDescription)", retryHandler: retry)
        }

        resetPipeline()
    }

    /// Classify whether an error is worth retrying with the same input.
    /// Mirrors the classifier in `GeminiClient.isTransientError` but widened
    /// to Anthropic / URL / HTTP surfaces so the HUD retry button lights up
    /// consistently across providers.
    private static func isTransient(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let transient = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                             NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost]
            if transient.contains(ns.code) { return true }
        }
        if let rest = error as? GeminiRESTError,
           case .httpError(let code, _) = rest,
           (500..<600).contains(code) {
            return true
        }
        return false
    }

    /// Run local STT if available. Returns nil when the transcriber isn't
    /// ready, the audio is silent, or the engine threw — all of which fall
    /// back to the legacy Gemini audio path. Emits a `.transcribe` metric
    /// on both success and failure (via `MetricsService.time`).
    private func transcribeLocally(_ audioData: Data) async -> String? {
        guard await localTranscriber.isReady else { return nil }
        hudController.setStep(ProcessingStep.Kind.transcribing(transport: "local-whisper"))
        do {
            let text = try await MetricsService.shared.time(.transcribe, transport: "local-whisper") {
                try await self.localTranscriber.transcribe(audioData: audioData, language: "da")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        } catch {
            LoggingService.shared.log("Local transcribe failed, falling back to Gemini audio: \(error)", level: .warning)
            return nil
        }
    }

    /// Text-to-model call (used after local STT succeeded). Timing wrapped
    /// through `MetricsService.time` so `modelCall` latency is recorded
    /// identically on success + failure.
    private func callModel(prompt: String, screenshot: Data?, mode: Mode, transport: String) async -> Result<String, Error> {
        hudController.setStep(mode.webSearch ? ProcessingStep.Kind.searchingWeb(query: prompt) : ProcessingStep.Kind.thinking(provider: "Gemini"))
        return await MetricsService.shared.time(.modelCall, mode: mode.name, transport: transport) {
            if let screenshot {
                return await self.geminiClient.sendTextWithImage(prompt: prompt, mode: mode, imageData: screenshot)
            } else {
                return await self.geminiClient.sendText(prompt: prompt, mode: mode)
            }
        }
    }

    /// Legacy path: audio → Gemini (Gemini transcribes internally). Retained
    /// as a fallback for when WhisperKit isn't loaded yet. Emits the same
    /// `.modelCall` metric tagged `gemini-audio` so we can compare the two
    /// transports directly in the histogram.
    private func callModelWithAudio(audioData: Data, screenshot: Data?, mode: Mode) async -> Result<String, Error> {
        hudController.setStep(ProcessingStep.Kind.transcribing(transport: "gemini-audio"))
        return await MetricsService.shared.time(.modelCall, mode: mode.name, transport: "gemini-audio") {
            if let screenshot {
                return await self.geminiClient.sendAudioWithImage(audioData, imageData: screenshot, mode: mode)
            } else {
                return await self.geminiClient.sendAudio(audioData, mode: mode)
            }
        }
    }

    // MARK: - Result Delivery

    private func deliverResult(_ text: String, mode: Mode) {
        LoggingService.shared.log("deliverResult: outputType=\(mode.outputType.rawValue), textChars=\(text.count)")
        switch mode.outputType {
        case .paste:
            let success = textInsertion.insertText(text)
            if success {
                hudController.showConfirmation("Tekst indsat")
            } else {
                LoggingService.shared.log("Text insertion failed, showing in HUD", level: .warning)
                hudController.showResult(text)
            }
            // v1.3: Dictation (and any future mode that opts in) also writes
            // the transcription to the clipboard AND Notes.app so there's a
            // persistent record. Fire-and-forget — shouldn't delay the paste.
            if mode.persistToNotes {
                DictationPersistence.save(text)
            }
        case .hud:
            LoggingService.shared.log("→ HUD showResult (\(text.prefix(80))...)")
            hudController.showResult(text)
            ttsService.speak(text)
        case .chat:
            // Chat output is handled by ChatPipeline
            break
        }
    }

    // MARK: - Screenshot with Fallback

    private func captureScreenWithFallback() async throws -> Data {
        do {
            return try await screenCapture.captureActiveWindow()
        } catch {
            LoggingService.shared.log("Active window capture failed, falling back to full screen", level: .warning)
            return try await screenCapture.captureFullScreen()
        }
    }

    // MARK: - Max Recording Callback

    private func setupHUDCallbacks() {
        hudController.onMaxRecordingReached = { [weak self] in
            guard let self, self.recordingState == .recording else { return }
            LoggingService.shared.log("Max recording duration reached, auto-stopping")
            self.handleRecordStop()
        }

        hudController.onSpeakRequested = { [weak self] text in
            self?.ttsService.speakAlways(text)
        }
    }

    // MARK: - Crash Recovery

    private func savePipelineState() {
        UserDefaults.standard.set(true, forKey: Constants.crashRecoveryKey)
    }

    func checkCrashRecovery() {
        let wasProcessing = UserDefaults.standard.bool(forKey: Constants.crashRecoveryKey)
        if wasProcessing {
            LoggingService.shared.log("Crash recovery: previous session was interrupted during processing", level: .warning)
            clearPipelineState()
        }
    }

    private func clearPipelineState() {
        UserDefaults.standard.removeObject(forKey: Constants.crashRecoveryKey)
    }

    // MARK: - Reset

    func resetPipeline() {
        recordingState = .idle
        onStateChanged?(.idle)
        activePipelineMode = nil
        pendingScreenshot = nil
        hudController.setStep(ProcessingStep.Kind?.none)
        clearPipelineState()
    }
}
