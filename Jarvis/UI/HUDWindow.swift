import AppKit
import SwiftUI

@MainActor
class HUDWindowController {
    private var panel: NSPanel?
    private var autoCloseTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    let hudState = HUDState()
    let audioLevel = AudioLevelMonitor()
    let waveform = WaveformBuffer()
    let speechService = SpeechRecognitionService()
    /// Current mode name shown in the HUD badge. AppDelegate keeps this in sync.
    var activeModeName: String = ""
    /// Set by AppDelegate once services exist, then passed into UptodateView.
    var updatesService: UpdatesService?
    /// Set by AppDelegate once services exist, then passed into InfoModeView.
    var infoModeService: InfoModeService?
    var onAgentChatSend: ((String) -> Void)?
    var onAgentApprove: (() -> Void)?
    var onAgentReject: (() -> Void)?

    var onSpeakRequested: ((String) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onMaxRecordingReached: (() -> Void)?
    var onPermissionAction: (() -> Void)?
    var onChatSend: ((String) -> Void)?
    var onPinToggle: (() -> Void)?
    var chatSession: ChatSession?
    // β.11: unified chat command-bar wiring.
    var commandRouter: ChatCommandRouter?
    var availableModes: [Mode] = []
    var shortcutLookup: (Mode) -> String? = { _ in nil }
    var onToggleVoiceRecord: (() -> Void)?
    var inputBuffer: ChatInputBuffer?
    var permissionsManager: PermissionsManager?
    var hasGeminiKey: Bool = false
    var hasAnthropicKey: Bool = false
    var onOpenSettings: (() -> Void)?
    // v1.1.5 history sidebar
    var conversationHistory: [ConversationStore.Metadata] = []
    var currentConversationID: UUID?
    var onLoadConversation: ((UUID) -> Void)?
    var onDeleteConversation: ((UUID) -> Void)?

    private var recordingStartTime: Date?

    // MARK: - Public API

    func showRecording() {
        hudState.currentPhase = .recording(elapsed: 0)
        recordingStartTime = Date()
        presentPanel()
        startRecordingTimer()
    }

    func showProcessing() {
        cancelRecordingTimer()
        hudState.currentPhase = .processing
        if panel == nil { presentPanel() }
    }

    func showResult(_ text: String) {
        cancelRecordingTimer()
        hudState.currentPhase = .result(text: text)
        if panel == nil { presentPanel() }
        scheduleAutoClose(after: Constants.Timers.resultAutoClose)
    }

    func showConfirmation(_ message: String) {
        cancelRecordingTimer()
        hudState.currentPhase = .confirmation(message: message)
        if panel == nil { presentPanel() }
        scheduleAutoClose(after: Constants.Timers.confirmationAutoClose)
    }

    func showError(_ message: String) {
        cancelRecordingTimer()
        hudState.currentPhase = .error(message: message)
        if panel == nil { presentPanel() }
        scheduleAutoClose(after: Constants.Timers.errorAutoClose)
    }

    func showPermissionError(permission: String, instructions: String) {
        cancelRecordingTimer()
        hudState.currentPhase = .permissionError(permission: permission, instructions: instructions)
        if panel == nil { presentPanel() }
        scheduleAutoClose(after: Constants.Timers.errorAutoClose)
    }

    func showChat() {
        cancelRecordingTimer()
        hudState.currentPhase = .chat
        if panel == nil {
            presentChatPanel()
        } else {
            // Resize existing panel to chat size
            resizePanelForChat()
        }
    }

    var isChatVisible: Bool {
        hudState.isVisible && hudState.currentPhase == .chat
    }

    /// Opens the chat panel — agent tooling is activated by picking the
    /// Agent mode from the command-bar dropdown. Kept as a named function so
    /// the ⌥⇧A hotkey has a stable entry point.
    func showAgentChat() {
        showChat()
    }

    var isAgentChatVisible: Bool {
        isChatVisible
    }

    func showUptodate() {
        cancelRecordingTimer()
        cancelAutoClose()
        hudState.currentPhase = .uptodate
        if panel == nil {
            presentUptodatePanel()
        } else {
            resizePanelForUptodate()
        }
    }

    var isUptodateVisible: Bool {
        hudState.isVisible && hudState.currentPhase == .uptodate
    }

    func showInfoMode() {
        cancelRecordingTimer()
        cancelAutoClose()
        hudState.currentPhase = .infoMode
        if panel == nil {
            presentInfoPanel()
        }
    }

    var isInfoModeVisible: Bool {
        hudState.isVisible && hudState.currentPhase == .infoMode
    }

    func close() {
        cancelAutoClose()
        cancelRecordingTimer()
        panel?.close()
        panel = nil
        hudState.isVisible = false
    }

    // MARK: - Panel Management

    private func presentPanel() {
        cancelAutoClose()
        if panel != nil { return }   // already visible — @Observable state updates in place
        presentCornerPanel()
    }

    /// Builds the single HUDContentView used by both the corner HUD panel
    /// (recording / result / error) and the Spotlight-style chat panel.
    /// Centralised so β.11's new command-bar plumbing only needs one wiring site.
    private func makeHUDContentView() -> HUDContentView {
        HUDContentView(
            state: hudState,
            audioLevel: audioLevel,
            waveform: waveform,
            speechService: speechService,
            activeModeName: activeModeName,
            onClose: { [weak self] in self?.close() },
            onSpeak: { [weak self] text in self?.onSpeakRequested?(text) },
            onPermissionAction: { [weak self] in self?.onPermissionAction?() },
            chatSession: chatSession,
            onChatSend: { [weak self] text in self?.onChatSend?(text) },
            onPin: { [weak self] in self?.onPinToggle?() },
            onAgentChatSend: onAgentChatSend != nil ? { [weak self] text in self?.onAgentChatSend?(text) } : nil,
            onAgentApprove: onAgentApprove != nil ? { [weak self] in self?.onAgentApprove?() } : nil,
            onAgentReject: onAgentReject != nil ? { [weak self] in self?.onAgentReject?() } : nil,
            commandRouter: commandRouter,
            availableModes: availableModes,
            shortcutLookup: shortcutLookup,
            onToggleVoiceRecord: onToggleVoiceRecord != nil ? { [weak self] in self?.onToggleVoiceRecord?() } : nil,
            inputBuffer: inputBuffer,
            permissionsManager: permissionsManager,
            hasGeminiKey: hasGeminiKey,
            hasAnthropicKey: hasAnthropicKey,
            onOpenSettings: onOpenSettings != nil ? { [weak self] in self?.onOpenSettings?() } : nil,
            conversationHistory: conversationHistory,
            currentConversationID: currentConversationID,
            onLoadConversation: onLoadConversation != nil ? { [weak self] id in self?.onLoadConversation?(id) } : nil,
            onDeleteConversation: onDeleteConversation != nil ? { [weak self] id in self?.onDeleteConversation?(id) } : nil
        )
    }

    private func presentCornerPanel() {
        let contentView = makeHUDContentView()

        let hostingController = NSHostingController(rootView: contentView)

        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - Constants.HUD.width - Constants.HUD.padding
            let y = screenFrame.maxY - Constants.HUD.maxHeight - Constants.HUD.padding
            panel.setFrame(
                NSRect(x: x, y: y, width: Constants.HUD.width, height: Constants.HUD.maxHeight),
                display: true
            )
        }

        panel.orderFrontRegardless()
        self.panel = panel
        hudState.isVisible = true
    }

