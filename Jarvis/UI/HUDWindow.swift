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

    var onSpeakRequested: ((String) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onMaxRecordingReached: (() -> Void)?
    var onPermissionAction: (() -> Void)?
    var onChatSend: ((String) -> Void)?
    var onChatVoice: (() -> Void)?
    var onPinToggle: (() -> Void)?
    var chatSession: ChatSession?

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

    private func presentCornerPanel() {
        let contentView = HUDContentView(
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
            onChatVoice: onChatVoice != nil ? { [weak self] in self?.onChatVoice?() } : nil,
            onPin: { [weak self] in self?.onPinToggle?() }
        )

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

        let contentView = HUDContentView(
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
            onChatVoice: onChatVoice != nil ? { [weak self] in self?.onChatVoice?() } : nil,
            onPin: { [weak self] in self?.onPinToggle?() }
        )

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

        // Restore saved frame or use defaults
        let savedW = UserDefaults.standard.double(forKey: Constants.Defaults.chatFrameW)
        let savedH = UserDefaults.standard.double(forKey: Constants.Defaults.chatFrameH)
        let w = savedW > 0 ? savedW : Constants.ChatHUD.width
        let h = savedH > 0 ? savedH : Constants.ChatHUD.height

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let savedX = UserDefaults.standard.double(forKey: Constants.Defaults.chatFrameX)
            let savedY = UserDefaults.standard.double(forKey: Constants.Defaults.chatFrameY)
            let x = savedX > 0 ? savedX : screenFrame.maxX - w - Constants.HUD.padding
            let y = savedY > 0 ? savedY : screenFrame.maxY - h - Constants.HUD.padding
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
            .frame(minWidth: 480, minHeight: 560)
            .jarvisHUDBackground(showReticle: false)

        let hostingController = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 440, height: 480)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let w: CGFloat = 500
            let h: CGFloat = 620
            let x = screenFrame.maxX - w - Constants.HUD.padding
            let y = screenFrame.maxY - h - Constants.HUD.padding
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }

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
            .frame(minWidth: 520, minHeight: 620)
            .jarvisHUDBackground(showReticle: false)

        let hostingController = NSHostingController(rootView: view)

        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 520, height: 560)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let w: CGFloat = 560
            let h: CGFloat = 680
            let x = screenFrame.maxX - w - Constants.HUD.padding
            let y = screenFrame.maxY - h - Constants.HUD.padding
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        hudState.isVisible = true
    }

    private func resizePanelForUptodate() {
        guard let panel, let updatesService else { return }
        let view = UptodateView(service: updatesService) { [weak self] in self?.close() }
            .frame(minWidth: 480, minHeight: 560)
            .jarvisHUDBackground(showReticle: false)
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        let origin = panel.frame.origin
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: 500, height: 620), display: true, animate: true)
    }

    private func resizePanelForChat() {
        guard let panel else { return }
        let w = Constants.ChatHUD.width
        let h = Constants.ChatHUD.height
        let origin = panel.frame.origin
        // Stay borderless — ChatView's own header owns close/pin, so we don't want
        // a ghost system titlebar reserving space above our cyan background.
        panel.styleMask = [.borderless, .resizable, .nonactivatingPanel]
        panel.minSize = NSSize(width: Constants.ChatHUD.minWidth, height: Constants.ChatHUD.minHeight)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true, animate: true)
        panel.makeKey()
    }

    func saveChatFrame() {
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(frame.origin.x, forKey: Constants.Defaults.chatFrameX)
        UserDefaults.standard.set(frame.origin.y, forKey: Constants.Defaults.chatFrameY)
        UserDefaults.standard.set(frame.size.width, forKey: Constants.Defaults.chatFrameW)
        UserDefaults.standard.set(frame.size.height, forKey: Constants.Defaults.chatFrameH)
    }

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
