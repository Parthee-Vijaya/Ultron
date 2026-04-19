import Foundation

/// Orchestrates multi-turn chat: takes user text, builds history, asks Gemini to
/// stream a response, and appends tokens to the ChatSession as they arrive.
///
/// As of v5.0.0-alpha, no SDK-level `Chat` object is cached — the full history
/// is rebuilt from `ChatSession` per turn (cheap) and sent to the REST API.
final class ChatPipeline {
    private let geminiClient: GeminiClient
    private let chatSession: ChatSession
    private let hudController: HUDWindowController
    private let mode: Mode
    private let conversationStore = ConversationStore()

    private var conversationID: UUID?

    init(
        geminiClient: GeminiClient,
        chatSession: ChatSession,
        hudController: HUDWindowController,
        mode: Mode = BuiltInModes.chat
    ) {
        self.geminiClient = geminiClient
        self.chatSession = chatSession
        self.hudController = hudController
        self.mode = mode
    }

    // MARK: - Text

    func sendTextMessage(_ text: String) {
        sendTextMessage(text, mode: nil)
    }

    /// Overload used by the ChatCommandRouter (β.11) so different chat command-bar
    /// modes (Q&A, Translate, etc.) can reuse the same pipeline with mode-specific
    /// system prompts + web-search flags. Passing `nil` falls back to the pipeline's
    /// init-time mode (default: `.chat`).
    func sendTextMessage(_ text: String, mode: Mode?) {
        chatSession.addUserMessage(text)
        let placeholderID = chatSession.addAssistantMessage("")
        chatSession.isStreaming = true

        let effectiveMode = mode ?? self.mode
        // v1.4 Fase 2b: narrate the waiting state. Web-search modes show the
        // search step explicitly; others just "Gemini thinks…".
        chatSession.currentStep = ProcessingStep(
            effectiveMode.webSearch ? .searchingWeb(query: text) : .thinking(provider: "Gemini")
        )
        Task {
            await streamResponse(placeholderID: placeholderID, text: text, mode: effectiveMode)
        }
    }

    // MARK: - Voice (transcribe first, then chat)

    func sendVoiceMessage(audioData: Data, transcribeMode: Mode) {
        chatSession.isStreaming = true

        Task {
            let transcribeResult = await geminiClient.sendAudio(audioData, mode: transcribeMode)
            switch transcribeResult {
            case .success(let transcript):
                guard !transcript.isEmpty else {
                    chatSession.isStreaming = false
                    return
                }
                chatSession.addUserMessage(transcript)
                let placeholderID = chatSession.addAssistantMessage("")
                await streamResponse(placeholderID: placeholderID, text: transcript)
            case .failure(let error):
                LoggingService.shared.log("Voice transcription failed: \(error)", level: .error)
                chatSession.isStreaming = false
            }
        }
    }

    // MARK: - Streaming core

    private func streamResponse(placeholderID: UUID, text: String, mode: Mode? = nil) async {
        // Build history from the session, dropping the trailing user message
        // (which is passed separately to the REST call) and any empty placeholders.
        let history = chatSession.currentHistory(excludingLastUser: true)
        let activeMode = mode ?? self.mode

        let result = await geminiClient.sendChatStreaming(
            history: history,
            text: text,
            mode: activeMode,
            onDelta: { [weak self] delta in
                guard let self else { return }
                // Switch the narrated step to "streaming" the moment the first
                // delta lands, so the user sees the state change from "thinking"
                // to "receiving" the way ChatGPT's UI does.
                if self.chatSession.currentStep?.kind != .streaming(provider: "Gemini") {
                    self.chatSession.currentStep = ProcessingStep(.streaming(provider: "Gemini"))
                }
                self.chatSession.appendToAssistant(id: placeholderID, delta: delta)
            }
        )

        switch result {
        case .success(let cleaned):
            chatSession.updateAssistant(id: placeholderID, text: cleaned)
        case .failure(let error):
            chatSession.markAssistantError(
                id: placeholderID,
                errorText: "Fejl: \(error.localizedDescription)",
                sourceModeID: activeMode.id,
                sourcePrompt: text
            )
        }

        chatSession.isStreaming = false
        chatSession.currentStep = nil
        conversationID = conversationStore.saveSession(chatSession, existingID: conversationID)
    }

    /// Called by AppDelegate after a Keychain key rotation. No cached state
    /// survives a rotation in v5.0.0-alpha, so this just drops the conversation
    /// pointer so the next message starts a new saved session.
    func reset() {
        conversationID = nil
    }
}