    // MARK: - Chat Panel

    private func presentChatPanel() {
        cancelAutoClose()

        if panel != nil {
            resizePanelForChat()
            return
        }

        let contentView = makeHUDContentView()

        let hostingController = NSHostingController(rootView: contentView)

        // Custom subclass: canBecomeKey=true so the TextField can actually receive
        // keystrokes (fixes the v4.x "can't type in chat" bug).
        let panel = JarvisChatPanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI handles the cyan glow shadow
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: Constants.ChatHUD.minWidth, height: Constants.ChatHUD.minHeight)

        // β.11: always open centered, Spotlight-style. Frame persistence
        // dropped — the user can still drag within a session, but re-opening
        // snaps back to centre for predictable behaviour.
        let w = Constants.ChatHUD.width
        let h = Constants.ChatHUD.height
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - w / 2
            let y = screenFrame.midY - h / 2
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }

        panel.orderFrontRegardless()
        // Make the panel key so the text field can receive keyboard input
        panel.makeKey()
        self.panel = panel
        hudState.isVisible = true
    }

    // MARK: - Uptodate Panel

    private func presentUptodatePanel() {
        guard let updatesService else {
            LoggingService.shared.log("Uptodate panel requested but service not wired", level: .warning)
            return
        }
        cancelAutoClose()

        let view = UptodateView(service: updatesService) { [weak self] in self?.close() }
            .jarvisHUDBackground(showReticle: false)

        let hostingController = NSHostingController(rootView: view)
        hostingController.sizingOptions = .preferredContentSize

        let panel = JarvisKeyablePanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 600, height: 200)

        // Intrinsic-size-driven: let the hosting controller pick the height,
        // then pin the panel to the top-right of the visible screen.
        anchorPanelTopRight(panel)

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        hudState.isVisible = true
    }

    // MARK: - Info Panel

    private func presentInfoPanel() {
        guard let infoModeService else {
            LoggingService.shared.log("Info panel requested but service not wired", level: .warning)
            return
        }
        cancelAutoClose()

        let view = InfoModeView(service: infoModeService) { [weak self] in self?.close() }
            .jarvisHUDBackground(showReticle: false)

        let hostingController = NSHostingController(rootView: view)
        // DO NOT set sizingOptions = .preferredContentSize. That option tells
        // NSHostingView to continuously observe SwiftUI's preferred size and
        // resize the window in response. Combined with MKMapView (autoresizing
        // mask) + any dynamic content, it spins into a setFrame → layout →
        // setFrame loop and overflows the main-thread stack at ~6900 frames.
        // Instead we measure the SwiftUI content's fittingSize ONCE below and
        // pin the panel to that size.

        let panel = JarvisKeyablePanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 520, height: 200)

        // One-shot measurement: force the hosting view to layout once so we
        // can read its fittingSize. Because no window is observing it yet,
        // there's no feedback loop.
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        let screenVisible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let targetWidth = max(fitting.width, 680)
        let targetHeight = min(fitting.height, screenVisible.height - 40)
        let origin = NSPoint(
            x: screenVisible.maxX - targetWidth - Constants.HUD.padding,
            y: screenVisible.maxY - targetHeight - Constants.HUD.padding
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: targetWidth, height: targetHeight)), display: true)

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        hudState.isVisible = true
    }

    /// After the hosting controller has sized the panel to its SwiftUI content,
    /// move it to the top-right of the visible screen. Clamps to screen height
    /// if the content is pathologically tall.
    private func anchorPanelTopRight(_ panel: NSPanel) {
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let panel, let screen = NSScreen.main else { return }
            let screenFrame = screen.visibleFrame
            var frame = panel.frame
            let maxHeight = screenFrame.height - 40
            if frame.height > maxHeight { frame.size.height = maxHeight }
            frame.origin.x = screenFrame.maxX - frame.width - Constants.HUD.padding
            frame.origin.y = screenFrame.maxY - frame.height - Constants.HUD.padding
            panel.setFrame(frame, display: true)
            _ = self  // silence unused warning
        }
    }

    private func resizePanelForUptodate() {
        guard let panel, let updatesService else { return }
        let view = UptodateView(service: updatesService) { [weak self] in self?.close() }
            .jarvisHUDBackground(showReticle: false)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        anchorPanelTopRight(panel)
    }

    private func resizePanelForChat() {
        guard let panel else { return }
        let w = Constants.ChatHUD.width
        let h = Constants.ChatHUD.height
        // Stay borderless — ChatView's own header owns close/pin, so we don't want
        // a ghost system titlebar reserving space above our cyan background.
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.minSize = NSSize(width: Constants.ChatHUD.minWidth, height: Constants.ChatHUD.minHeight)
        // β.11: always recenter on chat-mode transition too.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - w / 2
            let y = screenFrame.midY - h / 2
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: true)
        }
        panel.makeKey()
    }

    /// No-op retained for call-site compatibility — chat panel no longer
    /// persists its frame. Safe to delete once all callers are updated.
    func saveChatFrame() {}

    // MARK: - Timers

    private func scheduleAutoClose(after seconds: TimeInterval) {
        guard !hudState.isPinned else { return }
        cancelAutoClose()
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard self?.hudState.isPinned != true else { return }
            self?.close()
        }
    }

    private func cancelAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
    }

    private func startRecordingTimer() {
        cancelRecordingTimer()
        recordingTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled, let start = self.recordingStartTime else { break }
                let elapsed = Date().timeIntervalSince(start)

                if elapsed >= Constants.maxRecordingDuration {
                    self.onMaxRecordingReached?()
                    break
                }

                self.hudState.currentPhase = .recording(elapsed: elapsed)
            }
        }
    }

    private func cancelRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingStartTime = nil
    }
}
