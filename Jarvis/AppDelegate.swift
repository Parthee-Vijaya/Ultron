import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - UI
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let settingsHostState = SettingsHostState()

    // Menu items updated in-place
    private var modeMenuItem: NSMenuItem?
    private var usageMenuItem: NSMenuItem?
    private var modesSubmenuItem: NSMenuItem?

    // MARK: - Public (accessed by JarvisApp)
    let modeManager = ModeManager()
    let usageTracker = UsageTracker()
    lazy var hotkeyBindings = HotkeyBindings(store: hotkeyStore, manager: hotkeyManager)

    // MARK: - Services
    private let keychainService = KeychainService()
    private let hotkeyManager = HotkeyManager()
    private let hotkeyStore = HotkeyStore()
    private let hudController = HUDWindowController()
    private var pipeline: RecordingPipeline!
    let chatSession = ChatSession()
    private var chatPipeline: ChatPipeline!
    private lazy var wakeWordDetector: WakeWordDetecting = PorcupineWakeWordDetector(
        accessKeyProvider: { [weak keychainService] in keychainService?.getPorcupineKey() }
    )
    let voiceCommandService = VoiceCommandService()
    /// β.11: agent chat now shares the main chat session so the unified
    /// Spotlight-style chat window renders regular chat + agent turns in one
    /// conversation. Kept as a computed alias so legacy call sites still
    /// resolve without edits.
    /// v1.1.5: agent mode now uses the shared `chatSession` directly.
    private var agentChatPipeline: AgentChatPipeline?
    private var commandRouter: ChatCommandRouter?
    /// Shared buffer for the chat command-bar text field. Lets
    /// `handleChatVoiceToggle` push dictation transcripts back into the UI.
    private let chatInputBuffer = ChatInputBuffer()
    let locationService = LocationService()
    lazy var updatesService = UpdatesService(locationService: locationService)
    lazy var infoModeService = InfoModeService(locationService: locationService)
    lazy var errorPresenter = ErrorPresenter(hudController: hudController)
    private lazy var summaryService = DocumentSummaryService(
        geminiClient: geminiClient,
        hudController: hudController,
        errorPresenter: errorPresenter
    )

    // Supporting services (owned here, injected into pipeline)
    private let audioCapture = AudioCaptureManager()
    private let textInsertion = TextInsertionService()
    private let permissions = PermissionsManager()
    private let screenCapture = ScreenCaptureService()
    private let ttsService = TTSService()
    private lazy var geminiClient = GeminiClient(keychainService: keychainService, usageTracker: usageTracker)

    // MARK: - App Lifecycle

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            setupPipeline()
            setupChatPipeline()
            setupMenuBar()
            setupHotkeys()
            hotkeyBindings.applyAll()
            setupCostWarning()
            setupWakeWord()
            setupVoiceCommands()
            checkFirstLaunch()
            // v1.1.7: spawn any MCP servers the user declared in ~/.jarvis/mcp.json
            // and register their tools with the shared agent registry. Runs in
            // the background — we don't block app launch if a server is slow.
            Task { await MCPRegistry.shared.bootstrap() }
            // v1.4 Fase 4 slice: register ourselves as a services-menu
            // provider so "Ask Jarvis about this" appears in every app's
            // Services submenu for selected text. The Info.plist NSServices
            // array advertises the action; this call tells AppKit we're
            // ready to handle it.
            NSApplication.shared.servicesProvider = self
            NSUpdateDynamicServices()
            // v1.2.0: ping GitHub Releases once a day to see if a newer
            // Jarvis DMG is published. Non-blocking; prompts only when a
            // higher semver is found.
            updateChecker.checkIfDue()
            LoggingService.shared.log("Jarvis v\(Constants.appVersion) started")
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MCPRegistry.shared.shutdown()
        }
    }

    // MARK: - Services menu (v1.4 Fase 4 slice)

    /// Called by AppKit when the user picks "Ask Jarvis about this" from any
    /// app's Services submenu. The `NSMessage` key in Info.plist maps this
    /// selector; pasteboard contains the selected plain text.
    ///
    /// Behaviour: pull the text, route it through the chat as a Q&A-mode
    /// prompt, and show the HUD. Matches the `open jarvis://qna?prompt=…`
    /// URL scheme flow so the handling is unified.
    @objc func askJarvisAboutSelection(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            LoggingService.shared.log("Services: empty pasteboard — nothing to ask", level: .warning)
            return
        }
        LoggingService.shared.log("Services: ask Jarvis about \(text.count)-char selection")
        // Reuse the same chat-opening path the ⌥C hotkey uses. Route through
        // the chat command router in Q&A mode so web-search grounds the reply.
        Task { @MainActor in
            hudController.showChat()
            await commandRouter?.run(mode: BuiltInModes.qna, input: text)
        }
    }

    /// v1.1.8: handle incoming `jarvis://…` URLs from the OS / Shortcuts /
    /// automation tools. Supported:
    ///   - jarvis://chat?prompt=TEXT      — open chat, pre-fill the bar
    ///   - jarvis://qna?prompt=TEXT       — run Q&A with the given prompt
    ///   - jarvis://summarize             — open picker + summarize
    ///   - jarvis://vision?prompt=TEXT    — capture screen + ask
    ///   - jarvis://info / ://briefing    — open the respective panel
    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { handleJarvisURL(url) }
        }
    }

    private func handleJarvisURL(_ url: URL) {
        guard url.scheme?.lowercased() == "jarvis" else { return }
        let action = (url.host ?? "").lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let prompt = components?.queryItems?.first(where: { $0.name == "prompt" })?.value ?? ""

        switch action {
        case "chat":
            refreshConversationHistory()
            hudController.showChat()
            if !prompt.isEmpty { chatInputBuffer.text = prompt }
        case "qna":
            refreshConversationHistory()
            hudController.showChat()
            if !prompt.isEmpty, let router = commandRouter {
                Task { await router.run(mode: BuiltInModes.qna, input: prompt) }
            }
        case "summarize":
            summaryService.summarizeInteractively()
        case "vision":
            refreshConversationHistory()
            hudController.showChat()
            if let router = commandRouter {
                Task { await router.run(mode: BuiltInModes.vision, input: prompt) }
            }
        case "info", "cockpit":
            hudController.showInfoMode()
        case "briefing", "uptodate":
            hudController.showUptodate()
        default:
            LoggingService.shared.log("Unknown jarvis:// action: \(action)", level: .warning)
        }
    }

    // MARK: - Pipeline Setup

    private func setupPipeline() {
        // Wire the mic tap's RMS + peak samples into the HUD's live visualisers.
        audioCapture.levelMonitor = hudController.audioLevel
        audioCapture.waveformBuffer = hudController.waveform

        // Ask for on-device speech-recognition auth up front so the first ⌥Q
        // isn't interrupted by a permission prompt.
        Task { await hudController.speechService.requestAuthorization() }

        // v1.4 Fase 2c: always ask for location on startup so Cockpit's
        // weather / commute / sun tiles have fresh GPS-driven data without
        // waiting for the user to open Info mode. No-op after the first
        // grant (macOS dedupes repeat authorization requests).
        locationService.requestAuthorization()
        Task { _ = await locationService.refresh() }

        // Wire the Uptodate + Info panel data sources.
        hudController.updatesService = updatesService
        hudController.infoModeService = infoModeService

        pipeline = RecordingPipeline(
            audioCapture: audioCapture,
            geminiClient: geminiClient,
            textInsertion: textInsertion,
            screenCapture: screenCapture,
            permissions: permissions,
            hudController: hudController,
            ttsService: ttsService,
            modeManager: modeManager
        )

        pipeline.onStateChanged = { [weak self] state in
            self?.updateMenuBarIcon(state: state)
            self?.updateUsageLabel()
        }
    }

    // MARK: - Chat Pipeline Setup

    private func setupChatPipeline() {
        hudController.chatSession = chatSession

        chatPipeline = ChatPipeline(
            geminiClient: geminiClient,
            chatSession: chatSession,
            hudController: hudController
        )

        hudController.onChatSend = { [weak self] text in
            self?.chatPipeline.sendTextMessage(text)
        }

        hudController.onPinToggle = { [weak self] in
            guard let self else { return }
            self.hudController.hudState.isPinned.toggle()
        }

        // Agent chat — lazily instantiated on first ⌥⇧A press so users who
        // never use it don't pay the Anthropic provider init cost.
        hudController.onAgentChatSend = { [weak self] text in
            self?.ensureAgentChatPipeline().sendTextMessage(text)
        }
        hudController.onAgentApprove = { [weak self] in
            self?.ensureAgentChatPipeline().approvePendingConfirmation()
        }
        hudController.onAgentReject = { [weak self] in
            self?.ensureAgentChatPipeline().rejectPendingConfirmation()
        }

        // β.11: unified command router — chat window uses this to dispatch
        // all modes (text/voice/screenshot/document) into a single message
        // thread, keeping direct hotkey invocations unchanged.
        let router = ChatCommandRouter(
            chatPipeline: chatPipeline,
            agentChatPipeline: { [weak self] in self?.ensureAgentChatPipeline() },
            geminiClient: geminiClient,
            screenCapture: screenCapture,
            summaryService: summaryService,
            chatSession: chatSession,
            instantAnswers: InstantAnswerProvider(infoModeService: infoModeService)
        )
        commandRouter = router
        hudController.commandRouter = router
        hudController.availableModes = modeManager.allModes
        hudController.shortcutLookup = { [weak self] mode in
            guard let self else { return nil }
            return self.shortcutStringFor(mode: mode)
        }
        hudController.onToggleVoiceRecord = { [weak self] in
            self?.handleChatVoiceToggle()
        }
        hudController.inputBuffer = chatInputBuffer
        hudController.permissionsManager = permissions
        hudController.hasGeminiKey = keychainService.hasAPIKey
        hudController.hasAnthropicKey = keychainService.getAnthropicKey() != nil
        hudController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }

        // v1.1.5: history sidebar wiring. Metadata is re-read every time the
        // chat panel opens so newly-saved conversations show up without a
        // restart. Load/delete pipe through to the on-disk store.
        hudController.onLoadConversation = { [weak self] id in
            self?.loadConversationIntoChat(id: id)
        }
        hudController.onDeleteConversation = { [weak self] id in
            self?.deleteConversation(id: id)
        }
        refreshConversationHistory()
    }

    private let conversationStore = ConversationStore()
    private let updateChecker = UpdateChecker()

    private func refreshConversationHistory() {
        hudController.conversationHistory = conversationStore.loadAllMetadata()
    }

    private func loadConversationIntoChat(id: UUID) {
        guard let conversation = conversationStore.load(id: id) else { return }
        chatSession.replaceMessages(conversation.messages)
        hudController.currentConversationID = id
    }

    private func deleteConversation(id: UUID) {
        conversationStore.delete(id: id)
        if hudController.currentConversationID == id {
            chatSession.clear()
            hudController.currentConversationID = nil
        }
        refreshConversationHistory()
    }

    /// Map a mode to the hotkey that invokes its equivalent direct action,
    /// so the mode picker can show keyboard shortcuts. Only built-ins with a
    /// matching `HotkeyAction` return a value — custom user modes just show
    /// no shortcut.
    private func shortcutStringFor(mode: Mode) -> String? {
        let action: HotkeyAction?
        switch mode.id {
        case BuiltInModes.dictation.id: action = .dictation
        case BuiltInModes.qna.id:       action = .qna
        case BuiltInModes.vision.id:    action = .vision
        case BuiltInModes.translate.id: action = .translate
        case BuiltInModes.summarize.id: action = .summarize
        case BuiltInModes.agent.id:     action = .agent
        case BuiltInModes.chat.id:      action = .toggleChat
        default:                        action = nil
        }
        guard let action else { return nil }
        return hotkeyBindings.binding(for: action).displayString
    }

    /// Chat-dictation: record mic directly (not via RecordingPipeline, which
    /// would paste/HUD), transcribe, drop the result into the chat's command
    /// text so the user can review + edit before sending. Written as a single
    /// method so there's only one state machine to reason about.
    private func handleChatVoiceToggle() {
        let buffer = chatInputBuffer
        if buffer.isRecording {
            // Stop + transcribe
            let audioData = audioCapture.stopRecording()
            buffer.isRecording = false
            guard !audioData.isEmpty else { return }
            buffer.isTranscribing = true

            Task { [weak self] in
                guard let self else { return }
                let result = await self.geminiClient.sendAudio(audioData, mode: BuiltInModes.dictation)
                await MainActor.run {
                    buffer.isTranscribing = false
                    switch result {
                    case .success(let transcript):
                        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            // Append to whatever the user had already typed —
                            // lets them combine typed context with spoken content.
                            if buffer.text.isEmpty {
                                buffer.text = trimmed
                            } else {
                                buffer.text += " " + trimmed
                            }
                        }
                    case .failure(let error):
                        LoggingService.shared.log("Chat dictation transcription failed: \(error)", level: .warning)
                    }
                }
            }
        } else {
            // Only start if RecordingPipeline isn't already using the mic
            // via a hotkey — sharing AudioCaptureManager with two concurrent
            // sessions would step on the WAV header.
            if case .recording = hudController.hudState.currentPhase { return }
            do {
                try audioCapture.startRecording()
                buffer.isRecording = true
            } catch {
                LoggingService.shared.log("Chat dictation start failed: \(error)", level: .warning)
            }
        }
    }

    /// Returns the agent pipeline, instantiating it on first use. Reads the
    /// user's preferred Claude model from UserDefaults so Settings updates
    /// can take effect on the next run.
    private func ensureAgentChatPipeline() -> AgentChatPipeline {
        if let pipeline = agentChatPipeline { return pipeline }
        let provider = AnthropicProvider(keychain: keychainService)
        let modelID = UserDefaults.standard.string(forKey: Constants.Defaults.agentClaudeModel)
            ?? "claude-sonnet-4-6"
        let pipeline = AgentChatPipeline(
            provider: provider,
            chatSession: chatSession,
            modelID: modelID
        )
        agentChatPipeline = pipeline
        return pipeline
    }

    /// Called by `SettingsView` after the user saves a new API key so the chat pipeline
    /// drops its cached SDK Chat (which was constructed with the old key).
    func resetChatPipelineForKeyRotation() {
        chatPipeline?.reset()
        LoggingService.shared.log("Chat pipeline reset after API key rotation")
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis")
            button.image?.isTemplate = true
        }

        buildMenu()
    }

    private func buildMenu() {
        statusMenu = NSMenu()

        let headerItem = NSMenuItem(title: "Jarvis v\(Constants.appVersion)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        statusMenu.addItem(headerItem)
        statusMenu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Mode: \(modeManager.activeMode.name)", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        self.modeMenuItem = modeItem
        statusMenu.addItem(modeItem)

        let modesItem = NSMenuItem(title: "Switch Mode", action: nil, keyEquivalent: "")
        modesItem.submenu = buildModesSubmenu()
        self.modesSubmenuItem = modesItem
        statusMenu.addItem(modesItem)

        statusMenu.addItem(NSMenuItem.separator())

        let usageItem = NSMenuItem(title: usageTracker.formattedUsage, action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        self.usageMenuItem = usageItem
        statusMenu.addItem(usageItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Quick-launch panels
        let infoItem = NSMenuItem(title: "Info mode", action: #selector(openInfoModeFromMenu), keyEquivalent: "i")
        infoItem.target = self
        infoItem.keyEquivalentModifierMask = [.option]
        statusMenu.addItem(infoItem)

        let uptodateItem = NSMenuItem(title: "Briefing", action: #selector(openUptodateFromMenu), keyEquivalent: "u")
        uptodateItem.target = self
        uptodateItem.keyEquivalentModifierMask = [.option]
        statusMenu.addItem(uptodateItem)

        // Hotkey cheat sheet submenu
        let shortcutsItem = NSMenuItem(title: "Hurtig-genveje", action: nil, keyEquivalent: "")
        shortcutsItem.submenu = buildShortcutsSubmenu()
        statusMenu.addItem(shortcutsItem)

        statusMenu.addItem(NSMenuItem.separator())

        let hotkeysItem = NSMenuItem(title: "Tilpas hotkeys…", action: #selector(openHotkeysSettings), keyEquivalent: "")
        hotkeysItem.target = self
        statusMenu.addItem(hotkeysItem)

        let cheatSheetItem = NSMenuItem(title: "Hotkeys & kommandoer…", action: #selector(openCheatSheet), keyEquivalent: "?")
        cheatSheetItem.target = self
        cheatSheetItem.keyEquivalentModifierMask = [.command]
        statusMenu.addItem(cheatSheetItem)

        let updatesItem = NSMenuItem(title: "Søg efter opdateringer…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        statusMenu.addItem(updatesItem)

        let settingsItem = NSMenuItem(title: "Indstillinger…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Afslut Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = statusMenu
    }

    /// Read-only "cheat sheet" of active hotkeys so the user can see them at a
    /// glance without opening Settings.
    private func buildShortcutsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for action in HotkeyAction.allCases {
            let binding = hotkeyBindings.binding(for: action)
            let item = NSMenuItem(
                title: "\(action.displayName)   \(binding.displayString)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildModesSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for mode in modeManager.allModes {
            let item = NSMenuItem(title: mode.name, action: #selector(switchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id.uuidString
            if mode.id == modeManager.activeMode.id {
                item.state = .on
            }
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Targeted Menu Updates

    private func updateModeCheckmark() {
        modeMenuItem?.title = "Mode: \(modeManager.activeMode.name)"
        modesSubmenuItem?.submenu = buildModesSubmenu()
    }

    private func updateUsageLabel() {
        usageMenuItem?.title = usageTracker.formattedUsage
    }

    // MARK: - Menu Actions

    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let uuid = UUID(uuidString: idString) else { return }
        modeManager.setActiveMode(byId: uuid)
        updateModeCheckmark()
    }

    @objc private func openSettings() {
        presentSettings(tab: nil)
    }

    @objc private func openHotkeysSettings() {
        presentSettings(tab: .hotkeys)
    }

    private var cheatSheetWindow: NSWindow?

    @objc private func checkForUpdates() {
        Task { await updateChecker.checkNow(userInitiated: true) }
    }

    @objc private func openCheatSheet() {
        if let window = cheatSheetWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HotkeyCheatSheet(bindings: hotkeyBindings) { [weak self] in
            self?.cheatSheetWindow?.close()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "Hotkeys & kommandoer"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        cheatSheetWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openInfoModeFromMenu() {
        if hudController.isInfoModeVisible {
            hudController.close()
        } else {
            hudController.showInfoMode()
        }
    }

    @objc private func openUptodateFromMenu() {
        if hudController.isUptodateVisible {
            hudController.close()
        } else {
            hudController.showUptodate()
        }
    }

    private func presentSettings(tab: SettingsTab?) {
        if let tab { settingsHostState.selectedTab = tab }
        if settingsWindow == nil {
            let settingsView = SettingsHost(state: settingsHostState)
                .environment(modeManager)
                .environment(usageTracker)
                .environment(hotkeyBindings)
            let hostingController = NSHostingController(rootView: settingsView)
            // Use the view's own sizing hints — SwiftUI populates the hosting
            // controller's preferredContentSize from the .frame(ideal:) modifiers.
            hostingController.sizingOptions = [.preferredContentSize]

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Jarvis Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.setContentSize(NSSize(
                width: Constants.SettingsWindow.defaultWidth,
                height: Constants.SettingsWindow.defaultHeight
            ))
            window.minSize = NSSize(
                width: Constants.SettingsWindow.minWidth,
                height: Constants.SettingsWindow.minHeight
            )
            // Persist size across launches — AppKit takes care of this automatically
            // when we give the window a frame autosave name.
            window.setFrameAutosaveName("JarvisSettingsWindow")
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Bar Icon

    private func updateMenuBarIcon(state: RecordingState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis")
            button.contentTintColor = nil
            button.title = ""
        case .recording:
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
            button.title = " Optager"
        case .processing:
            button.image = NSImage(systemSymbolName: "gear.circle", accessibilityDescription: "Processing")
            button.contentTintColor = .systemOrange
            button.title = " Arbejder"
        }
        button.image?.isTemplate = (state == .idle)
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeyManager.onDictationKeyDown = { [weak self] in
            self?.pipeline.handleRecordStart(mode: nil, captureScreen: false)
        }
        hotkeyManager.onDictationKeyUp = { [weak self] in
            self?.pipeline.handleRecordStop()
        }

        hotkeyManager.onQnAKeyDown = { [weak self] in
            self?.pipeline.handleRecordStart(mode: BuiltInModes.qna, captureScreen: false)
        }
        hotkeyManager.onQnAKeyUp = { [weak self] in
            self?.pipeline.handleRecordStop()
        }

        hotkeyManager.onVisionKeyDown = { [weak self] in
            self?.pipeline.handleRecordStart(mode: BuiltInModes.vision, captureScreen: true)
        }
        hotkeyManager.onVisionKeyUp = { [weak self] in
            self?.pipeline.handleRecordStop()
        }

        hotkeyManager.onModeCycle = { [weak self] in
            guard let self else { return }
            self.modeManager.cycleMode()
            self.updateModeCheckmark()
            LoggingService.shared.log("Mode cycled to: \(self.modeManager.activeMode.name)")
        }

        hotkeyManager.onChatToggle = { [weak self] in
            guard let self else { return }
            if self.hudController.isChatVisible {
                self.hudController.saveChatFrame()
                self.hudController.close()
            } else {
                self.refreshConversationHistory()
                self.hudController.showChat()
            }
        }

        hotkeyManager.onTranslateKeyDown = { [weak self] in
            self?.pipeline.handleRecordStart(mode: BuiltInModes.translate, captureScreen: false)
        }
        hotkeyManager.onTranslateKeyUp = { [weak self] in
            self?.pipeline.handleRecordStop()
        }

        hotkeyManager.onUptodate = { [weak self] in
            guard let self else { return }
            if self.hudController.isUptodateVisible {
                self.hudController.close()
            } else {
                self.hudController.showUptodate()
            }
        }

        hotkeyManager.onSummarize = { [weak self] in
            self?.summaryService.summarizeInteractively()
        }

        hotkeyManager.onAgent = { [weak self] in
            guard let self else { return }
            if self.hudController.isAgentChatVisible {
                self.hudController.saveChatFrame()
                self.hudController.close()
            } else {
                self.hudController.showAgentChat()
            }
        }

        hotkeyManager.onInfoMode = { [weak self] in
            guard let self else { return }
            if self.hudController.isInfoModeVisible {
                self.hudController.close()
            } else {
                self.hudController.showInfoMode()
            }
        }

        // Registration happens after this, via `hotkeyBindings.applyAll()` in applicationDidFinishLaunching.
    }

    // MARK: - Cost Warning

    private func setupCostWarning() {
        usageTracker.onCostWarning = { [weak self] cost in
            self?.hudController.showError(
                "Omkostningsadvarsel: Dit månedlige forbrug har nået $\(String(format: "%.2f", cost))"
            )
        }
    }

    // MARK: - Wake Word

    private func setupWakeWord() {
        NotificationCenter.default.addObserver(
            forName: .jarvisWakeWordSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshWakeWord()
        }
        refreshWakeWord()
    }

    private func refreshWakeWord() {
        let enabled = UserDefaults.standard.bool(forKey: Constants.Defaults.wakeWordEnabled)
        if enabled {
            startWakeWord()
        } else {
            wakeWordDetector.stop()
        }
    }

    // MARK: - Voice commands (continuous on-device "Jarvis ..." listener)

    private func setupVoiceCommands() {
        voiceCommandService.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .info:
                if !self.hudController.isInfoModeVisible { self.hudController.showInfoMode() }
            case .uptodate:
                if !self.hudController.isUptodateVisible { self.hudController.showUptodate() }
            case .chat:
                if !self.hudController.isChatVisible { self.hudController.showChat() }
            case .qna:
                self.runVoiceRecording(mode: BuiltInModes.qna)
            case .translate:
                self.runVoiceRecording(mode: BuiltInModes.translate)
            case .summarize:
                self.summaryService.summarizeInteractively()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .jarvisVoiceCommandSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshVoiceCommands()
        }

        Task { [weak self] in
            guard let self else { return }
            await self.voiceCommandService.prepare()
            self.refreshVoiceCommands()
        }
    }

    /// Run a 4-second recording window triggered by a voice command. Mutes the
    /// voice-command recogniser for the duration so the tail of the same
    /// utterance doesn't re-trigger a second command.
    private func runVoiceRecording(mode: Mode) {
        voiceCommandService.suspend()
        pipeline.handleRecordStart(mode: mode, captureScreen: false)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.pipeline.handleRecordStop()
            // Give the recogniser a moment to drain its buffer before we
            // re-enable matching — another ~500ms of silence.
            try? await Task.sleep(for: .milliseconds(500))
            self?.voiceCommandService.resume()
        }
    }

    private func refreshVoiceCommands() {
        let enabled = UserDefaults.standard.bool(forKey: Constants.Defaults.voiceCommandsEnabled)
        if enabled {
            voiceCommandService.start()
        } else {
            voiceCommandService.stop()
        }
    }

    private func startWakeWord() {
        // Stop before restart so a key change doesn't leave a dangling mic tap.
        wakeWordDetector.stop()
        do {
            try wakeWordDetector.start { [weak self] in
                guard let self else { return }
                // Treat a wake event the same as pressing the Q&A hotkey.
                self.pipeline.handleRecordStart(mode: BuiltInModes.qna, captureScreen: false)
                // Auto-stop 4 s later — no release key to trigger stop in wake-word mode.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.pipeline.handleRecordStop()
                }
            }
        } catch {
            LoggingService.shared.log("Wake word start failed: \(error.localizedDescription)", level: .warning)
            hudController.showError(error.localizedDescription)
        }
    }

    // MARK: - First Launch

    private func checkFirstLaunch() {
        let hasLaunched = UserDefaults.standard.bool(forKey: Constants.Defaults.hasLaunchedBefore)
        if !hasLaunched {
            UserDefaults.standard.set(true, forKey: Constants.Defaults.hasLaunchedBefore)
            showOnboarding()
        }
    }

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
}

enum RecordingState {
    case idle, recording, processing
}
