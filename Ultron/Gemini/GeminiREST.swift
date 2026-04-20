import Foundation

/// Bare-metal REST client for Gemini v1beta. Replaces `google/generative-ai-swift`
/// as of v5.0.0-alpha. Handles:
/// - Non-streaming generateContent
/// - SSE streaming via streamGenerateContent?alt=sse
/// - Tool invocations (googleSearch, codeExecution)
/// - Usage tracking hooked into the existing UsageTracker
///
/// Actor isolation: the class keeps no mutable state; nonisolated members just
/// grab an API key per request. That means it's safe to call from any actor.
final class GeminiREST: @unchecked Sendable {
    private let keychain: KeychainService
    private let usage: UsageTracker
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    private let session: URLSession

    init(keychain: KeychainService, usage: UsageTracker) {
        self.keychain = keychain
        self.usage = usage

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }

    // MARK: - Non-streaming

    func generate(model: String, request: GeminiRequest, mode: Mode) async throws -> GeminiResponse {
        let urlRequest = try buildRequest(model: model, body: request, streaming: false)
        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)

        let decoded: GeminiResponse
        do {
            decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            throw GeminiRESTError.decodingFailed(underlying: error)
        }

        if let block = decoded.promptFeedback?.blockReason {
            throw GeminiRESTError.blocked(reason: block)
        }

        trackUsage(decoded, mode: mode)
        return decoded
    }

    // MARK: - Streaming

    /// Streams partial candidates as they arrive via Server-Sent Events. Each
    /// yielded chunk contains the text delta for that partial + usage (only
    /// appears on the final chunk).
    func stream(model: String, request: GeminiRequest, mode: Mode) -> AsyncThrowingStream<GeminiStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(model: model, body: request, streaming: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try validate(response: response, data: nil)

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        // SSE format: "data: {json}"; blank lines separate events.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let payloadData = payload.data(using: .utf8) else { continue }

                        let chunk: GeminiResponse
                        do {
                            chunk = try JSONDecoder().decode(GeminiResponse.self, from: payloadData)
                        } catch {
                            // One malformed chunk shouldn't nuke the whole stream.
                            LoggingService.shared.log("Gemini stream chunk decode failed: \(error)", level: .warning)
                            continue
                        }

                        if let block = chunk.promptFeedback?.blockReason {
                            continuation.finish(throwing: GeminiRESTError.blocked(reason: block))
                            return
                        }

                        trackUsage(chunk, mode: mode)
                        continuation.yield(GeminiStreamChunk(
                            text: chunk.text,
                            usage: chunk.usageMetadata,
                            groundingSources: chunk.groundingSources
                        ))
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

    private func buildRequest(model: String, body: GeminiRequest, streaming: Bool) throws -> URLRequest {
        guard let apiKey = keychain.getAPIKey() else {
            throw GeminiRESTError.missingAPIKey
        }

        let endpoint = streaming ? "streamGenerateContent" : "generateContent"
        var url = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent("\(model):\(endpoint)")
        if streaming {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            guard let composed = components.url else { throw GeminiRESTError.invalidURL }
            url = composed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GeminiRESTError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            LoggingService.shared.log("Gemini HTTP \(http.statusCode): \(body.prefix(400))", level: .error)
            throw GeminiRESTError.httpError(statusCode: http.statusCode, body: String(body.prefix(400)))
        }
    }

    private func trackUsage(_ response: GeminiResponse, mode: Mode) {
        guard let usage = response.usageMetadata else { return }
        self.usage.trackUsage(
            model: mode.model,
            inputTokens: usage.promptTokenCount ?? 0,
            outputTokens: usage.candidatesTokenCount ?? 0
        )
    }
}
