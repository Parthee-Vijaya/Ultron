import Foundation

/// Placeholder AIProvider used by `ProviderRouter` when its policy decides
/// "Gemini" but we don't have a real AIProvider-conforming Gemini client yet
/// (the historical `GeminiClient` doesn't implement AIProvider).
///
/// Throwing up-front keeps the router honest — the user gets a clear error
/// instead of silently falling through to Ollama.
///
/// When Phase 3f lands a GeminiAIProvider wrapper, swap this factory in
/// `AppDelegate.ensureAgentChatPipeline` and delete this file.
final class UnsupportedGeminiProvider: AIProvider {
    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        throw RouterError.geminiNotYetWired
    }

    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RouterError.geminiNotYetWired)
        }
    }
}

enum RouterError: LocalizedError {
    case geminiNotYetWired

    var errorDescription: String? {
        switch self {
        case .geminiNotYetWired:
            return "Routeren valgte Gemini, men Ultron's agent-pipeline har endnu ikke en AIProvider-wrapper for Gemini. Vælg en konkret provider manuelt, eller brug Chat-mode (ikke Agent)."
        }
    }
}
