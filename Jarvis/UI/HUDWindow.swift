import AppKit
import SwiftUI

class HUDWindowController {
    private var panel: NSPanel?
    private var autoCloseTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private let hudState = HUDState()

    var onSpeakRequested: ((String) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onMaxRecordingReached: (() -> Void)?
    var onPermissionAction: (() -> Void)?

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

        if panel != nil {
            // Panel already visible — just update content (state is @Observable)
            return
        }

        let contentView = HUDContentView(
            state: hudState,
            onClose: { [weak self] in self?.close() },
            onSpeak: { [weak self] text in self?.onSpeakRequested?(text) },
            onPermissionAction: { [weak self] in self?.onPermissionAction?() }
        )

        let hostingController = NSHostingController(rootView: contentView)

        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadows
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false  // Critical: menu bar app is never "active"
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

    // MARK: - Timers

    private func scheduleAutoClose(after seconds: TimeInterval) {
        cancelAutoClose()
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
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
