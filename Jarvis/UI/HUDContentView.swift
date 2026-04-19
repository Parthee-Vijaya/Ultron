import SwiftUI

/// HUD content — Claude-desktop inspired layout for v5.0.0-alpha.5.
///
/// Flat dark surface, amber accent, compact header row, generous body area,
/// prominent waveform at the bottom during recording. No glow/bloom effects,
/// system typography throughout.
struct HUDContentView: View {
    let state: HUDState
    let audioLevel: AudioLevelMonitor
    let waveform: WaveformBuffer
    let speechService: SpeechRecognitionService
    let activeModeName: String
    let onClose: () -> Void
    var onSpeak: ((String) -> Void)?
    var onPermissionAction: (() -> Void)?
    var chatSession: ChatSession?
    var onChatSend: ((String) -> Void)?
    var onPin: (() -> Void)?
    // Agent-mode plumbing (β.2)
    var onAgentChatSend: ((String) -> Void)?
    var onAgentApprove: (() -> Void)?
    var onAgentReject: (() -> Void)?
    // β.11: unified chat command bar + router
    var commandRouter: ChatCommandRouter?
    var availableModes: [Mode] = []
    var shortcutLookup: (Mode) -> String? = { _ in nil }
    var onToggleVoiceRecord: (() -> Void)?
    var inputBuffer: ChatInputBuffer?
    var permissionsManager: PermissionsManager?
    var hasGeminiKey: Bool = false
    var hasAnthropicKey: Bool = false
    var onOpenSettings: (() -> Void)?
    // v1.1.5 history sidebar wiring
    var conversationHistory: [ConversationStore.Metadata] = []
    var currentConversationID: UUID?
    var onLoadConversation: ((UUID) -> Void)?
    var onDeleteConversation: ((UUID) -> Void)?
    /// v1.3 hover-pause: wired from AppDelegate → HUDWindowController.onHoverChanged.
    /// Called true on pointer-enter and false on leave over the non-chat HUD card
    /// so the auto-close timer can be paused while the user is still reading.
    var onHoverChanged: ((Bool) -> Void)?
    /// v1.4 Fase 2b.5: optional retry callback for the error card. When nil,
    /// the error view hides the "Prøv igen" button. Set by HUDWindowController
    /// when `showError(_:retryHandler:)` is called with a non-nil handler.
    var onErrorRetry: (() -> Void)?

    @State private var appeared = false

    private var isChat: Bool {
        if case .chat = state.currentPhase { return true }
        return false
    }

