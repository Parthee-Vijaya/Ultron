import SwiftUI

/// HUD content styled as a pill growing downward out of the MacBook notch.
/// The *top* edge is flat (so it tucks flush against the system notch's bottom
/// and looks like a single shape), and the *bottom* edge is rounded on both
/// sides. Content is laid out horizontally-compact so the pill stays readable
/// on a 14" display.
struct NotchHUDContentView: View {
    let state: HUDState
    let audioLevel: AudioLevelMonitor
    let waveform: WaveformBuffer
    let speechService: SpeechRecognitionService
    let activeModeName: String
    let onClose: () -> Void
    var onSpeak: ((String) -> Void)?
    var onPermissionAction: (() -> Void)?

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            phaseContent
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(
            NotchPillShape(cornerRadius: Constants.NotchHUD.cornerRadius)
        )
        .overlay(
            NotchPillShape(cornerRadius: Constants.NotchHUD.cornerRadius)
                .stroke(JarvisTheme.neonCyan.opacity(0.35), lineWidth: 0.75)
        )
        .shadow(color: JarvisTheme.neonCyan.opacity(0.25), radius: 18, y: 6)
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(y: appeared ? 1 : 0.75, anchor: .top)
        .onAppear {
            withAnimation(.spring(duration: 0.45, bounce: 0.3)) {
                appeared = true
            }
        }
    }

    // MARK: - Phases

    @ViewBuilder
    private var phaseContent: some View {
        switch state.currentPhase {
        case .recording(let elapsed):
            recordingRow(elapsed: elapsed)
        case .processing:
            processingRow
        case .result(let text):
            resultBlock(text: text)
        case .confirmation(let message):
            confirmationRow(message: message)
        case .error(let message):
            errorBlock(message: message)
        case .permissionError(let permission, let instructions):
            errorBlock(message: "\(permission): \(instructions)")
        case .chat, .uptodate:
            // Chat + Uptodate run in their own dedicated panels, never the notch.
            EmptyView()
        }
    }

    // MARK: - Recording

    private func recordingRow(elapsed: TimeInterval) -> some View {
        let remaining = max(0, Constants.maxRecordingDuration - elapsed)
        return VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ArcReactorView(
                    progress: min(elapsed / Constants.maxRecordingDuration, 1.0),
                    size: 40,
                    levelMonitor: audioLevel
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        modeBadge
                        Spacer(minLength: 0)
                        Text(formatTime(remaining))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.85))
                    }
                    if !speechService.transcript.isEmpty {
                        Text(speechService.transcript)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(2)
                            .transition(.opacity)
                    } else {
                        Text(audioLevel.isSilent ? "Slip for at sende" : "Lytter…")
                            .font(.caption)
                            .foregroundStyle(audioLevel.isSilent ? JarvisTheme.brightCyan : JarvisTheme.neonCyan.opacity(0.55))
                    }
                }
            }
            WaveformScope(buffer: waveform, height: 18)
        }
        .animation(.easeInOut(duration: 0.2), value: audioLevel.isSilent)
        .animation(.easeInOut(duration: 0.2), value: speechService.transcript.isEmpty)
    }

    private var modeBadge: some View {
        Text(activeModeName.isEmpty ? "Jarvis" : activeModeName)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .fill(JarvisTheme.neonCyan.opacity(0.18))
                    .overlay(Capsule().stroke(JarvisTheme.neonCyan.opacity(0.55), lineWidth: 0.5))
            }
            .foregroundStyle(JarvisTheme.brightCyan)
    }

    // MARK: - Processing

    private var processingRow: some View {
        HStack(spacing: 12) {
            ArcReactorView(progress: 0, size: 32, levelMonitor: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("Behandler…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JarvisTheme.brightCyan)
                if !speechService.transcript.isEmpty {
                    Text(speechService.transcript)
                        .font(.caption2)
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Result

    private func resultBlock(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(JarvisTheme.neonCyan)
                Text("Jarvis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JarvisTheme.brightCyan)
                Spacer()
                Button { onSpeak?(text) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.75))
                }
                .buttonStyle(.borderless)
                .help("Læs op")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
                }
                .buttonStyle(.borderless)
            }
            ScrollView {
                MarkdownTextView(text, foregroundColor: .white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Constants.NotchHUD.maxHeight - 60)
        }
    }

    // MARK: - Confirmation

    private func confirmationRow(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(JarvisTheme.successGlow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Error

    private func errorBlock(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(JarvisTheme.criticalGlow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fejl")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JarvisTheme.criticalGlow)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
            }
            .buttonStyle(.borderless)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Flat top, rounded bottom corners. Matches the visual language of the notch
/// (camera cutout has flat top + curved bottom) so the pill looks continuous.
struct NotchPillShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))                          // top-left
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))                       // top-right
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))                   // down the right
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))                   // bottom
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
