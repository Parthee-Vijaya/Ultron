import Foundation
import Observation

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    var text: String
    let timestamp: Date
    /// v1.1.5: when the assistant turn errored, carry the error snippet + the
    /// original prompt + the mode that was used, so the UI can offer a
    /// retry pill and the router can re-run the exact same call.
    var lastError: String?
    var sourceModeID: UUID?
    var sourcePrompt: String?

    enum ChatRole: String, Codable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        timestamp: Date = Date(),
        lastError: String? = nil,
        sourceModeID: UUID? = nil,
        sourcePrompt: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.lastError = lastError
        self.sourceModeID = sourceModeID
        self.sourcePrompt = sourcePrompt
    }
}

/// Multi-turn chat session. v5.0.0-alpha removed the cached SDK `Chat` object —
/// we now pass the full message history to `GeminiClient.sendChatStreaming`
/// on each turn, which is what the REST API expects anyway. That means an
/// API-key rotation takes effect immediately: no cached credentials sitting
/// inside an SDK object.
@Observable
class ChatSession {
    var messages: [ChatMessage] = []
    var isStreaming = false

    /// Tool call currently awaiting user approval in agent mode. When non-nil
    /// the chat UI renders an inline confirmation card; nil means nothing is
    /// pending. v5.0.0-beta.2.
    var pendingConfirmation: PendingToolCall?

    /// Inline log of tool invocations from the current agent conversation —
    /// surfaces in the chat as collapsible cards so the user can see what the
    /// agent did without tailing the audit-log file.
    var agentToolInvocations: [AgentService.ToolInvocation] = []

    /// v1.4 Fase 2b: what the chat pipeline is currently doing. Nil while
    /// idle. Set by ChatPipeline / AgentChatPipeline at key transitions so
    /// the chat UI can render a narrated status line (e.g. "Ultron tænker…",
    /// "Kører read_file…") next to the streaming cursor.
    var currentStep: ProcessingStep?

    func addUserMessage(_ text: String) {
        messages.append(ChatMessage(role: .user, text: text))
    }

    func addAssistantMessage(_ text: String) -> UUID {
        let message = ChatMessage(role: .assistant, text: text)
        messages.append(message)
        return message.id
    }

    func appendToAssistant(id: UUID, delta: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
    }

    func updateAssistant(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        messages[index].lastError = nil
    }

    /// Mark an assistant bubble as errored so the chat UI can render a retry
    /// pill. Stores the original prompt + mode so a retry can re-run the
    /// exact same call. `errorText` shows up in the bubble body.
    func markAssistantError(id: UUID, errorText: String, sourceModeID: UUID?, sourcePrompt: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = errorText
        messages[index].lastError = errorText
        messages[index].sourceModeID = sourceModeID
        messages[index].sourcePrompt = sourcePrompt
    }

    /// Clear the retry metadata — used after a successful retry so the pill
    /// disappears.
    func clearAssistantError(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].lastError = nil
    }

    func clear() {
        messages.removeAll()
        isStreaming = false
        pendingConfirmation = nil
        agentToolInvocations.removeAll()
        currentStep = nil
    }

    /// v1.1.5: replace the current message log with a loaded conversation
    /// (used by the history sidebar). Mutates in place so SwiftUI observers
    /// don't lose their view identity — same pattern as `clear()`.
    func replaceMessages(_ newMessages: [ChatMessage]) {
        messages = newMessages
        isStreaming = false
        pendingConfirmation = nil
        agentToolInvocations.removeAll()
        currentStep = nil
    }

    /// Turn the message log into REST history suitable for
    /// `GeminiClient.sendChatStreaming(history:)`. Drops empty assistant
    /// placeholders (the streaming sentinel) and drops the trailing user
    /// message (which the caller passes separately as `text`).
    ///
    /// The Gemini REST API also requires history to end on a `model` turn
    /// (or be empty). α.12 adds a defensive trim that ensures we never send
    /// history ending on a `user` turn — if the session is corrupted (e.g.
    /// crash-recovered mid-turn) we walk back to the last valid model reply.
    func currentHistory(excludingLastUser: Bool = true) -> [GeminiContent] {
        var prepared: [GeminiContent] = []
        for message in messages {
            let role = message.role == .user ? "user" : "model"
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            prepared.append(GeminiContent(role: role, parts: [.text(trimmed)]))
        }
        if excludingLastUser, prepared.last?.role == "user" {
            prepared.removeLast()
        }
        // Defensive: a valid history for Gemini ends on a model turn (or is
        // empty). Trim any trailing user messages that would otherwise confuse
        // the API or the model into re-answering them.
        while prepared.last?.role == "user" {
            prepared.removeLast()
        }
        return prepared
    }
}
