import SwiftUI

/// Spotlight-inspired command bar (β.12 revamp).
///
/// Always-editable text field, a dedicated mic button next to it for voice
/// input, a mode picker pill, and an adaptive send button. Picking a mode
/// from the dropdown no longer auto-starts recording — use the mic button
/// instead. Dictation transcripts land in the text field so the user can
/// review/edit before hitting send.
struct ChatCommandBar: View {
    let chatSession: ChatSession
    @Binding var selectedMode: Mode
    @Binding var commandText: String
    let availableModes: [Mode]
    let shortcutLookup: (Mode) -> String?

    let onSubmit: (String) -> Void
    let onNewChat: () -> Void
    let onClose: () -> Void
    let onPin: () -> Void
    let isPinned: Bool
    /// Chat-dictation state, owned by `AppDelegate` and surfaced here so the
    /// mic button can flip between record / processing / idle icons.
    let isRecording: Bool
    let isTranscribing: Bool
    let onToggleRecord: (() -> Void)?
    /// v1.1.5 history sidebar toggle. Nil hides the button entirely (legacy
    /// callers that don't have conversation plumbing).
    var onToggleHistory: (() -> Void)? = nil
    var isHistoryOpen: Bool = false

    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 16))
                .foregroundStyle(JarvisTheme.accent)
                .shadow(color: JarvisTheme.accent.opacity(0.4), radius: 5)

            TextField(placeholder, text: $commandText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(JarvisTheme.textPrimary)
                .focused($inputFocused)
                .lineLimit(1...4)
                .onSubmit(performSubmit)

            Spacer(minLength: 8)

            micButton
            modePicker
            sendButton

            Divider()
                .frame(height: 18)
                .background(JarvisTheme.hairline)

            if let onToggleHistory {
                headerIconButton(
                    system: "clock.arrow.circlepath",
                    active: isHistoryOpen,
                    help: isHistoryOpen ? "Skjul historik" : "Vis historik",
                    action: onToggleHistory
                )
            }
            headerIconButton(system: isPinned ? "pin.fill" : "pin",
                             active: isPinned, help: isPinned ? "Unpin" : "Pin",
                             action: onPin)
            headerIconButton(system: "xmark", help: "Luk", action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear {
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    // MARK: - Placeholder per mode

    private var placeholder: String {
        if isRecording { return "Optager… tryk stop for at transskribere" }
        if isTranscribing { return "Transskriberer…" }
        switch selectedMode.inputKind {
        case .screenshot:
            return "Beskriv hvad du vil vide om skærmbilledet (eller lad stå tomt)…"
        case .document:
            return "Tryk dokument-knappen for at vælge en fil"
        case .voice, .text:
            switch selectedMode.name {
            case "Q&A":          return "Stil et spørgsmål…"
            case "Translate":    return "Tekst at oversætte…"
            case "Agent":        return "Bed Jarvis gøre noget…"
            case "Chat":         return "Hvad kan jeg hjælpe med i dag?"
            case "VibeCode":     return "Beskriv funktionen du vil bygge…"
            case "Professional": return "Tekst at omskrive professionelt…"
            case "Dictation":    return "Skriv eller tryk mic for at tale…"
            default:             return "Hvad kan jeg hjælpe med?"
            }
        }
    }

    // MARK: - Mic button (always visible)

    @ViewBuilder
    private var micButton: some View {
        if let onToggleRecord {
            Button(action: onToggleRecord) {
                Image(systemName: micSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(micColor)
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .help(micHelp)
        }
    }

    private var micSymbol: String {
        if isTranscribing { return "waveform" }
        return isRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var micColor: Color {
        if isTranscribing { return JarvisTheme.textMuted }
        return isRecording ? JarvisTheme.criticalGlow : JarvisTheme.accent
    }

    private var micHelp: String {
        if isTranscribing { return "Transskriberer…" }
        return isRecording ? "Stop optagelse" : "Tale-til-tekst"
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Menu {
            Button {
                commandText = ""
                chatSession.clear()
                onNewChat()
            } label: {
                Label("Ny samtale", systemImage: "plus.circle")
            }

            Divider()

            ForEach(availableModes, id: \.id) { mode in
                Button {
                    selectedMode = mode
                    inputFocused = true
                    // β.12: no longer auto-starts recording for voice modes.
                    // User explicitly clicks the mic button when ready.
                    // Document mode still opens picker on select since that's
                    // the only sensible trigger — empty submit would be noise.
                    if mode.inputKind == .document {
                        performSubmit()
                    }
                } label: {
                    HStack {
                        Label(mode.name, systemImage: mode.icon)
                        if let shortcut = shortcutLookup(mode) {
                            Spacer()
                            Text(shortcut)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(JarvisTheme.textMuted)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedMode.icon)
                    .font(.system(size: 11))
                Text(selectedMode.name)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(JarvisTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(JarvisTheme.surfaceElevated)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Send button

    @ViewBuilder
    private var sendButton: some View {
        switch selectedMode.inputKind {
        case .document:
            Button(action: performSubmit) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(JarvisTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Vælg dokument")

        case .screenshot:
            Button(action: performSubmit) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 20))
                    .foregroundStyle(canSubmitScreenshot ? JarvisTheme.accent : JarvisTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(chatSession.isStreaming)
            .help("Tag skærmbillede og spørg")

        case .text, .voice:
            Button(action: performSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(canSubmit ? JarvisTheme.accent : JarvisTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [])
            .help("Send")
        }
    }

    private var canSubmit: Bool {
        !commandText.trimmingCharacters(in: .whitespaces).isEmpty && !chatSession.isStreaming
    }

    private var canSubmitScreenshot: Bool {
        !chatSession.isStreaming
    }

    private func performSubmit() {
        let text = commandText.trimmingCharacters(in: .whitespaces)
        // Screenshot + document submit even when text is empty.
        if selectedMode.inputKind == .text || selectedMode.inputKind == .voice {
            if text.isEmpty { return }
        }
        commandText = ""
        onSubmit(text)
    }

    // MARK: - Icon buttons

    private func headerIconButton(system: String, active: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? JarvisTheme.accent : JarvisTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(JarvisTheme.surfaceElevated)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
