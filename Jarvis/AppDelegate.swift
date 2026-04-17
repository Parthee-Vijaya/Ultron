import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - UI
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var settingsWindow: NSWindow?

    // MARK: - Public (accessed by JarvisApp)
    let modeManager = ModeManager()
    let usageTracker = UsageTracker()

    // MARK: - Services
    private let keychainService = KeychainService()
    private let geminiClient: GeminiClient
    private let hotkeyManager = HotkeyManager()
    private let audioCapture = AudioCaptureManager()
    private let textInsertion = TextInsertionService()
    private let permissions = PermissionsManager()
    private let screenCapture = ScreenCaptureService()
    private let hudController = HUDWindowController()
    private let ttsService = TTSService()

    // MARK: - Pipeline state
    private var recordingState: RecordingState = .idle
    private var activePipelineMode: Mode?
    private var pendingScreenshot: Data?

    override init() {
        self.geminiClient = GeminiClient(keychainService: keychainService, usageTracker: usageTracker)
        super.init()
    }

    // MARK: - App Lifecycle

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            setupMenuBar()
            setupHotkeys()
            setupHUDCallbacks()
            checkFirstLaunch()
            LoggingService.shared.log("Jarvis started")
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis")
            button.image?.isTemplate = true
        }

        rebuildMenu()
    }

    func rebuildMenu() {
        statusMenu = NSMenu()

        let headerItem = NSMenuItem(title: "Jarvis v1.0", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        statusMenu.addItem(headerItem)
        statusMenu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Mode: \(modeManager.activeMode.name)", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        statusMenu.addItem(modeItem)

        let modesItem = NSMenuItem(title: "Switch Mode", action: nil, keyEquivalent: "")
        let modesSubmenu = NSMenu()
        for mode in modeManager.allModes {
            let item = NSMenuItem(title: mode.name, action: #selector(switchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id.uuidString
            if mode.id == modeManager.activeMode.id {
                item.state = .on
            }
            modesSubmenu.addItem(item)
        }
        modesItem.submenu = modesSubmenu
        statusMenu.addItem(modesItem)

        statusMenu.addItem(NSMenuItem.separator())

        let usageItem = NSMenuItem(title: usageTracker.formattedUsage, action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        statusMenu.addItem(usageItem)

        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        statusMenu.items.last?.target = self

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = statusMenu
    }

    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let uuid = UUID(uuidString: idString) else { return }
        modeManager.setActiveMode(byId: uuid)
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
                .environment(modeManager)
                .environment(usageTracker)
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Jarvis Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 500, height: 450))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Bar Icon State

    func updateMenuBarIcon(state: RecordingState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis")
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
        case .processing:
            button.image = NSImage(systemSymbolName: "gear.circle", accessibilityDescription: "Processing")
            button.contentTintColor = .systemOrange
        }
        button.image?.isTemplate = (state == .idle)
    }

    // MARK: - Hotkey Setup

    private func setupHotkeys() {
        // ⌥Space: Push-to-talk with active mode
        hotkeyManager.onDictationKeyDown = { [weak self] in
            self?.handleRecordStart(mode: nil, captureScreen: false)
        }
        hotkeyManager.onDictationKeyUp = { [weak self] in
            self?.handleRecordStop()
        }

        // ⌥Q: Push-to-talk in Q&A mode
        hotkeyManager.onQnAKeyDown = { [weak self] in
            self?.handleRecordStart(mode: BuiltInModes.qna, captureScreen: false)
        }
        hotkeyManager.onQnAKeyUp = { [weak self] in
            self?.handleRecordStop()
        }

        // ⌥⇧Space: Push-to-talk in Vision mode (captures screenshot on start)
        hotkeyManager.onVisionKeyDown = { [weak self] in
            self?.handleRecordStart(mode: BuiltInModes.vision, captureScreen: true)
        }
        hotkeyManager.onVisionKeyUp = { [weak self] in
            self?.handleRecordStop()
        }

        // ⌥M: Cycle modes
        hotkeyManager.onModeCycle = { [weak self] in
            guard let self else { return }
            self.modeManager.cycleMode()
            self.rebuildMenu()
            LoggingService.shared.log("Mode cycled to: \(self.modeManager.activeMode.name)")
        }

        hotkeyManager.registerHotkeys()
    }

    // MARK: - Recording Pipeline

    /// Start recording. If mode is nil, uses active mode. If captureScreen is true, captures screenshot first.
    private func handleRecordStart(mode: Mode?, captureScreen: Bool) {
        guard recordingState == .idle else { return }

        let pipelineMode = mode ?? modeManager.activeMode
        activePipelineMode = pipelineMode

        // Check microphone permission
        guard permissions.checkMicrophone() else {
            LoggingService.shared.log("Microphone permission not granted", level: .error)
            Task {
                let granted = await AudioPermissionHelper.requestMicrophonePermission()
                if !granted {
                    LoggingService.shared.log("Microphone permission denied", level: .error)
                }
            }
            return
        }

        // Check accessibility for paste modes
        if pipelineMode.outputType == .paste && !permissions.checkAccessibility() {
            LoggingService.shared.log("Accessibility permission not granted", level: .error)
            permissions.openAccessibilitySettings()
            return
        }

        // Capture screenshot for Vision mode before recording starts
        if captureScreen {
            Task {
                do {
                    let screenshot = try await screenCapture.captureActiveWindow()
                    self.pendingScreenshot = screenshot
                    LoggingService.shared.log("Vision screenshot captured (\(screenshot.count) bytes)")
                    self.startAudioRecording()
                } catch {
                    LoggingService.shared.log("Screenshot failed: \(error)", level: .error)
                    self.showError("Kunne ikke tage screenshot: \(error.localizedDescription)")
                }
            }
        } else {
            startAudioRecording()
        }
    }

    private func startAudioRecording() {
        do {
            try audioCapture.startRecording()
            recordingState = .recording
            updateMenuBarIcon(state: .recording)
        } catch {
            LoggingService.shared.log("Audio recording failed: \(error)", level: .error)
            showError("Mikrofonoptagelse fejlede: \(error.localizedDescription)")
            activePipelineMode = nil
            pendingScreenshot = nil
        }
    }

    private func handleRecordStop() {
        guard recordingState == .recording else { return }

        let audioData = audioCapture.stopRecording()
        recordingState = .processing
        updateMenuBarIcon(state: .processing)

        guard let pipelineMode = activePipelineMode else {
            resetPipeline()
            return
        }

        let screenshot = pendingScreenshot

        Task {
            await processRecording(audioData: audioData, screenshot: screenshot, mode: pipelineMode)
        }
    }

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
            showError("Fejl: \(error.localizedDescription)")
        }

        resetPipeline()
    }

    private func deliverResult(_ text: String, mode: Mode) {
        switch mode.outputType {
        case .paste:
            let success = textInsertion.insertText(text)
            if !success {
                LoggingService.shared.log("Text insertion failed, showing in HUD", level: .warning)
                hudController.show(content: text)
            }
        case .hud:
            hudController.show(content: text)
            ttsService.speak(text)
        }
    }

    private func showError(_ message: String) {
        hudController.show(content: "⚠️ \(message)")
    }

    // MARK: - HUD & TTS

    private func setupHUDCallbacks() {
        hudController.onSpeakRequested = { [weak self] text in
            self?.ttsService.speakAlways(text)
        }
    }

    // MARK: - First Launch

    private func checkFirstLaunch() {
        let hasLaunched = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunched {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            showOnboarding()
        }
    }

    private var onboardingWindow: NSWindow?

    private func showOnboarding() {
        let onboardingView = OnboardingView(
            onComplete: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            },
            onOpenSettings: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.openSettings()
            }
        )
        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Jarvis"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func resetPipeline() {
        recordingState = .idle
        updateMenuBarIcon(state: .idle)
        activePipelineMode = nil
        pendingScreenshot = nil
        rebuildMenu()
    }
}

enum RecordingState {
    case idle, recording, processing
}
