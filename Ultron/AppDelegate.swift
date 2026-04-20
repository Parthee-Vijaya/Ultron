import AppKit
import CoreSpotlight
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

    // MARK: - Public (accessed by UltronApp)
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
    /// One pipeline per AI provider type so switching a mode between Claude
    /// and Ollama doesn't destroy the other's conversation buffer. Lazy —
    /// pipelines are built on first use.
    private var agentChatPipelines: [AIProviderType: AgentChatPipeline] = [:]
    private var commandRouter: ChatCommandRouter?
    /// Shared buffer for the chat command-bar text field. Lets
    /// `handleChatVoiceToggle` push dictation transcripts back into the UI.
    private let chatInputBuffer = ChatInputBuffer()
    let locationService = LocationService()
    /// v1.4: observes screen-lock / display-sleep so the HUD can suppress
    /// auto-pop surfaces while the user is away. Instantiated once and kept
    /// for the app's lifetime.
    private let focusObserver = FocusModeObserver()
    lazy var updatesService = UpdatesService(locationService: locationService)
    lazy var infoModeService = InfoModeService(locationService: locationService)
    let briefingScheduler = BriefingScheduler()
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
    /// Exposed (not private) so UI views like the Cockpit briefing tile can
    /// call `speakAlways(...)` for "Læs op"-style playback. Recording pipeline
    /// is still the main consumer.
    let ttsService = TTSService()
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
            migrateClaudeBudgetLimits()
            // v1.1.7: spawn any MCP servers the user declared in ~/.ultron/mcp.json
            // and register their tools with the shared agent registry. Runs in
            // the background — we don't block app launch if a server is slow.
            // Phase 4c: after the sidecar registers, hydrate the briefing tile
            // from the persisted `digest.latest` result so the Cockpit shows
            // something meaningful before the user hits Regenerate.
            Task {
                await MCPRegistry.shared.bootstrap()
                await infoModeService.loadCachedDigest()
            }
            // Phase 4c wiring: briefing uses a ProviderRouter so Regenerate
            // respects local-first routing + trace logging.
            do {
                let keychain = keychainService
                let usage = usageTracker
                infoModeService.briefingProviderFactory = {
                    ProviderRouter(factories: .init(
                        ollama:    { OllamaProvider() },
                        anthropic: { AnthropicProvider(keychain: keychain) },
                        gemini:    { GeminiAIProvider(keychain: keychain, usage: usage) }
                    ))
                }
                infoModeService.briefingModelProvider = {
                    UserDefaults.standard.string(forKey: Constants.Defaults.agentOllamaModel)
                        ?? "gemma3:4b"
                }
            }
            // Phase 4c — automatic morning briefing. Scheduler fires at the
            // configured time; closure returns a short summary for the
            // notification body.
            briefingScheduler.onFire = { [weak self] in
                guard let self else { return nil }
                await self.infoModeService.regenerateDigest()
                return self.infoModeService.cachedDigest?.text
            }
            briefingScheduler.start()
            // v1.4 Fase 4 slice: register ourselves as a services-menu
            // provider so "Ask Ultron about this" appears in every app's
            // Services submenu for selected text. The Info.plist NSServices
            // array advertises the action; this call tells AppKit we're
            // ready to handle it.
            NSApplication.shared.servicesProvider = self
            NSUpdateDynamicServices()
            // v1.2.0: ping GitHub Releases once a day to see if a newer
            // Ultron DMG is published. Non-blocking; prompts only when a
            // higher semver is found.
            updateChecker.checkIfDue()
            LoggingService.shared.log("Ultron v\(Constants.appVersion) started")
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MCPRegistry.shared.shutdown()
        }
    }

    // MARK: - Services menu (v1.4 Fase 4 slice)

    /// Called by AppKit when the user picks "Ask Ultron about this" from any
    /// app's Services submenu. The `NSMessage` key in Info.plist maps this
    /// selector; pasteboard contains the selected plain text.
    ///
    /// Behaviour: pull the text, route it through the chat as a Q&A-mode
    /// prompt, and show the HUD. Matches the `open ultron://qna?prompt=…`
    /// URL scheme flow so the handling is unified.
    @objc func askUltronAboutSelection(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            LoggingService.shared.log("Services: empty pasteboard — nothing to ask", level: .warning)
            return
        }
        LoggingService.shared.log("Services: ask Ultron about \(text.count)-char selection")
        // Reuse the same chat-opening path the ⌥C hotkey uses. Route through
        // the chat command router in Q&A mode so web-search grounds the reply.
        Task { @MainActor in
            hudController.showChat()
            await commandRouter?.run(mode: BuiltInModes.qna, input: text)
        }
    }

    /// v1.1.8: handle incoming `ultron://…` URLs from the OS / Shortcuts /
    /// automation tools. Supported:
    ///   - ultron://chat?prompt=TEXT      — open chat, pre-fill the bar
    ///   - ultron://qna?prompt=TEXT       — run Q&A with the given prompt
    ///   - ultron://summarize             — open picker + summarize
    ///   - ultron://vision?prompt=TEXT    — capture screen + ask
    ///   - ultron://info / ://briefing    — open the respective panel
    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { handleUltronURL(url) }
        }
    }

    private func handleUltronURL(_ url: URL) {
        guard url.scheme?.lowercased() == "ultron" else { return }
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
        case "dictate-clipboard":
            // Fire-and-forget URL entry. AppIntent callers invoke
            // `dictateToClipboard(seconds:)` directly so they can await
            // the transcript; the URL scheme just kicks off the flow
            // with HUD feedback.
            Task { _ = await dictateToClipboard(seconds: 6) }
        case "info", "cockpit":
            hudController.showInfoMode()
        case "briefing", "uptodate":
            hudController.showUptodate()
        case "conversation":
            // Spotlight hit or explicit ultron://conversation?id=UUID —
            // open the chat window and load the requested transcript.
            guard let idString = components?.queryItems?.first(where: { $0.name == "id" })?.value,
                  let uuid = UUID(uuidString: idString) else {
                LoggingService.shared.log("ultron://conversation missing id", level: .warning)
                return
            }
            refreshConversationHistory()
            hudController.showChat()
            loadConversationIntoChat(id: uuid)
        default:
            LoggingService.shared.log("Unknown ultron:// action: \(action)", level: .warning)
        }
    }

    /// Spotlight taps arrive as an `NSUserActivity` of type
    /// `CSSearchableItemActionType`, not as a `ultron://` URL — AppKit
    /// routes them here. Pull the conversation UUID out of the activity
    /// userInfo (`CSSearchableItemActivityIdentifier`) and open the chat.
    nonisolated func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                                 restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let idString = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let uuid = UUID(uuidString: idString) else {
            return false
        }
        MainActor.assumeIsolated {
            refreshConversationHistory()
            hudController.showChat()
            loadConversationIntoChat(id: uuid)
        }
        return true
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
        hudController.focusObserver = focusObserver

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
            self?.ensureAgentChatPipeline(for: .anthropic)?.sendTextMessage(text)
        }
        hudController.onAgentApprove = { [weak self] in
            self?.ensureAgentChatPipeline(for: .anthropic)?.approvePendingConfirmation()
        }
        hudController.onAgentReject = { [weak self] in
            self?.ensureAgentChatPipeline(for: .anthropic)?.rejectPendingConfirmation()
        }

        // β.11: unified command router — chat window uses this to dispatch
        // all modes (text/voice/screenshot/document) into a single message
        // thread, keeping direct hotkey invocations unchanged.
        let router = ChatCommandRouter(
            chatPipeline: chatPipeline,
            agentChatPipeline: { [weak self] providerType in self?.ensureAgentChatPipeline(for: providerType) },
            geminiClient: geminiClient,
            screenCapture: screenCapture,
            summaryService: summaryService,
            chatSession: chatSession,
            instantAnswers: InstantAnswerProvider(infoModeService: infoModeService),
            infoModeService: infoModeService
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

    // MARK: - AppIntents helpers (v1.2.2)
    //
    // The three methods below back the Siri/Shortcuts intents in
    // `UltronAppIntents.swift`. Kept on AppDelegate (rather than free
    // functions) so they share the same `geminiClient`, `audioCapture`,
    // and `hudController` instances as the hotkey-driven paths — no
    // second set of services to keep in sync.

    /// Push-to-talk for a fixed `seconds` window, transcribe via Gemini,
    /// copy the result to the system pasteboard. Returns the trimmed
    /// transcript (empty string on mic denial or Gemini failure).
    @MainActor
    func dictateToClipboard(seconds: TimeInterval = 6) async -> String {
        guard permissions.checkMicrophone() else {
            hudController.showError("Mikrofon-tilladelse mangler")
            return ""
        }
        hudController.activeModeName = "Dictation → Clipboard"
        hudController.showRecording()
        do {
            try audioCapture.startRecording()
        } catch {
            hudController.showError("Mic fejl: \(error.localizedDescription)")
            return ""
        }
        try? await Task.sleep(for: .seconds(seconds))
        let audioData = audioCapture.stopRecording()
        hudController.showProcessing()
        guard !audioData.isEmpty else {
            hudController.close()
            return ""
        }
        let result = await geminiClient.sendAudio(audioData, mode: BuiltInModes.dictation)
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(trimmed, forType: .string)
            hudController.showConfirmation("Kopieret til udklipsholder")
            return trimmed
        case .failure(let error):
            hudController.showError("Transkription fejlede: \(error.localizedDescription)")
            return ""
        }
    }

    /// Fetch a URL, strip tags/scripts/styles, cap at 8 KB of readable text,
    /// then ask Gemini for a 3-bullet summary. Throws on fetch/decode/API
    /// failure so Shortcut error branches can handle it.
    @MainActor
    func summarizeURL(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }
        let stripped = raw
            .replacingOccurrences(
                of: "<script[^>]*>[\\s\\S]*?</script>",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "<style[^>]*>[\\s\\S]*?</style>",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(stripped.prefix(8_000))
        let prompt = """
        Opsummer indholdet nedenfor i præcis 3 korte bullet points \
        (hver under 20 ord). Svar på samme sprog som teksten.

        Indhold:
        \(truncated)
        """
        let result = await geminiClient.sendText(prompt: prompt, mode: BuiltInModes.summarize)
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    /// Combine selected text + a question into a single prompt, send to
    /// Gemini chat mode, return the reply as one string. Bypasses
    /// ChatPipeline because Shortcuts wants a synchronous value — no
    /// streaming surface needed here.
    @MainActor
    func askWithContext(selectedText: String, question: String) async throws -> String {
        let prompt = """
        Context:

        \(selectedText)

        Question: \(question)
        """
        let result = await geminiClient.sendText(prompt: prompt, mode: BuiltInModes.chat)
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    /// Returns the agent pipeline for a given provider type, instantiating it
    /// on first use. Cached in `agentChatPipelines` keyed by type so switching
    /// modes doesn't rebuild the pipeline on every send.
    ///
    /// Reads the user's preferred model from UserDefaults so Settings updates
    /// can take effect on the next run:
    ///   - Anthropic: Constants.Defaults.agentClaudeModel (default claude-sonnet-4-6)
    ///   - Ollama:    Constants.Defaults.agentOllamaModel (default gemma3:4b)
    ///
    /// Returns nil only when the provider type isn't yet supported.
    private func ensureAgentChatPipeline(for providerType: AIProviderType) -> AgentChatPipeline? {
        if let pipeline = agentChatPipelines[providerType] { return pipeline }

        let pipeline: AgentChatPipeline
        let keychain = keychainService
        switch providerType {
        case .anthropic:
            let inner = AnthropicProvider(keychain: keychain)
            let traced = TracedAIProvider(inner: inner, type: .anthropic, taskType: "agent.claude")
            let modelID = UserDefaults.standard.string(forKey: Constants.Defaults.agentClaudeModel)
                ?? "claude-sonnet-4-6"
            pipeline = AgentChatPipeline(provider: traced, chatSession: chatSession, modelID: modelID)
        case .ollama:
            let inner = OllamaProvider()
            let traced = TracedAIProvider(inner: inner, type: .ollama, taskType: "agent.ollama")
            let modelID = UserDefaults.standard.string(forKey: Constants.Defaults.agentOllamaModel)
                ?? "gemma3:4b"
            pipeline = AgentChatPipeline(provider: traced, chatSession: chatSession, modelID: modelID)
        case .auto:
            let usage = usageTracker  // capture for factory closure
            let router = ProviderRouter(factories: .init(
                ollama:    { OllamaProvider() },
                anthropic: { AnthropicProvider(keychain: keychain) },
                gemini:    { GeminiAIProvider(keychain: keychain, usage: usage) }
            ))
            // Prefer the Ollama default model for agent-mode auto; the router
            // swaps to the right one per decision.
            let modelID = UserDefaults.standard.string(forKey: Constants.Defaults.agentOllamaModel)
                ?? "gemma3:4b"
            pipeline = AgentChatPipeline(provider: router, chatSession: chatSession, modelID: modelID)
        case .gemini:
            // Gemini routes through ChatPipeline (non-agent), not this one.
            return nil
        }

        agentChatPipelines[providerType] = pipeline
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
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Ultron")
            button.image?.isTemplate = true
        }

        buildMenu()
    }

    private func buildMenu() {
        statusMenu = NSMenu()

        let headerItem = NSMenuItem(title: "Ultron v\(Constants.appVersion)", action: nil, keyEquivalent: "")
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

        // Phase 4c: AI-briefing regeneration shortcut. Uses ⌥⇧D by default,
        // same binding as the `.generateDigest` hotkey action so the menu
        // item label reflects the user's current shortcut.
        let digestItem = NSMenuItem(title: "Generer AI-briefing", action: #selector(generateDigestFromMenu), keyEquivalent: "d")
        digestItem.target = self
        digestItem.keyEquivalentModifierMask = [.option, .shift]
        statusMenu.addItem(digestItem)

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
        statusMenu.addItem(NSMenuItem(title: "Afslut Ultron", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

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

    @objc private func generateDigestFromMenu() {
        runBriefingGeneration(openCockpit: true)
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
            window.title = "Ultron Settings"
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
            window.setFrameAutosaveName("UltronSettingsWindow")
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
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Ultron")
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

        hotkeyManager.onGenerateDigest = { [weak self] in
            self?.runBriefingGeneration(openCockpit: true)
        }

        // Registration happens after this, via `hotkeyBindings.applyAll()` in applicationDidFinishLaunching.
    }

    /// Phase 4c single-entry-point for triggering an AI-briefing regeneration.
    /// Called from the ⌥⇧D hotkey, the "Ultron digest" voice command, and
    /// the menu bar's "Generer briefing" item. Optionally pops the Cockpit
    /// so the user sees the tile update.
    @MainActor
    private func runBriefingGeneration(openCockpit: Bool) {
        if openCockpit, !hudController.isInfoModeVisible {
            hudController.showInfoMode()
        }
        Task { [weak self] in
            await self?.infoModeService.regenerateDigest()
        }
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
            forName: .ultronWakeWordSettingsChanged,
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

    // MARK: - Voice commands (continuous on-device "Ultron ..." listener)

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
            case .digest:
                self.runBriefingGeneration(openCockpit: true)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .ultronVoiceCommandSettingsChanged,
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

    /// v1.4: Claude Code budget defaults jumped from 1 M / 5 M tokens to
    /// 500 M / 2.5 B because cache-read is the dominant category and the
    /// old numbers put the Cockpit bars at >90000% for a normal week. If
    /// the stored value is still at the pre-bump tier, rewrite it to the
    /// new default. Users who deliberately set a higher number keep theirs.
    private func migrateClaudeBudgetLimits() {
        let d = UserDefaults.standard
        let dailyKey = Constants.Defaults.claudeDailyLimitTokens
        let weeklyKey = Constants.Defaults.claudeWeeklyLimitTokens
        let storedDaily = d.integer(forKey: dailyKey)
        if storedDaily > 0, storedDaily < 10_000_000 {
            d.set(Constants.ClaudeStats.defaultDailyLimit, forKey: dailyKey)
        }
        let storedWeekly = d.integer(forKey: weeklyKey)
        if storedWeekly > 0, storedWeekly < 50_000_000 {
            d.set(Constants.ClaudeStats.defaultWeeklyLimit, forKey: weeklyKey)
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
        window.title = "Welcome to Ultron"
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
