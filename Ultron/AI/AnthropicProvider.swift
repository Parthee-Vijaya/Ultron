import Foundation

/// AIProvider for Anthropic's Messages API. Scaffolded in α2 — tool-use parsing
/// for agent mode lands in β. For now this supports text-only send + stream
/// which is enough for β's chat baseline.
///
/// Docs: https://docs.anthropic.com/en/api/messages
final class AnthropicProvider: AIProvider {
    private let keychain: KeychainService
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession
    private let apiVersion = "2023-06-01"

    init(keychain: KeychainService) {
        self.keychain = keychain
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }

    // MARK: - Non-streaming

    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        let request = try buildRequest(model: model, messages: messages, options: options, streaming: false)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.decodingFailed
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw AnthropicError.apiError(message: message)
        }

        let contentArray = (root["content"] as? [[String: Any]]) ?? []
        let text = contentArray.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }.joined()

        let toolCalls = contentArray.compactMap { item -> (id: String, name: String, input: [String: Any])? in
            guard (item["type"] as? String) == "tool_use",
                  let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let input = item["input"] as? [String: Any] else { return nil }
            return (id, name, input)
        }

        let usage = (root["usage"] as? [String: Any]) ?? [:]
        let inputTokens = (usage["input_tokens"] as? Int) ?? 0
        let outputTokens = (usage["output_tokens"] as? Int) ?? 0
        // v1.4 Fase 3: Anthropic reports cache usage in separate fields when
        // prompt caching is active. Surface them in the log so the user can
        // see the savings; a later commit will propagate them into
        // UsageTracker for the Cockpit tile.
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        if cacheRead > 0 || cacheCreate > 0 {
            LoggingService.shared.log("Anthropic cache: read=\(cacheRead) tokens, create=\(cacheCreate) tokens")
        }

        return AIResponse(
            text: text,
            toolCalls: toolCalls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            groundingSources: []
        )
    }

    // MARK: - Streaming

    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(model: model, messages: messages, options: options, streaming: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response: response, data: nil)

                    var inputTokens = 0
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        guard let payloadData = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                            continue
                        }
                        let type = event["type"] as? String

                        switch type {
                        case "message_start":
                            if let message = event["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any],
                               let input = usage["input_tokens"] as? Int {
                                inputTokens = input
                            }
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any],
                               (delta["type"] as? String) == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(.textDelta(text))
                            }
                        case "message_delta":
                            if let usage = event["usage"] as? [String: Any],
                               let output = usage["output_tokens"] as? Int {
                                continuation.yield(.usage(inputTokens: inputTokens, outputTokens: output))
                            }
                        case "message_stop":
                            continuation.yield(.done)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func buildRequest(model: String, messages: [AIMessage], options: AIRequestOptions, streaming: Bool) throws -> URLRequest {
        guard let apiKey = keychain.getAnthropicKey() else {
            throw AnthropicError.missingAPIKey
        }

        var systemText = options.systemPrompt
        var threadMessages: [AIMessage] = []
        for message in messages {
            if message.role == .system {
                let text = message.parts.compactMap { part -> String? in
                    if case .text(let s) = part { return s }
                    return nil
                }.joined(separator: "\n")
                systemText = [systemText, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            } else {
                threadMessages.append(message)
            }
        }

        var jsonMessages: [[String: Any]] = []
        for message in threadMessages {
            let role = (message.role == .assistant) ? "assistant" : "user"
            var content: [[String: Any]] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    content.append(["type": "text", "text": text])
                case .image(let data, let mime):
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mime,
                            "data": data.base64EncodedString()
                        ]
                    ])
                case .audio:
                    // Anthropic doesn't accept audio parts; skip silently.
                    continue
                case .toolUse(let id, let name, let input):
                    content.append(["type": "tool_use", "id": id, "name": name, "input": input])
                case .toolResult(let id, let resultContent, let isError):
                    content.append([
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": resultContent,
                        "is_error": isError
                    ])
                }
            }
            jsonMessages.append(["role": role, "content": content])
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens,
            "messages": jsonMessages,
            "stream": streaming
        ]
        // v1.4 Fase 3: prompt caching on the system prompt. Large agent-mode
        // system prompts repeat across every tool-loop iteration — marking
        // them as `cache_control: ephemeral` tells Anthropic to reuse the
        // computed KV-cache for up to 5 minutes, cutting input-token cost on
        // repeat turns by ~90%. Only applied when systemText is long enough
        // to be worth caching (Anthropic requires ≥ 1024 input tokens on
        // Sonnet / ≥ 2048 on Haiku; we gate at 1500 chars ≈ 1100 tokens as
        // a safe lower bound across models).
        if let systemText, !systemText.isEmpty {
            if systemText.count >= 1500 {
                body["system"] = [[
                    "type": "text",
                    "text": systemText,
                    "cache_control": ["type": "ephemeral"]
                ] as [String: Any]]
            } else {
                body["system"] = systemText
            }
        }
        if let temp = options.temperature {
            body["temperature"] = temp
        }
        if !options.tools.isEmpty {
            body["tools"] = options.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema
                ]
            }
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            LoggingService.shared.log("Anthropic HTTP \(http.statusCode): \(bodyPreview.prefix(400))", level: .error)
            throw AnthropicError.httpError(statusCode: http.statusCode, body: String(bodyPreview.prefix(400)))
        }
    }
}

enum AnthropicError: LocalizedError, Sendable {
    case missingAPIKey
    case httpError(statusCode: Int, body: String)
    case decodingFailed
    case apiError(message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Ingen Anthropic API-nøgle fundet. Tilføj den i Settings → API Keys."
        case .httpError(let code, _):
            return "Anthropic returnerede HTTP \(code)."
        case .decodingFailed:
            return "Kunne ikke læse svar fra Anthropic."
        case .apiError(let message):
            return "Anthropic: \(message)"
        }
    }
}
