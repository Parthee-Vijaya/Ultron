import Foundation

/// AIProvider for a locally-running Ollama daemon. First provider in the
/// local-first routing story (Phase 3a).
///
/// Wire protocol: `POST http://localhost:11434/api/chat`
/// - Request body: `{ "model", "messages": [...], "stream": true, "tools": [...] }`
/// - Streaming response: newline-delimited JSON (NDJSON), one chunk per line,
///   terminated by a line with `"done": true`.
///
/// Docs: https://github.com/ollama/ollama/blob/main/docs/api.md
final class OllamaProvider: AIProvider {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = URL(string: "http://localhost:11434")!) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.default
        // Local HTTP; short timeouts keep the UI snappy when Ollama is down.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Non-streaming

    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse {
        let request = try buildRequest(model: model, messages: messages, options: options, streaming: false)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaError.decodingFailed
        }

        let message = (root["message"] as? [String: Any]) ?? [:]
        let text = (message["content"] as? String) ?? ""

        // Tool calls (Ollama ≥ 0.3, select models). Structure mirrors OpenAI:
        // message.tool_calls = [{ "function": { "name": ..., "arguments": {...} } }, ...]
        let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        let toolCalls = rawCalls.enumerated().compactMap { (idx, call) -> (id: String, name: String, input: [String: Any])? in
            guard let fn = call["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return nil }
            let args = (fn["arguments"] as? [String: Any]) ?? [:]
            // Ollama doesn't return a stable call id; synthesise one so the
            // Anthropic-style tool_use → tool_result threading still works.
            let id = (call["id"] as? String) ?? "ollama-call-\(idx)"
            return (id, name, args)
        }

        let inputTokens = (root["prompt_eval_count"] as? Int) ?? 0
        let outputTokens = (root["eval_count"] as? Int) ?? 0

        return AIResponse(
            text: text,
            toolCalls: toolCalls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            groundingSources: []
        )
    }

    // MARK: - Streaming (NDJSON)

    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(model: model, messages: messages, options: options, streaming: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response: response, data: nil)

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty,
                              let data = trimmed.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        if let message = obj["message"] as? [String: Any] {
                            if let text = message["content"] as? String, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            // Tool calls arrive in the final chunk for Ollama (non-incremental);
                            // emit them as discrete events so downstream orchestrators can
                            // handle them uniformly with other providers.
                            if let calls = message["tool_calls"] as? [[String: Any]] {
                                for (idx, call) in calls.enumerated() {
                                    guard let fn = call["function"] as? [String: Any],
                                          let name = fn["name"] as? String else { continue }
                                    let args = (fn["arguments"] as? [String: Any]) ?? [:]
                                    let id = (call["id"] as? String) ?? "ollama-call-\(idx)"
                                    continuation.yield(.toolCall(id: id, name: name, input: args))
                                }
                            }
                        }

                        if (obj["done"] as? Bool) == true {
                            let inputTokens = (obj["prompt_eval_count"] as? Int) ?? 0
                            let outputTokens = (obj["eval_count"] as? Int) ?? 0
                            continuation.yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
                            continuation.yield(.done)
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

    // MARK: - Request building

    private func buildRequest(model: String, messages: [AIMessage], options: AIRequestOptions, streaming: Bool) throws -> URLRequest {
        var jsonMessages: [[String: Any]] = []

        // Ollama accepts a system message as the first element of `messages`,
        // identical to OpenAI chat completions. If options.systemPrompt is set,
        // prepend it; any `.system` role messages in the thread also become
        // system entries.
        if let systemPrompt = options.systemPrompt, !systemPrompt.isEmpty {
            jsonMessages.append(["role": "system", "content": systemPrompt])
        }

        for message in messages {
            let role: String = {
                switch message.role {
                case .system: return "system"
                case .user: return "user"
                case .assistant: return "assistant"
                case .tool: return "tool"
                }
            }()

            // Ollama chat API expects a string `content` for plain text, or a
            // `tool_calls` array for assistant tool_use parts. Multi-modal
            // parts (images) attach as a top-level `images: [base64]` field.
            var textParts: [String] = []
            var images: [String] = []
            var toolCalls: [[String: Any]] = []
            var toolResultPayload: [String: String]?

            for part in message.parts {
                switch part {
                case .text(let text):
                    textParts.append(text)
                case .image(let data, _):
                    images.append(data.base64EncodedString())
                case .audio:
                    // Ollama doesn't accept audio parts on /api/chat.
                    continue
                case .toolUse(let id, let name, let input):
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": input
                        ] as [String: Any]
                    ])
                case .toolResult(let id, let content, _):
                    toolResultPayload = ["tool_call_id": id, "content": content]
                }
            }

            var entry: [String: Any] = ["role": role]
            if let toolResultPayload {
                entry["role"] = "tool"
                entry["content"] = toolResultPayload["content"] ?? ""
                entry["tool_call_id"] = toolResultPayload["tool_call_id"] ?? ""
            } else {
                entry["content"] = textParts.joined(separator: "\n")
            }
            if !images.isEmpty { entry["images"] = images }
            if !toolCalls.isEmpty { entry["tool_calls"] = toolCalls }
            jsonMessages.append(entry)
        }

        var body: [String: Any] = [
            "model": model,
            "messages": jsonMessages,
            "stream": streaming,
            // Ollama's options dict is where max_tokens / temperature live.
            "options": {
                var opts: [String: Any] = [
                    "num_predict": options.maxTokens
                ]
                if let temp = options.temperature {
                    opts["temperature"] = temp
                }
                return opts
            }()
        ]

        if !options.tools.isEmpty {
            body["tools"] = options.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema
                    ] as [String: Any]
                ]
            }
        }

        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw OllamaError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            LoggingService.shared.log("Ollama HTTP \(http.statusCode): \(bodyPreview.prefix(400))", level: .error)
            throw OllamaError.httpError(statusCode: http.statusCode, body: String(bodyPreview.prefix(400)))
        }
    }
}

enum OllamaError: LocalizedError, Sendable {
    case daemonNotRunning
    case httpError(statusCode: Int, body: String)
    case decodingFailed
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Ollama kører ikke lokalt. Start den med `ollama serve` eller `brew services start ollama`."
        case .httpError(let code, _):
            return "Ollama returnerede HTTP \(code)."
        case .decodingFailed:
            return "Kunne ikke læse svar fra Ollama."
        case .modelNotFound(let model):
            return "Model '\(model)' er ikke hentet. Kør `ollama pull \(model)`."
        }
    }
}

/// Simple health check so Settings can show an "Ollama: running" chip and the
/// provider router can fail-fast instead of waiting for a timeout.
extension OllamaProvider {
    /// Probes GET /api/tags. Returns installed model names on success, nil if
    /// the daemon isn't reachable. Never throws — this is a best-effort probe.
    static func probeInstalledModels(endpoint: URL = URL(string: "http://localhost:11434")!) async -> [String]? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let session = URLSession(configuration: .default)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return nil
        }
        return models.compactMap { $0["name"] as? String }
    }
}
