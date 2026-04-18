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
    var onChatVoice: (() -> Void)?
    var onPin: (() -> Void)?

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
            }
        }
        .scaleEffect(appeared ? 1 : Constants.Animation.appearScaleFrom)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : Constants.Animation.appearOffsetFrom)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.currentPhase)
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
            if let chatSession, let onChatSend {
                ChatView(
                    chatSession: chatSession,
                    onSend: onChatSend,
                    onVoice: onChatVoice,
                    onClose: onClose,
                    onPin: { onPin?() },
                    isPinned: state.isPinned
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
            // Header: indicator + mode name + countdown
            HStack(spacing: 10) {
                HALEyeView(
                    progress: min(elapsed / Constants.maxRecordingDuration, 1.0),
                    size: 18,
                    levelMonitor: audioLevel
                )
                Text(activeModeName.isEmpty ? "Jarvis" : activeModeName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
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
        .animation(.easeInOut(duration: 0.2), value: audioLevel.isSilent)
        .animation(.easeInOut(duration: 0.2), value: speechService.transcript.isEmpty)
    }

    // MARK: - Processing

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(JarvisTheme.accent)
                Text("Behandler…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
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
                Text("Jarvis")
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
            ScrollView {
                MarkdownTextView(text, foregroundColor: JarvisTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
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
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
