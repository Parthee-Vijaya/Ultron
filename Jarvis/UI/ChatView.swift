import SwiftUI
import UniformTypeIdentifiers

/// Chat HUD — β.11 Spotlight-style. Command bar on top unifies mode
/// launching; message list below renders all modes' output as bubbles.
struct ChatView: View {
    let chatSession: ChatSession
    /// Legacy send (Gemini-only). Kept so the old path still compiles while
    /// the router path rolls out — nil means "route through commandRouter".
    let onSend: (String) -> Void
    let onClose: () -> Void
    let onPin: () -> Void
    let isPinned: Bool
    /// Optional approve / reject callbacks — present when the hosting pipeline
    /// is AgentChatPipeline, nil for the Gemini ChatPipeline (no confirmations).
    var onApproveConfirmation: (() -> Void)? = nil
    var onRejectConfirmation: (() -> Void)? = nil
    /// β.11 optional wiring — when present, ChatView uses the new ChatCommandBar
    /// + router. When nil, falls back to the old legacy header + input bar.
    var commandRouter: ChatCommandRouter? = nil
    var availableModes: [Mode] = []
    var shortcutLookup: (Mode) -> String? = { _ in nil }
    /// Shared input buffer (β.12) — AppDelegate writes dictation transcripts
    /// here; the command bar binds its TextField to `buffer.text`. Optional
    /// so legacy callers without the router keep the old flow.
    var inputBuffer: ChatInputBuffer? = nil
    /// Toggle chat-mode mic recording. AppDelegate wires this to start/stop
    /// AudioCaptureManager and transcribe into `inputBuffer.text`.
    var onToggleVoiceRecord: (() -> Void)? = nil
    // v1.1.5 sidebar plumbing
    var conversationHistory: [ConversationStore.Metadata] = []
    var currentConversationID: UUID? = nil
    var onLoadConversation: ((UUID) -> Void)? = nil
    var onDeleteConversation: ((UUID) -> Void)? = nil
    /// Optional hint-row dependencies. When all are present, `ChatHintRow` is
    /// rendered below the command bar; any missing piece hides the row.
    var permissionsManager: PermissionsManager? = nil
    var hasGeminiKey: Bool = false
    var hasAnthropicKey: Bool = false
    var onOpenSettings: (() -> Void)? = nil

    @State private var inputText = ""
    @State private var selectedMode: Mode = BuiltInModes.chat
    @State private var fallbackCommandText: String = ""
    @State private var isDropTargeted: Bool = false
    @State private var showHistorySidebar: Bool = false
    @FocusState private var inputFocused: Bool

