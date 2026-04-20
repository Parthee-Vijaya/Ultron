import Foundation

/// AIProvider implementation for Google Gemini. Thin bridge over the existing
/// `GeminiREST` client — converts generic AIMessage/AITool shapes to Gemini's
/// native request types.
final class GeminiProvider: AIProvider {
    private let rest: GeminiREST
    private let usageTracker: UsageTracker

    init(keychain: KeychainService, usageTracker: UsageTracker) {
        self.rest = GeminiREST(keychain: keychain, usage: usageTracker)
        self.usageTracker = usageTracker
    }

    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        let request = buildRequest(messages: messages, options: options)
        let response = try await rest.generate(model: model, request: request, mode: dummyMode(for: options))
        return AIResponse(
            text: response.text ?? "",
            toolCalls: [],  // Gemini tool-call parsing not wired in α2 — β lands agent support
            inputTokens: response.usageMetadata?.promptTokenCount ?? 0,
            outputTokens: response.usageMetadata?.candidatesTokenCount ?? 0,
            groundingSources: response.groundingSources
        )
    }

    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = buildRequest(messages: messages, options: options)
                    for try await chunk in rest.stream(model: model, request: request, mode: dummyMode(for: options)) {
                        if Task.isCancelled { break }
                        if let text = chunk.text, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        if !chunk.groundingSources.isEmpty {
                            continuation.yield(.groundingSources(chunk.groundingSources))
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(
                                inputTokens: usage.promptTokenCount ?? 0,
                                outputTokens: usage.candidatesTokenCount ?? 0
                            ))
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Bridging

    private func buildRequest(messages: [AIMessage], options: AIRequestOptions) -> GeminiRequest {
        // Pull out the system prompt (Gemini keeps it in a separate field).
        var systemText = options.systemPrompt ?? ""
        var chatMessages: [AIMessage] = []
        for message in messages {
            if message.role == .system {
                let sysPart = message.parts.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined(separator: "\n")
                systemText = systemText.isEmpty ? sysPart : "\(systemText)\n\(sysPart)"
            } else {
                chatMessages.append(message)
            }
        }

        let contents = chatMessages.map { message -> GeminiContent in
            let role = (message.role == .assistant) ? "model" : "user"
            let parts = message.parts.compactMap { part -> GeminiPart? in
                switch part {
                case .text(let text):
                    return .text(text)
                case .image(let data, let mime):
                    return .data(mime: mime, data)
                case .audio(let data, let mime):
                    return .data(mime: mime, data)
                case .toolUse, .toolResult:
                    // Not threaded through Gemini in α2 — β adds the mapping.
                    return nil
                }
            }
            return GeminiContent(role: role, parts: parts)
        }

        let tools: [GeminiTool]? = options.webSearch ? [.googleSearch] : nil
        let systemInstruction = systemText.isEmpty ? nil :
            GeminiContent(role: "system", parts: [.text(systemText)])

        return GeminiRequest(
            systemInstruction: systemInstruction,
            contents: contents,
            tools: tools,
            generationConfig: GeminiGenerationConfig(
                maxOutputTokens: options.maxTokens,
                temperature: options.temperature
            )
        )
    }

    /// GeminiREST's usage tracker wants a Mode to attribute tokens to. Construct
    /// a throw-away one from the options so we preserve token accounting through
    /// the provider abstraction without forcing AIRequestOptions to carry a Mode.
    private func dummyMode(for options: AIRequestOptions) -> Mode {
        Mode(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000BBBB")!,
            name: "_provider",
            systemPrompt: options.systemPrompt ?? "",
            model: .flash,
            outputType: .hud,
            maxTokens: options.maxTokens,
            isBuiltIn: false
        )
    }
}
