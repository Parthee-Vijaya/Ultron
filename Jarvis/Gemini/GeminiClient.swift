import Foundation

/// High-level Gemini façade used by RecordingPipeline, ChatPipeline and the
/// summary/info flows. Wraps the raw REST client in domain-specific methods
/// with retry + post-processing.
///
/// As of v5.0.0-alpha this class no longer depends on `google/generative-ai-swift`.
/// All network I/O goes through `GeminiREST`.
final class GeminiClient {
    private let keychainService: KeychainService
    private let usageTracker: UsageTracker
    private let rest: GeminiREST

    init(keychainService: KeychainService, usageTracker: UsageTracker) {
        self.keychainService = keychainService
        self.usageTracker = usageTracker
        self.rest = GeminiREST(keychain: keychainService, usage: usageTracker)
    }

    // MARK: - Connection test

    func testConnection() async -> Result<String, Error> {
        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text("You are a test assistant.")]),
            contents: [GeminiContent(role: "user", parts: [.text("Say 'Connection successful' in exactly those words.")])],
            tools: nil,
            generationConfig: GeminiGenerationConfig(maxOutputTokens: 32)
        )
        do {
            let response = try await rest.generate(model: Constants.GeminiModelName.flash,
                                                   request: request, mode: BuiltInModes.qna)
            if let text = response.text {
                LoggingService.shared.log("Gemini connection test: OK")
                return .success(text)
            }
            return .failure(GeminiRESTError.emptyResponse)
        } catch {
            LoggingService.shared.log("Gemini connection test failed: \(error)", level: .error)
            return .failure(error)
        }
    }

    // MARK: - Audio (single-turn)

    func sendAudio(_ audioData: Data, mode: Mode) async -> Result<String, Error> {
        if mode.webSearch {
            return await withRetry { [weak self] in
                guard let self else { throw GeminiRESTError.missingAPIKey }
                let question = try await self.transcribe(audioData: audioData)
                return try await self.sendTextWithSearch(prompt: question, imageData: nil, mode: mode)
            }
        }
        return await withRetry { [weak self] in
            guard let self else { throw GeminiRESTError.missingAPIKey }
            return try await self.generateOnce(
                parts: [.data(mime: "audio/wav", audioData)],
                mode: mode
            )
        }
    }

    func sendAudioWithImage(_ audioData: Data, imageData: Data, mode: Mode) async -> Result<String, Error> {
        if mode.webSearch {
            return await withRetry { [weak self] in
                guard let self else { throw GeminiRESTError.missingAPIKey }
                let question = try await self.transcribe(audioData: audioData)
                return try await self.sendTextWithSearch(prompt: question, imageData: imageData, mode: mode)
            }
        }
        return await withRetry { [weak self] in
            guard let self else { throw GeminiRESTError.missingAPIKey }
            return try await self.generateOnce(
                parts: [.data(mime: "audio/wav", audioData), .data(mime: "image/png", imageData)],
                mode: mode
            )
        }
    }

    // MARK: - Plain text (one-shot, no chat)

    func sendText(prompt: String, mode: Mode) async -> Result<String, Error> {
        if mode.webSearch {
            return await withRetry { [weak self] in
                guard let self else { throw GeminiRESTError.missingAPIKey }
                return try await self.sendTextWithSearch(prompt: prompt, imageData: nil, mode: mode)
            }
        }
        return await withRetry { [weak self] in
            guard let self else { throw GeminiRESTError.missingAPIKey }
            return try await self.generateOnce(parts: [.text(prompt)], mode: mode)
        }
    }

    // MARK: - Chat (multi-turn, no cached SDK object — history is passed each turn)

    /// Stream a multi-turn chat reply. History should *not* include the current
    /// user message — it's passed as `text` and appended server-side.
    func sendChatStreaming(
        history: [GeminiContent],
        text: String,
        mode: Mode,
        onDelta: @escaping (String) -> Void
    ) async -> Result<String, Error> {
        let modelName = modelName(for: mode)
        var contents = history
        contents.append(GeminiContent(role: "user", parts: [.text(text)]))

        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text(mode.systemPrompt)]),
            contents: contents,
            tools: mode.webSearch ? [.googleSearch] : nil,
            generationConfig: GeminiGenerationConfig(maxOutputTokens: mode.maxTokens)
        )

        do {
            var full = ""
            var loggedGrounding = false
            for try await chunk in rest.stream(model: modelName, request: request, mode: mode) {
                if let delta = chunk.text {
                    full += delta
                    onDelta(delta)
                }
                if !loggedGrounding, !chunk.groundingSources.isEmpty {
                    LoggingService.shared.log("Gemini grounded on: \(chunk.groundingSources.prefix(5).joined(separator: ", "))")
                    loggedGrounding = true
                }
            }
            guard !full.isEmpty else { return .failure(GeminiRESTError.emptyResponse) }
            return .success(postProcess(full))
        } catch {
            LoggingService.shared.log("Gemini stream error: \(error)", level: .error)
            return .failure(error)
        }
    }

    /// Stream a single audio turn (used by the voice-in-chat path).
    func sendAudioStreaming(
        _ audioData: Data,
        mode: Mode,
        onDelta: @escaping (String) -> Void
    ) async -> Result<String, Error> {
        let modelName = modelName(for: mode)
        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text(mode.systemPrompt)]),
            contents: [GeminiContent(role: "user", parts: [.data(mime: "audio/wav", audioData)])],
            tools: nil,
            generationConfig: GeminiGenerationConfig(maxOutputTokens: mode.maxTokens)
        )
        do {
            var full = ""
            for try await chunk in rest.stream(model: modelName, request: request, mode: mode) {
                if let delta = chunk.text {
                    full += delta
                    onDelta(delta)
                }
            }
            guard !full.isEmpty else { return .failure(GeminiRESTError.emptyResponse) }
            return .success(postProcess(full))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Internals

    private func generateOnce(parts: [GeminiPart], mode: Mode) async throws -> String {
        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text(mode.systemPrompt)]),
            contents: [GeminiContent(role: "user", parts: parts)],
            tools: nil,
            generationConfig: GeminiGenerationConfig(maxOutputTokens: mode.maxTokens)
        )
        let response = try await rest.generate(model: modelName(for: mode), request: request, mode: mode)
        guard let text = response.text else { throw GeminiRESTError.emptyResponse }
        LoggingService.shared.log("Gemini response received (\(text.count) chars)")
        return postProcess(text)
    }

    private func sendTextWithSearch(prompt: String, imageData: Data?, mode: Mode) async throws -> String {
        // 1) Pre-fetch real web results via DuckDuckGo. Gemini's own `googleSearch`
        //    tool fires inconsistently — sometimes the model "knows" a stale answer
        //    and skips the tool. Doing our own DDG call FIRST guarantees fresh
        //    context in the prompt; we keep `googleSearch` enabled too as a
        //    cross-reference.
        let searchResults = await WebSearchService.shared.search(query: prompt, limit: 4)
        var augmentedPrompt = prompt
        if !searchResults.isEmpty {
            let today = Self.todayDateString()
            let context = searchResults
                .map { $0.promptLine }
                .joined(separator: "\n")
            augmentedPrompt = """
            Dato: \(today)
            Web-søgeresultater fra DuckDuckGo:
            \(context)

            Brugerens spørgsmål: \(prompt)

            Brug søgeresultaterne som primær kilde. Hvis de ikke dækker spørgsmålet, \
            brug google_search-værktøjet til at søge videre. Svar kortfattet på samme sprog \
            som spørgsmålet. Angiv gerne 1-2 kilder i parentes.
            """
            LoggingService.shared.log("WebSearch: \(searchResults.count) DDG results prepended")
        } else {
            LoggingService.shared.log("WebSearch: DDG returned 0 results — relying on googleSearch tool", level: .warning)
        }

        var parts: [GeminiPart] = [.text(augmentedPrompt)]
        if let imageData { parts.append(.data(mime: "image/png", imageData)) }
        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text(mode.systemPrompt)]),
            contents: [GeminiContent(role: "user", parts: parts)],
            tools: [.googleSearch],
            generationConfig: GeminiGenerationConfig(maxOutputTokens: mode.maxTokens)
        )

        LoggingService.shared.log("Gemini REST+search POST: model=\(modelName(for: mode)), promptChars=\(augmentedPrompt.count), image=\(imageData != nil)")
        let response = try await rest.generate(model: modelName(for: mode), request: request, mode: mode)
        guard let text = response.text else { throw GeminiRESTError.emptyResponse }
        if !response.groundingSources.isEmpty {
            LoggingService.shared.log("Gemini grounded on: \(response.groundingSources.prefix(5).joined(separator: ", "))")
        }
        return postProcess(text)
    }

    private static func todayDateString() -> String {
        let df = DateFormatter()
        df.dateStyle = .full
        df.locale = Locale(identifier: "da_DK")
        return df.string(from: Date())
    }

    /// Transcribe an audio blob to text. Used before the grounded-search call so
    /// Gemini's google_search tool fires (it doesn't activate on raw audio input).
    private func transcribe(audioData: Data) async throws -> String {
        let prompt = """
        Transcribe the user's audio into plain text. Return ONLY the transcribed question, \
        no commentary. Preserve the original language.
        """
        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text(prompt)]),
            contents: [GeminiContent(role: "user", parts: [.data(mime: "audio/wav", audioData)])],
            tools: nil,
            generationConfig: GeminiGenerationConfig(maxOutputTokens: 1024)
        )
        let response = try await rest.generate(model: Constants.GeminiModelName.flash,
                                               request: request, mode: BuiltInModes.qna)
        guard let text = response.text else { throw GeminiRESTError.emptyResponse }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        LoggingService.shared.log("Transcribed question: \(cleaned.prefix(120))")
        return cleaned
    }

    private func modelName(for mode: Mode) -> String {
        mode.model == .pro ? Constants.GeminiModelName.pro : Constants.GeminiModelName.flash
    }

    // MARK: - Retry with exponential backoff

    private func withRetry(
        maxAttempts: Int = Constants.Retry.maxAttempts,
        operation: @escaping () async throws -> String
    ) async -> Result<String, Error> {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return .success(try await operation())
            } catch {
                lastError = error
                guard isTransientError(error), attempt < maxAttempts else {
                    LoggingService.shared.log("Gemini error (attempt \(attempt)/\(maxAttempts), not retrying): \(error)", level: .error)
                    break
                }
                let delay = Constants.Retry.baseDelay * pow(Constants.Retry.backoffMultiplier, Double(attempt - 1))
                LoggingService.shared.log("Gemini error (attempt \(attempt)/\(maxAttempts)), retrying in \(delay)s", level: .warning)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        return .failure(lastError ?? GeminiRESTError.emptyResponse)
    }

    private func isTransientError(_ error: Error) -> Bool {
        if let rest = error as? GeminiRESTError, case .httpError(let code, _) = rest, (500..<600).contains(code) {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let transient = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet]
            return transient.contains(nsError.code)
        }
        return false
    }

    // MARK: - Post processing

    private func postProcess(_ text: String) -> String {
        var result = text
        let patterns = [
            "^(Here'?s?|Her er) (the |din |your )?(cleaned[- ]?up |rensede )?te[xk]st?:?\\s*",
            "^Sure[,!]?\\s*(here'?s?)?\\s*",
            "^Of course[,!]?\\s*",
            "^Certainly[,!]?\\s*"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// App-level error type retained for backwards compatibility with v4.x call
/// sites. New code should throw `GeminiRESTError` directly.
enum JarvisError: LocalizedError {
    case noAPIKey
    case emptyResponse
    case audioCaptureFailed
    case audioFormatInvalid
    case accessibilityDenied
    case screenCaptureDenied
    case networkError(underlying: Error)
    case permissionDenied(permission: String, instructions: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Gemini API key found. Please add it in Settings."
        case .emptyResponse: return "Gemini returned an empty response."
        case .audioCaptureFailed: return "Failed to capture audio from microphone."
        case .audioFormatInvalid: return "Audio input format is invalid (sample rate is 0)."
        case .accessibilityDenied: return "Accessibility permission is required for text insertion."
        case .screenCaptureDenied: return "Screen Recording permission is required for Vision mode."
        case .networkError(let underlying): return "Network error: \(underlying.localizedDescription)"
        case .permissionDenied(let permission, _): return "\(permission) permission is required."
        }
    }
}
