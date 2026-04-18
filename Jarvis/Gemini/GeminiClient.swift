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

    /// Text + image in one turn — used by the β.11 chat command bar's Vision
    /// mode. Routes through the search-grounded path when the mode asks for it,
    /// so the model still has to cite sources for any claim not visible on
    /// screen.
    func sendTextWithImage(prompt: String, mode: Mode, imageData: Data) async -> Result<String, Error> {
        if mode.webSearch {
            return await withRetry { [weak self] in
                guard let self else { throw GeminiRESTError.missingAPIKey }
                return try await self.sendTextWithSearch(prompt: prompt, imageData: imageData, mode: mode)
            }
        }
        return await withRetry { [weak self] in
            guard let self else { throw GeminiRESTError.missingAPIKey }
            return try await self.generateOnce(
                parts: [.text(prompt), .data(mime: "image/png", imageData)],
                mode: mode
            )
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
        // Always gather fresh sources FIRST. The strict system prompt tells the
        // model "answer only from these sources"; we keep googleSearch enabled
        // as a second-layer safety net for queries our fixed sources miss.
        let searchResults = await WebSearchService.shared.search(query: prompt, limit: 5)

        let today = Self.todayDateString()
        let augmentedPrompt: String
        if searchResults.isEmpty {
            // No external sources found. The model's system prompt knows to say
            // "Jeg kan ikke finde et klart svar …" in this case.
            augmentedPrompt = """
            Dato: \(today)
            INGEN web-søgeresultater tilgængelige.

            Spørgsmål: \(prompt)
            """
            LoggingService.shared.log("WebSearch: 0 pre-fetch results — model will refuse without grounding", level: .warning)
        } else {
            let numbered = searchResults.enumerated()
                .map { (index, result) in result.promptBlock(index: index + 1) }
                .joined(separator: "\n\n")
            augmentedPrompt = """
            Dato: \(today)
            Verificerbare kilder (brug KUN disse til faktuelle udsagn):

            \(numbered)

            Spørgsmål: \(prompt)

            Svar i det påkrævede format med [n]-henvisninger og en **Kilder**-sektion.
            """
            LoggingService.shared.log("WebSearch: \(searchResults.count) pre-fetch results numbered for model")
        }

        var parts: [GeminiPart] = [.text(augmentedPrompt)]
        if let imageData { parts.append(.data(mime: "image/png", imageData)) }

        let request = GeminiRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.text(mode.systemPrompt)]),
            contents: [GeminiContent(role: "user", parts: parts)],
            tools: [.googleSearch],
            generationConfig: GeminiGenerationConfig(maxOutputTokens: mode.maxTokens)
        )

        LoggingService.shared.log("Gemini POST: model=\(modelName(for: mode)), chars=\(augmentedPrompt.count), preSources=\(searchResults.count), image=\(imageData != nil)")
        let response = try await rest.generate(model: modelName(for: mode), request: request, mode: mode)
        guard let text = response.text else { throw GeminiRESTError.emptyResponse }

        // Combine pre-fetched sources with anything Gemini's googleSearch tool
        // produced, deduplicated. This gives the Kilder section full coverage.
        let geminiSources = Self.sourcesFromGrounding(response: response)
        let combinedSources = Self.dedupSources(searchResults + geminiSources)
        if !response.groundingSources.isEmpty {
            LoggingService.shared.log("Gemini grounded on: \(response.groundingSources.prefix(5).joined(separator: ", "))")
        }

        let finalText = Self.ensureSourcesFooter(rawAnswer: postProcess(text), sources: combinedSources)
        return finalText
    }

    // MARK: - Source-footer helpers

    /// Extract extra sources from Gemini's groundingMetadata chunks (when the
    /// model actually used googleSearch). Maps each `web` chunk to a SearchResult.
    private static func sourcesFromGrounding(response: GeminiResponse) -> [SearchResult] {
        guard let chunks = response.candidates?.first?.groundingMetadata?.groundingChunks else {
            return []
        }
        return chunks.compactMap { chunk -> SearchResult? in
            guard let web = chunk.web else { return nil }
            let title = web.title ?? (URL(string: web.uri ?? "")?.host ?? "Kilde")
            return SearchResult(title: title, snippet: "", url: web.uri ?? "")
        }
    }

    /// Dedup by URL host+path, preserving order.
    private static func dedupSources(_ items: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        var output: [SearchResult] = []
        for item in items where !item.url.isEmpty {
            let key = URL(string: item.url)?.absoluteString ?? item.url
            if seen.insert(key).inserted {
                output.append(item)
            }
        }
        return output
    }

    /// Guarantees the answer ends with a **Kilder** section containing every
    /// source we have, deduped. Strips any footer the model produced first so
    /// we don't end up with two sections after merging grounding metadata.
    ///
    /// α.12 simplified this: the α.10 version used a regex with `.anchored` +
    /// alternation, which Foundation's NSRegularExpression only honours on the
    /// first alternation branch. We now scan for a small set of literal header
    /// markers and keep everything before the earliest match.
    private static func ensureSourcesFooter(rawAnswer: String, sources: [SearchResult]) -> String {
        guard !sources.isEmpty else { return rawAnswer }

        let markers = ["\n**Kilder**", "\n## Kilder", "\n### Kilder", "\nKilder:", "\n**Sources**", "\nSources:"]
        var earliest: String.Index? = nil
        for marker in markers {
            if let range = rawAnswer.range(of: marker, options: .literal) {
                if earliest == nil || range.lowerBound < earliest! {
                    earliest = range.lowerBound
                }
            }
        }
        let beforeFooter = earliest.map { String(rawAnswer[..<$0]) } ?? rawAnswer
        let stripped = beforeFooter.trimmingCharacters(in: .whitespacesAndNewlines)

        let footer = sources.enumerated()
            .map { (index, src) in "\(index + 1). [\(src.title)](\(src.url))" }
            .joined(separator: "\n")

        return "\(stripped)\n\n**Kilder**\n\(footer)"
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
