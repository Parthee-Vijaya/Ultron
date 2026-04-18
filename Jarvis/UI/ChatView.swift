import SwiftUI

/// Chat HUD — Claude-desktop inspired layout. Minimal header, scrollable
/// message area, clean input bar at the bottom.
struct ChatView: View {
    let chatSession: ChatSession
    let onSend: (String) -> Void
    let onVoice: (() -> Void)?
    let onClose: () -> Void
    let onPin: () -> Void
    let isPinned: Bool

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().background(JarvisTheme.hairline)
            messagesArea
            Divider().background(JarvisTheme.hairline)
            inputBar
        }
        .frame(
            minWidth: Constants.ChatHUD.minWidth,
            minHeight: Constants.ChatHUD.minHeight
        )
        .onAppear {
            // Small delay so the panel has finished becoming key before we grab focus.
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(JarvisTheme.accent)
                .frame(width: 22, height: 22)
                .overlay(
                    Text("J")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
            Text("Jarvis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JarvisTheme.textPrimary)
            Spacer()

            if !chatSession.messages.isEmpty {
                Button {
                    chatSession.clear()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New chat")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(JarvisTheme.surfaceElevated)
                    )
                }
                .buttonStyle(.plain)
                .help("Start en ny samtale")
            }

            headerIconButton(system: isPinned ? "pin.fill" : "pin",
                             active: isPinned, help: isPinned ? "Unpin" : "Pin",
                             action: onPin)
            headerIconButton(system: "xmark", help: "Luk", action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

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

    // MARK: - Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chatSession.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chatSession.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: chatSession.messages.count) {
                if let last = chatSession.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatSession.messages.last?.text) {
                if let last = chatSession.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            // The stylised amber star that appears in Claude's empty state
            Image(systemName: "sparkle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(JarvisTheme.accent)
                .shadow(color: JarvisTheme.accent.opacity(0.4), radius: 6)
                .padding(.top, 40)
            Text("Hvad kan jeg hjælpe dig med?")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(JarvisTheme.textPrimary)
            Text("Skriv en besked, eller tryk mic for at tale")
                .font(.system(size: 12))
                .foregroundStyle(JarvisTheme.textMuted)

            // Suggestion chips — tapping one pre-fills the input
            VStack(spacing: 6) {
                chip("Opsummer et dokument for mig")
                chip("Hvad sker der i nyhederne i dag?")
                chip("Hjælp mig med at skrive en mail")
            }
            .padding(.top, 6)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private func chip(_ text: String) -> some View {
        Button { inputText = text; inputFocused = true } label: {
            HStack {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(JarvisTheme.textSecondary)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(JarvisTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(JarvisTheme.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(JarvisTheme.hairline, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            if let onVoice {
                Button(action: onVoice) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(JarvisTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(JarvisTheme.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
                .help("Tal til Jarvis")
            }

            TextField("Skriv en besked…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(JarvisTheme.textPrimary)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? JarvisTheme.surfaceElevated
                                    : JarvisTheme.accent
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatSession.isStreaming)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !chatSession.isStreaming else { return }
        inputText = ""
        onSend(text)
    }
}
