import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// v1.4 Fase 2b.4: shared chat input buffer. Exposed so the "+" →
    /// Vedhæft billede flow can stash picked image data on
    /// `attachedImage`, and so the preview row can read + clear it.
    var inputBuffer: ChatInputBuffer? = nil

    @FocusState private var inputFocused: Bool

    var body: some View {
        // v1.4 Fase 2c: Gemini-style pill. Only the minimal controls live
        // inside the input row: "+", text, "Fast" mode label, mic. Send
        // happens via Enter. History / pin / close moved to the chat
        // window's top-right header (see `ChatView.chatTopBar`).
        VStack(alignment: .leading, spacing: 6) {
            if let inputBuffer, let imageData = inputBuffer.attachedImage {
                AttachedImagePreview(imageData: imageData) {
                    inputBuffer.attachedImage = nil
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: 10) {
                plusMenu

                TextField(placeholder, text: $commandText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .focused($inputFocused)
                    .lineLimit(1...4)
                    .onSubmit(performSubmit)

                Spacer(minLength: 8)

                modeLabel
                micButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(JarvisTheme.surfaceElevated.opacity(0.4))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(JarvisTheme.hairline, lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .onAppear {
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    // MARK: - Mode label (replaces the pill-chip modePicker)

    /// Compact plain-text mode indicator — matches Gemini's "Fast" label.
    /// Click opens the same menu as the old pill-chip so power users can
    /// still switch modes without leaving the command bar.
    private var modeLabel: some View {
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
                    if mode.inputKind == .document {
                        performSubmit()
                    }
                } label: {
                    HStack {
                        Label(mode.name, systemImage: mode.icon)
                        if let shortcut = shortcutLookup(mode) {
                            Spacer()
                            Text(shortcut)
                                .font(.caption2.monospaced())
                                .foregroundStyle(JarvisTheme.textMuted)
                        }
                    }
                }
            }
        } label: {
            Text(modeShortLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(JarvisTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Aktuel tilstand: \(selectedMode.name). Tryk for at skifte.")
    }

    /// Short display name for the currently-selected mode. Gemini uses "Fast"
    /// for its quick model; we map mode names to 1-word labels that fit the
    /// tight pill. Unmapped modes show their first word.
    private var modeShortLabel: String {
        switch selectedMode.name {
        case "Chat":          return "Chat"
        case "Q&A":           return "Q&A"
        case "Vision":        return "Syn"
        case "Agent":         return "Agent"
        case "Translate":     return "Oversæt"
        case "Dictation":     return "Diktat"
        case "VibeCode":      return "Kode"
        case "Professional":  return "Pro"
        case "Summarize":     return "Sum"
        default:              return selectedMode.name.split(separator: " ").first.map(String.init) ?? selectedMode.name
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

    // MARK: - Plus menu (attachments + mode quick-switch)

    /// v1.4 Fase 2c: compact "+" button that replaces the leading sparkle
    /// icon. Opens a Menu with the attachment + mode actions that used to be
    /// scattered across the mode picker + document-mode submit button. Matches
    /// the Gemini desktop reference layout.
    private var plusMenu: some View {
        Menu {
            Button {
                switchTo(inputKind: .document, fallback: BuiltInModes.summarize)
            } label: {
                Label("Vedhæft fil", systemImage: "paperclip")
            }

            Button {
                pickImageAttachment()
            } label: {
                Label("Vedhæft billede", systemImage: "photo")
            }

            Button {
                switchTo(inputKind: .screenshot, fallback: BuiltInModes.vision)
            } label: {
                Label("Tag skærmbillede", systemImage: "camera.viewfinder")
            }

            Divider()

            // Modes submenu — quick switch without hunting through the mode
            // picker. Keeps the plus menu as the "what do you want to do?"
            // entry point; the mode-chip further right stays for power users.
            Menu {
                ForEach(availableModes, id: \.id) { mode in
                    Button {
                        selectedMode = mode
                        inputFocused = true
                    } label: {
                        HStack {
                            Label(mode.name, systemImage: mode.icon)
                            if let shortcut = shortcutLookup(mode) {
                                Spacer()
                                Text(shortcut)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(JarvisTheme.textMuted)
                            }
                        }
                    }
                }
            } label: {
                Label("Skift tilstand", systemImage: "square.grid.2x2")
            }

            Button {
                commandText = ""
                chatSession.clear()
                onNewChat()
            } label: {
                Label("Ny samtale", systemImage: "plus.circle")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JarvisTheme.textPrimary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(JarvisTheme.surfaceElevated.opacity(0.9))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Vedhæft eller skift tilstand")
    }

    /// Flip the selected mode to one whose `inputKind` matches the requested
    /// kind, falling back to the supplied mode when the availableModes list
    /// doesn't include one (can happen during mode-file editing). For
    /// `.document` and `.screenshot`, also calls `performSubmit()` immediately
    /// so the user's click fires the picker/screenshot without a second tap.
    private func switchTo(inputKind: InputKind, fallback: Mode) {
        let target = availableModes.first { $0.inputKind == inputKind } ?? fallback
        selectedMode = target
        inputFocused = true
        // Document + screenshot modes normally submit-on-select (the user's
        // intent is "open picker now"), matching the mode-picker's previous
        // behaviour.
        if inputKind == .document || inputKind == .screenshot {
            performSubmit()
        }
    }

    /// v1.4 Fase 2b.4: open an NSOpenPanel to pick an image file, downscale
    /// it to a sensible max dimension, and store it as attached data on the
    /// shared `ChatInputBuffer`. Next submit routes through
    /// `ChatCommandRouter.runTextWithImage(...)` (added below) so the image
    /// flows through the existing `sendTextWithImage` Gemini path.
    private func pickImageAttachment() {
        guard let inputBuffer else {
            LoggingService.shared.log("Image attach requested but ChatInputBuffer not wired", level: .warning)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Vedhæft"
        panel.title = "Vælg billede"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            LoggingService.shared.log("Image attach: could not load NSImage from \(url.lastPathComponent)", level: .warning)
            return
        }
        // Downscale to keep request payload sane. Gemini accepts up to ~20 MB
        // per image; typical photos easily exceed that once base64 encoded.
        let downscaled = Self.downscaledPNGData(image: image, maxDimension: 1280)
        inputBuffer.attachedImage = downscaled
        inputFocused = true
        LoggingService.shared.log("Image attached (\(downscaled?.count ?? 0) bytes)")
    }

    // MARK: - Image preview row

    /// Thumbnail of the currently-attached image with a remove button.
    /// Lives above the command pill so the user can see what will be sent
    /// alongside the typed text.
    fileprivate struct AttachedImagePreview: View {
        let imageData: Data
        let onRemove: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(JarvisTheme.hairline, lineWidth: 0.5)
                        )
                }
                Text("Billede vedhæftet")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(JarvisTheme.textSecondary)
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(JarvisTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Fjern vedhæftning")
                .accessibilityLabel("Fjern vedhæftet billede")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(JarvisTheme.surfaceElevated.opacity(0.55))
            )
        }
    }

    /// Fit the image into a max-dimension bounding box, preserving aspect ratio.
    /// Returns PNG-encoded data; nil only if NSImage → bitmap bridging fails.
    private static func downscaledPNGData(image: NSImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gfx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = gfx
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        return rep.representation(using: .png, properties: [:])
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
            .accessibilityLabel(micHelp)
        }
    }

    private var micSymbol: String {
        if isTranscribing { return "waveform" }
        return isRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var micColor: Color {
        if isTranscribing { return JarvisTheme.textMuted }
        // v1.4 Fase 2c: idle mic reads as a regular secondary icon — not a
        // brand-coloured call-to-action. Accent is reserved for the "+" menu
        // background and the recording red state.
        return isRecording ? JarvisTheme.criticalGlow : JarvisTheme.textSecondary
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
                                .font(.caption2.monospaced())
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
                    .font(.caption.weight(.medium))
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
            .accessibilityLabel("Vælg dokument og send")

        case .screenshot:
            Button(action: performSubmit) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 20))
                    .foregroundStyle(canSubmitScreenshot ? JarvisTheme.accent : JarvisTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(chatSession.isStreaming)
            .help("Tag skærmbillede og spørg")
            .accessibilityLabel("Tag skærmbillede og send")

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
            .accessibilityLabel("Send besked")
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
