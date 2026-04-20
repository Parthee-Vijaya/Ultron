import Foundation

/// Wraps `AgentService` into the chat paradigm. Parallel to `ChatPipeline`
/// (which routes to Gemini) — this one routes to Anthropic with the file-op
/// tool registry attached.
///
/// Lifecycle of a single user query:
/// 1. User types a prompt → `sendTextMessage(_:)` appends it to the session.
/// 2. `AgentService.run` is invoked on a Task. It loops the Anthropic
///    provider until the model returns a final non-tool answer OR hits the
///    iteration cap.
/// 3. On each `requiresConfirmation` tool call, the service awaits
///    `confirmationProvider` — this pipeline injects a closure that
///    publishes a `PendingToolCall` to the ChatSession and awaits the user's
///    decision via `approvePendingConfirmation()` / `rejectPendingConfirmation()`.
/// 4. When the loop finishes the final assistant text is appended and the
///    tool-invocation list is mirrored into `chatSession.agentToolInvocations`
///    so the chat can render collapsible tool cards.
@MainActor
final class AgentChatPipeline {
    private let agent: AgentService
    private let chatSession: ChatSession
    private let modelID: String

    /// Continuation the pipeline is awaiting for the current pending confirmation.
    /// Resolved exactly once from the UI layer via approve/reject.
    private var pendingContinuation: CheckedContinuation<Bool, Never>?

    init(provider: AIProvider, chatSession: ChatSession, modelID: String = "claude-sonnet-4-6") {
        self.agent = AgentService(provider: provider)
        self.chatSession = chatSession
        self.modelID = modelID

        agent.confirmationProvider = { [weak self] pending in
            await self?.requestConfirmation(pending) ?? false
        }
    }

    // MARK: - Public

    func sendTextMessage(_ text: String) {
        chatSession.addUserMessage(text)
        chatSession.isStreaming = true
        chatSession.currentStep = ProcessingStep(.thinking(provider: "Claude"))
        let placeholderID = chatSession.addAssistantMessage("")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await agent.run(prompt: text, model: modelID)
                chatSession.updateAssistant(id: placeholderID, text: result.finalAnswer)
                chatSession.agentToolInvocations.append(contentsOf: result.toolInvocations)
            } catch {
                chatSession.markAssistantError(
                    id: placeholderID,
                    errorText: "Fejl: \(error.localizedDescription)",
                    sourceModeID: BuiltInModes.agent.id,
                    sourcePrompt: text
                )
            }
            chatSession.isStreaming = false
            chatSession.currentStep = nil
            chatSession.pendingConfirmation = nil
        }
    }

    /// Called from the UI when the user taps "Tillad" on the confirmation card.
    func approvePendingConfirmation() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        chatSession.pendingConfirmation = nil
        continuation.resume(returning: true)
    }

    /// Called when the user taps "Afvis".
    func rejectPendingConfirmation() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        chatSession.pendingConfirmation = nil
        continuation.resume(returning: false)
    }

    // MARK: - Confirmation bridge

    private func requestConfirmation(_ pending: PendingToolCall) async -> Bool {
        // Surface the card via the session. ChatView observes pendingConfirmation
        // and renders an inline approve/reject prompt above the input bar.
        chatSession.pendingConfirmation = pending
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }
}
