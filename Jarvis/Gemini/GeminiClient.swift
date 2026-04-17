import Foundation
import GoogleGenerativeAI

class GeminiClient {
    private let keychainService: KeychainService
    private let usageTracker: UsageTracker

    init(keychainService: KeychainService, usageTracker: UsageTracker) {
        self.keychainService = keychainService
        self.usageTracker = usageTracker
    }

    private func makeModel(modelName: String, systemPrompt: String) -> GenerativeModel? {
        guard let apiKey = keychainService.getAPIKey() else {
            LoggingService.shared.log("No API key found in Keychain", level: .error)
            return nil
        }

        return GenerativeModel(
            name: modelName,
            apiKey: apiKey,
            generationConfig: GenerationConfig(maxOutputTokens: 4096),
            systemInstruction: ModelContent(role: "system", parts: [.text(systemPrompt)])
        )
    }

    func testConnection() async -> Result<String, Error> {
        guard let model = makeModel(
            modelName: "gemini-2.5-flash",
            systemPrompt: "You are a test assistant."
        ) else {
            return .failure(JarvisError.noAPIKey)
        }

        do {
            let response = try await model.generateContent("Say 'Connection successful' in exactly those words.")
            if let text = response.text {
                LoggingService.shared.log("Gemini connection test: OK")
                return .success(text)
            }
            return .failure(JarvisError.emptyResponse)
        } catch {
            LoggingService.shared.log("Gemini connection test failed: \(error)", level: .error)
            return .failure(error)
        }
    }

    func sendAudio(_ audioData: Data, mode: Mode) async -> Result<String, Error> {
        let modelName = mode.model == .pro ? "gemini-2.5-pro" : "gemini-2.5-flash"

        guard let model = makeModel(modelName: modelName, systemPrompt: mode.systemPrompt) else {
            return .failure(JarvisError.noAPIKey)
        }

        do {
            let audioPart = ModelContent.Part.data(mimetype: "audio/wav", audioData)
            let response = try await model.generateContent([audioPart])

            if let usage = response.usageMetadata {
                usageTracker.trackUsage(
                    model: mode.model,
                    inputTokens: usage.promptTokenCount ?? 0,
                    outputTokens: usage.candidatesTokenCount ?? 0
                )
            }

            if let text = response.text {
                let cleaned = postProcess(text)
                LoggingService.shared.log("Gemini response received (\(cleaned.count) chars)")
                return .success(cleaned)
            }
            return .failure(JarvisError.emptyResponse)
        } catch {
            LoggingService.shared.log("Gemini API error: \(error)", level: .error)
            return .failure(error)
        }
    }

    func sendAudioWithImage(_ audioData: Data, imageData: Data, mode: Mode) async -> Result<String, Error> {
        let modelName = mode.model == .pro ? "gemini-2.5-pro" : "gemini-2.5-flash"

        guard let model = makeModel(modelName: modelName, systemPrompt: mode.systemPrompt) else {
            return .failure(JarvisError.noAPIKey)
        }

        do {
            let audioPart = ModelContent.Part.data(mimetype: "audio/wav", audioData)
            let imagePart = ModelContent.Part.data(mimetype: "image/png", imageData)
            let response = try await model.generateContent([audioPart, imagePart])

            if let usage = response.usageMetadata {
                usageTracker.trackUsage(
                    model: mode.model,
                    inputTokens: usage.promptTokenCount ?? 0,
                    outputTokens: usage.candidatesTokenCount ?? 0
                )
            }

            if let text = response.text {
                let cleaned = postProcess(text)
                return .success(cleaned)
            }
            return .failure(JarvisError.emptyResponse)
        } catch {
            LoggingService.shared.log("Gemini vision API error: \(error)", level: .error)
            return .failure(error)
        }
    }

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

enum JarvisError: LocalizedError {
    case noAPIKey
    case emptyResponse
    case audioCaptureFailed
    case accessibilityDenied
    case screenCaptureDenied

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Gemini API key found. Please add it in Settings."
        case .emptyResponse: return "Gemini returned an empty response."
        case .audioCaptureFailed: return "Failed to capture audio from microphone."
        case .accessibilityDenied: return "Accessibility permission is required for text insertion."
        case .screenCaptureDenied: return "Screen Recording permission is required for Vision mode."
        }
    }
}
