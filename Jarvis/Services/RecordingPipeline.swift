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
        modeManager: ModeManager
    ) {
        self.audioCapture = audioCapture
        self.geminiClient = geminiClient
        self.textInsertion = textInsertion
        self.screenCapture = screenCapture
        self.permissions = permissions
        self.hudController = hudController
        self.ttsService = ttsService
        self.modeManager = modeManager

        setupHUDCallbacks()
        checkCrashRecovery()
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
                instructions: "Jarvis har brug for mikrofonadgang. Åbn Systemindstillinger → Privatliv → Mikrofon og aktivér Jarvis."
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
                instructions: "Jarvis har brug for tilgængelighedsadgang for at indsætte tekst. Åbn Systemindstillinger → Privatliv → Tilgængelighed."
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
        let result: Result<String, Error>

        if let screenshot {
            result = await geminiClient.sendAudioWithImage(audioData, imageData: screenshot, mode: mode)
        } else {
            result = await geminiClient.sendAudio(audioData, mode: mode)
        }

        switch result {
        case .success(let text):
            LoggingService.shared.log("Gemini response: \(text.prefix(100))...")
            deliverResult(text, mode: mode)
        case .failure(let error):
            LoggingService.shared.log("Gemini error: \(error)", level: .error)
            hudController.showError("Fejl: \(error.localizedDescription)")
        }

        resetPipeline()
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
        clearPipelineState()
    }
}
