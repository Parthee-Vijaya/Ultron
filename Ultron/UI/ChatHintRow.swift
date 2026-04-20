import SwiftUI

/// Permission / setup hint shown beneath the command bar when the selected
/// mode requires something the user hasn't granted yet. Tracks per-session
/// dismissals so "Ikke nu" actually hides the row.
struct ChatHintRow: View {
    let mode: Mode
    let permissions: PermissionsManager
    let hasGeminiKey: Bool
    let hasAnthropicKey: Bool
    let onOpenSettings: () -> Void

    @State private var dismissedIDs: Set<String> = []

    private var hint: Hint? {
        switch mode.inputKind {
        case .screenshot:
            if !permissions.checkScreenRecording() {
                return Hint(
                    id: "screen-rec",
                    title: "Aktivér skærmoptagelse",
                    subtitle: "Kræves for at Vision kan tage et skærmbillede",
                    actionTitle: "Åbn indstillinger",
                    action: { permissions.openScreenRecordingSettings() }
                )
            }
        case .voice:
            if !permissions.checkMicrophone() {
                return Hint(
                    id: "mic",
                    title: "Giv adgang til mikrofonen",
                    subtitle: "Kræves for Dictation",
                    actionTitle: "Åbn indstillinger",
                    action: { permissions.openMicrophoneSettings() }
                )
            }
        case .text, .document:
            break
        }

        // API-key checks apply to all modes that actually call an LLM.
        if mode.provider == .anthropic, !hasAnthropicKey {
            return Hint(
                id: "anthropic-key",
                title: "Sæt Anthropic API-nøgle",
                subtitle: "Agent-mode kræver Claude-adgang",
                actionTitle: "Åbn indstillinger",
                action: onOpenSettings
            )
        }
        if mode.provider == .gemini, !hasGeminiKey {
            return Hint(
                id: "gemini-key",
                title: "Sæt Gemini API-nøgle",
                subtitle: "Kræves for \(mode.name)",
                actionTitle: "Åbn indstillinger",
                action: onOpenSettings
            )
        }

        return nil
    }

    var body: some View {
        if let hint, !dismissedIDs.contains(hint.id) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(UltronTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hint.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UltronTheme.textPrimary)
                    Text(hint.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(UltronTheme.textMuted)
                }
                Spacer(minLength: 0)
                Button(action: hint.action) {
                    Text(hint.actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(UltronTheme.accent))
                }
                .buttonStyle(.plain)
                Button {
                    dismissedIDs.insert(hint.id)
                } label: {
                    Text("Ikke nu")
                        .font(.system(size: 11))
                        .foregroundStyle(UltronTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(UltronTheme.surfaceElevated))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(UltronTheme.surfaceElevated.opacity(0.5))
        } else {
            EmptyView()
        }
    }

    struct Hint {
        let id: String
        let title: String
        let subtitle: String
        let actionTitle: String
        let action: () -> Void
    }
}