    var body: some View {
        Group {
            if isChat {
                phaseContent
                    .frame(
                        minWidth: Constants.ChatHUD.minWidth,
                        maxWidth: .infinity,
                        minHeight: Constants.ChatHUD.minHeight,
                        maxHeight: .infinity
                    )
                    .jarvisHUDBackground()
            } else {
                VStack(spacing: 0) {
                    phaseContent
                }
                .padding(Constants.HUD.padding)
                .frame(width: Constants.HUD.width)
                .jarvisHUDBackground()
                .onHover { hovering in onHoverChanged?(hovering) }
            }
        }
        .scaleEffect(appeared ? 1 : Constants.Animation.appearScaleFrom)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : Constants.Animation.appearOffsetFrom)
        // NB: intentionally NO implicit animation on state.currentPhase here.
        // An implicit animation there caused SwiftUI to fade the old subview out
        // and the new one in, leaving a zero-opacity gap so users sometimes
        // never saw the result — the bug reported in α.7.
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.currentPhase {
        case .recording(let elapsed):
            recordingView(elapsed: elapsed)
        case .processing:
            processingView
        case .result(let text):
            resultView(text: text)
        case .confirmation(let message):
            confirmationView(message: message)
        case .error(let message):
            errorView(message: message)
        case .permissionError(let permission, let instructions):
            permissionErrorView(permission: permission, instructions: instructions)
        case .chat:
            // v1.1.4+: chat and agent chat share one unified panel. Agent mode
            // is picked via the command-bar dropdown.
            if let chatSession, let onChatSend {
                ChatView(
                    chatSession: chatSession,
                    onSend: onChatSend,
                    onClose: onClose,
                    onPin: { onPin?() },
                    isPinned: state.isPinned,
                    onApproveConfirmation: onAgentApprove,
                    onRejectConfirmation: onAgentReject,
                    commandRouter: commandRouter,
                    availableModes: availableModes,
                    shortcutLookup: shortcutLookup,
                    inputBuffer: inputBuffer,
                    onToggleVoiceRecord: onToggleVoiceRecord,
                    conversationHistory: conversationHistory,
                    currentConversationID: currentConversationID,
                    onLoadConversation: onLoadConversation,
                    onDeleteConversation: onDeleteConversation,
                    permissionsManager: permissionsManager,
                    hasGeminiKey: hasGeminiKey,
                    hasAnthropicKey: hasAnthropicKey,
                    onOpenSettings: onOpenSettings
                )
            }
        case .uptodate, .infoMode:
            EmptyView()
        }
    }

    // MARK: - Recording

    private func recordingView(elapsed: TimeInterval) -> some View {
        let remaining = max(0, Constants.maxRecordingDuration - elapsed)
        return VStack(alignment: .leading, spacing: 10) {
            // Header: indicator + mode name + Whisper badge + countdown
            HStack(spacing: 10) {
                HALEyeView(
                    progress: min(elapsed / Constants.maxRecordingDuration, 1.0),
                    size: 18,
                    levelMonitor: audioLevel
                )
                Text(activeModeName.isEmpty ? Constants.displayName : activeModeName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                if state.localSTTReady {
                    whisperBadge
                }
                Spacer()
                Text(formatTime(remaining))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(JarvisTheme.textSecondary)
            }

            // Live transcription area — grows to fit 3 lines
            ZStack(alignment: .topLeading) {
                if speechService.transcript.isEmpty {
                    Text(audioLevel.isSilent ? "Slip for at sende" : "Lytter…")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            audioLevel.isSilent ? JarvisTheme.accent : JarvisTheme.textSecondary
                        )
                        .transition(.opacity)
                } else {
                    Text(speechService.transcript)
                        .font(.system(size: 14))
                        .foregroundStyle(JarvisTheme.textPrimary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 42, alignment: .topLeading)

            // Prominent waveform — the visual emphasis of the recording HUD
            WaveformScope(buffer: waveform, height: 72)
        }
        .animation(JarvisTheme.springSnappy, value: audioLevel.isSilent)
        .animation(JarvisTheme.springSnappy, value: speechService.transcript.isEmpty)
    }

    /// "On-device" badge rendered next to the mode name while recording. Only
    /// visible when the Whisper model is loaded — during the ~5s cold-start
    /// it's hidden, making the transition from "Gemini STT" to "local STT"
    /// visually clear.
    private var whisperBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path")
                .font(.system(size: 9, weight: .semibold))
            Text("Whisper")
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(JarvisTheme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(JarvisTheme.accent.opacity(0.15))
                .overlay(Capsule().stroke(JarvisTheme.accent.opacity(0.4), lineWidth: 0.5))
        )
        .accessibilityLabel("Whisper aktiv, offline transkription")
    }

    // MARK: - Processing

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(JarvisTheme.accent)
                Text(state.currentStep?.displayText ?? "Behandler…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .animation(JarvisTheme.springSnappy, value: state.currentStep)
                Spacer()
                if let step = state.currentStep {
                    Image(systemName: step.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(JarvisTheme.accent.opacity(0.75))
                        .transition(.opacity)
                }
            }
            if !speechService.transcript.isEmpty {
                Text(speechService.transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Result

    private func resultView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(JarvisTheme.accent)
                    .frame(width: 8, height: 8)
                Text(Constants.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
                iconButton(system: state.isPinned ? "pin.fill" : "pin",
                           active: state.isPinned, help: state.isPinned ? "Unpin" : "Pin") {
                    onPin?()
                }
                iconButton(system: "speaker.wave.2.fill", help: "Læs op") {
                    onSpeak?(text)
                }
                iconButton(system: "xmark", help: "Luk", action: onClose)
            }
            Rectangle()
                .fill(JarvisTheme.hairline)
                .frame(height: 1)

            // Rules:
            // - Short answers flow naturally — HUD grows to fit.
            // - Long answers (>500 chars) go in a fixed-height scrollview so the
            //   HUD doesn't balloon past the screen.
            // The .fixedSize(vertical: true) is key — without it, the text view
            // reports 0 intrinsic height and collapses to nothing (the "only
            // header visible" bug reported in α.7).
            if text.count > 500 {
                ScrollView {
                    MarkdownTextView(text, foregroundColor: JarvisTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 260)
            } else {
                MarkdownTextView(text, foregroundColor: JarvisTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Confirmation

    private func confirmationView(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(JarvisTheme.successGlow)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(JarvisTheme.textPrimary)
            Spacer()
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(JarvisTheme.criticalGlow)
                Text("Fejl")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
                iconButton(system: "xmark", help: "Luk", action: onClose)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(JarvisTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onErrorRetry {
                Button {
                    onErrorRetry()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Prøv igen")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(JarvisTheme.accent)
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityHint("Kører den seneste kommando igen")
            }
        }
    }

    // MARK: - Permission Error

    private func permissionErrorView(permission: String, instructions: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(JarvisTheme.warningGlow)
                Text("\(permission) kræves")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
                iconButton(system: "xmark", help: "Luk", action: onClose)
            }
            Text(instructions)
                .font(.system(size: 13))
                .foregroundStyle(JarvisTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = onPermissionAction {
                Button("Åbn Indstillinger") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(JarvisTheme.accent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func iconButton(system: String, active: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? JarvisTheme.accent : JarvisTheme.textSecondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(JarvisTheme.surfaceElevated)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        // `help` doubles as the VoiceOver label so screen readers don't
        // announce "Button" — announce "Luk" / "Pin" / "Læs op" instead.
        .accessibilityLabel(help)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