    /// When the shared `ChatInputBuffer` is provided, bind through to it so
    /// AppDelegate's dictation transcripts appear in the command bar. Otherwise
    /// fall back to local @State so legacy callers still work.
    private var commandTextBinding: Binding<String> {
        if let inputBuffer {
            return Binding(
                get: { inputBuffer.text },
                set: { inputBuffer.text = $0 }
            )
        }
        return Binding(
            get: { fallbackCommandText },
            set: { fallbackCommandText = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if showHistorySidebar, onLoadConversation != nil {
                ConversationSidebar(
                    conversations: conversationHistory,
                    currentID: currentConversationID,
                    onSelect: { id in
                        onLoadConversation?(id)
                        // keep sidebar open so user can hop between chats
                    },
                    onDelete: { id in onDeleteConversation?(id) },
                    onClose: { showHistorySidebar = false }
                )
                .transition(.move(edge: .leading))
                Divider().background(JarvisTheme.hairline)
            }
            mainColumn
        }
        .animation(.easeInOut(duration: 0.18), value: showHistorySidebar)
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if commandRouter != nil {
                ChatCommandBar(
                    chatSession: chatSession,
                    selectedMode: $selectedMode,
                    commandText: commandTextBinding,
                    availableModes: availableModes,
                    shortcutLookup: shortcutLookup,
                    onSubmit: { text in
                        Task { await commandRouter?.run(mode: selectedMode, input: text) }
                    },
                    onNewChat: { selectedMode = BuiltInModes.chat },
                    onClose: onClose,
                    onPin: onPin,
                    isPinned: isPinned,
                    isRecording: inputBuffer?.isRecording ?? false,
                    isTranscribing: inputBuffer?.isTranscribing ?? false,
                    onToggleRecord: onToggleVoiceRecord,
                    onToggleHistory: onLoadConversation != nil ? { showHistorySidebar.toggle() } : nil,
                    isHistoryOpen: showHistorySidebar
                )
                if let permissionsManager, let onOpenSettings {
                    ChatHintRow(
                        mode: selectedMode,
                        permissions: permissionsManager,
                        hasGeminiKey: hasGeminiKey,
                        hasAnthropicKey: hasAnthropicKey,
                        onOpenSettings: onOpenSettings
                    )
                }
            } else {
                chatHeader
            }
            Divider().background(JarvisTheme.hairline)
            messagesArea
            if let pending = chatSession.pendingConfirmation {
                confirmationCard(pending)
            }
            if commandRouter == nil {
                Divider().background(JarvisTheme.hairline)
                inputBar
            }
        }
        .frame(
            minWidth: Constants.ChatHUD.minWidth,
            minHeight: Constants.ChatHUD.minHeight
        )
        .overlay(dropHighlight)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    // MARK: - Drag-drop

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(JarvisTheme.accent.opacity(0.7), lineWidth: 2)
                .padding(2)
                .allowsHitTesting(false)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let router = commandRouter else { return false }
        guard let provider = providers.first else { return false }

        // v1.1.5-α.1 scope: single-file drops. Multi-file expansion is α.2+.
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let prefill = commandTextBinding.wrappedValue
            Task { @MainActor in
                commandTextBinding.wrappedValue = ""
                await router.runDropped(url: url, prefilledText: prefill)
            }
        }
        return true
    }

    // MARK: - Confirmation card

    private func confirmationCard(_ pending: PendingToolCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconForTool(pending.toolName))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JarvisTheme.accent)
                Text("J.A.R.V.I.S vil \(pending.humanSummary.lowercased(with: Locale(identifier: "da_DK")))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
            }

            if !pending.arguments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(pending.arguments, id: \.key) { pair in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pair.key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(JarvisTheme.textMuted)
                                .frame(width: 80, alignment: .leading)
                            Text(pair.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(JarvisTheme.textSecondary)
                                .lineLimit(3)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    onRejectConfirmation?()
                } label: {
                    Text("Afvis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(JarvisTheme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(JarvisTheme.surfaceElevated))
                }
                .buttonStyle(.plain)

                Button {
                    onApproveConfirmation?()
                } label: {
                    Text("Tillad")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(JarvisTheme.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(JarvisTheme.surfaceElevated.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(JarvisTheme.accent.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func iconForTool(_ name: String) -> String {
        switch name {
        case "write_file":       return "pencil.and.outline"
        case "rename_file":      return "arrow.triangle.2.circlepath"
        case "delete_file":      return "trash"
        case "create_directory": return "folder.badge.plus"
        default:                 return "wrench.and.screwdriver"
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
            Text(Constants.displayName)
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

    // MARK: - Tool invocations (v1.4 Fase 2b.2)

    @ViewBuilder
    private var toolInvocationsSection: some View {
        let count = chatSession.agentToolInvocations.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textSecondary)
                Text(count == 1 ? "1 værktøj kørt" : "\(count) værktøjer kørt")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textSecondary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 4) {
                ForEach(Array(chatSession.agentToolInvocations.enumerated()), id: \.offset) { _, invocation in
                    ToolInvocationCard(invocation: invocation)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
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
                        MessageBubble(
                            message: message,
                            onRetry: commandRouter.map { router in
                                { msg in Task { await router.retry(msg) } }
                            },
                            isStreaming: chatSession.isStreaming
                                && message.role == .assistant
                                && message.id == chatSession.messages.last?.id
                        )
                        .id(message.id)
                    }
                    // v1.4 Fase 2b.2: render agent tool invocations as compact
                    // cards after the message log. Appears when Agent mode has
                    // run tools in the current session; collapsed by default.
                    if !chatSession.agentToolInvocations.isEmpty {
                        toolInvocationsSection
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
        VStack(spacing: 18) {
            Image(systemName: "sparkle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(JarvisTheme.accent)
                .shadow(color: JarvisTheme.accent.opacity(0.4), radius: 6)
                .padding(.top, 30)
            Text("Hvordan kan jeg hjælpe?")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(JarvisTheme.textPrimary)

            if commandRouter != nil, !availableModes.isEmpty {
                modeQuickStartGrid
            } else {
                VStack(spacing: 6) {
                    chip("Opsummer et dokument for mig")
                    chip("Hvad sker der i nyhederne i dag?")
                    chip("Hjælp mig med at skrive en mail")
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var modeQuickStartGrid: some View {
        // Show up to 6 modes in a 3-column grid — gives a glanceable
        // starting point matching the Claude desktop empty state.
        let columns = [GridItem(.flexible(), spacing: 10),
                       GridItem(.flexible(), spacing: 10),
                       GridItem(.flexible(), spacing: 10)]
        // v1.1.4: prefer user-facing priority over `BuiltInModes.all` order so
        // Chat / Q&A / Vision land on the front page instead of
        // Dictation / VibeCode / Professional (which are paste-mode niches).
        let priorityOrder: [UUID] = [
            BuiltInModes.chat.id,
            BuiltInModes.qna.id,
            BuiltInModes.vision.id,
            BuiltInModes.translate.id,
            BuiltInModes.agent.id,
            BuiltInModes.summarize.id
        ]
        let modes = priorityOrder
            .compactMap { id in availableModes.first(where: { $0.id == id }) }
            .prefix(6)
            .map { $0 }
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(modes, id: \.id) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(JarvisTheme.accent)
                        Text(mode.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(JarvisTheme.textPrimary)
                        if let shortcut = shortcutLookup(mode) {
                            Text(shortcut)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(JarvisTheme.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
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
