import Foundation

/// AIProvider conformance for Gemini, wrapping `GeminiREST`. This is what
/// `ProviderRouter` delegates to when RoutingPolicy picks `.gemini` — replaces
/// the placeholder `UnsupportedGeminiProvider`.
///
/// Why a wrapper (not changing GeminiREST directly): GeminiREST is the
/// historical entry point used by ChatPipeline + non-agent flows. Those keep
/// using it unchanged. The AIProvider protocol is a newer, narrower surface
/// for the agent-pipeline world; this adapter bridges the two without
/// disturbing the rest of the codebase.
final class GeminiAIProvider: AIProvider {
    private let rest: GeminiREST
    /// Mode used for UsageTracker attribution. Gemini call sites pass their
    /// own Mode normally; inside the agent pipeline we don't know which Mode
    /// kicked off the routed call, so we tag usage as the built-in chat mode.
    private let usageMode: Mode

    init(keychain: KeychainService, usage: UsageTracker, usageMode: Mode = BuiltInModes.chat) {
        self.rest = GeminiREST(keychain: keychain, usage: usage)
        self.usageMode = usageMode
    }

    // MARK: - AIProvider conformance

    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        let request = buildRequest(messages: messages, options: options)
        let response = try await rest.generate(model: model, request: request, mode: usageMode)

        let text = response.text ?? ""
        let usage = response.usageMetadata
        return AIResponse(
            text: text,
            toolCalls: [],  // Gemini function-calling not wired into AIProvider yet
            inputTokens: usage?.promptTokenCount ?? 0,
            outputTokens: usage?.candidatesTokenCount ?? 0,
            groundingSources: response.groundingSources
        )
    }

    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        let request = buildRequest(messages: messages, options: options)
        let mode = usageMode
        return AsyncThrowingStream { continuation in
            let upstream = rest.stream(model: model, request: request, mode: mode)
            let task = Task {
                do {
                    var lastSources: [String] = []
                    var tokensIn = 0
                    var tokensOut = 0
                    for try await chunk in upstream {
                        if Task.isCancelled { break }
                        if let text = chunk.text, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        if !chunk.groundingSources.isEmpty {
                            lastSources = chunk.groundingSources
                        }
                        if let usage = chunk.usage {
                            tokensIn = usage.promptTokenCount ?? tokensIn
                            tokensOut = usage.candidatesTokenCount ?? tokensOut
                        }
                    }
                    if !lastSources.isEmpty {
                        continuation.yield(.groundingSources(lastSources))
                    }
                    continuation.yield(.usage(inputTokens: tokensIn, outputTokens: tokensOut))
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func buildRequest(messages: [AIMessage], options: AIRequestOptions) -> GeminiRequest {
        // System messages concatenate into systemInstruction; others become
        // the contents stream. Gemini expects roles "user" or "model".
        var systemText = options.systemPrompt ?? ""
        var contents: [GeminiContent] = []
        for message in messages {
            if message.role == .system {
                for part in message.parts {
                    if case .text(let t) = part {
                        systemText = systemText.isEmpty ? t : systemText + "\n" + t
                    }
                }
                continue
            }

            let role: String = (message.role == .assistant) ? "model" : "user"
            var parts: [GeminiPart] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    parts.append(.text(text))
                case .image(let data, let mime):
                    parts.append(.data(mime: mime, data))
                case .audio(let data, let mime):
                    parts.append(.data(mime: mime, data))
                case .toolUse, .toolResult:
                    // Gemini function-calling uses a different wire format;
                    // when the agent pipeline routes to Gemini we degrade
                    // gracefully to plain text (the tool-call turn becomes
                    // a no-op). Full wiring is a separate slice.
                    continue
                }
            }
            if !parts.isEmpty {
                contents.append(GeminiContent(role: role, parts: parts))
            }
        }

        var config = GeminiGenerationConfig()
        config.maxOutputTokens = options.maxTokens
        if let temp = options.temperature {
            config.temperature = temp
        }

        let systemInstruction: GeminiContent? = systemText.isEmpty
            ? nil
            : GeminiContent(role: "system", parts: [.text(systemText)])

        let tools: [GeminiTool]? = options.webSearch ? [GeminiTool.googleSearch] : nil

        return GeminiRequest(
            systemInstruction: systemInstruction,
            contents: contents,
            tools: tools,
            generationConfig: config
        )
    }
}
