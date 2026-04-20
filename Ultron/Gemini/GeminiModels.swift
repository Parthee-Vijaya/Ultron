import Foundation

// Typed request/response models for the Gemini v1beta REST API.
// Matches https://ai.google.dev/api/generate-content with camelCase keys.

struct GeminiPart: Codable {
    var text: String?
    var inlineData: InlineData?

    struct InlineData: Codable {
        let mimeType: String
        let data: String  // base64
    }

    static func text(_ s: String) -> GeminiPart {
        GeminiPart(text: s, inlineData: nil)
    }
    static func data(mime: String, _ bytes: Data) -> GeminiPart {
        GeminiPart(text: nil, inlineData: InlineData(mimeType: mime, data: bytes.base64EncodedString()))
    }
}

struct GeminiContent: Codable {
    let role: String      // "user" | "model" | "system"
    let parts: [GeminiPart]

    init(role: String, parts: [GeminiPart]) {
        self.role = role
        self.parts = parts
    }

    // Custom decoder so a response shaped `{"role":"model","content":{}}` or
    // one where safety-filtering stripped `parts` doesn't crash the whole
    // pipeline. Missing role/parts decode as empty strings/arrays and the
    // `text` accessor below treats empty content as a soft empty-response
    // the caller can surface sensibly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        parts = (try? c.decode([GeminiPart].self, forKey: .parts)) ?? []
    }
}

/// Gemini's tool surface. Each field is its own sub-object by design; we set
/// exactly one per tool entry.
struct GeminiTool: Codable {
    var googleSearch: EmptyObject?
    var codeExecution: EmptyObject?

    struct EmptyObject: Codable {}

    static let googleSearch = GeminiTool(googleSearch: EmptyObject(), codeExecution: nil)
    static let codeExecution = GeminiTool(googleSearch: nil, codeExecution: EmptyObject())
}

struct GeminiGenerationConfig: Codable {
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
}

struct GeminiRequest: Codable {
    var systemInstruction: GeminiContent?
    var contents: [GeminiContent]
    var tools: [GeminiTool]?
    var generationConfig: GeminiGenerationConfig?
}

struct GeminiResponse: Codable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
    let promptFeedback: PromptFeedback?

    struct Candidate: Codable {
        let content: GeminiContent?
        let finishReason: String?
        let index: Int?
        let groundingMetadata: GroundingMetadata?
    }

    struct UsageMetadata: Codable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
    }

    struct PromptFeedback: Codable {
        let blockReason: String?
    }

    struct GroundingMetadata: Codable {
        let groundingChunks: [Chunk]?
        let webSearchQueries: [String]?

        struct Chunk: Codable {
            let web: Web?
            struct Web: Codable {
                let uri: String?
                let title: String?
            }
        }
    }

    /// Convenience: concatenate all text parts from the first candidate.
    var text: String? {
        guard let parts = candidates?.first?.content?.parts else { return nil }
        let joined = parts.compactMap { $0.text }.joined()
        return joined.isEmpty ? nil : joined
    }

    /// Convenience: pull out grounding source titles/domains (up to 5).
    var groundingSources: [String] {
        guard let chunks = candidates?.first?.groundingMetadata?.groundingChunks else { return [] }
        return chunks.compactMap { chunk -> String? in
            if let title = chunk.web?.title { return title }
            if let uri = chunk.web?.uri, let host = URL(string: uri)?.host { return host }
            return nil
        }
    }
}

/// One chunk from a streaming generation. Produced by `GeminiREST.stream(...)`.
struct GeminiStreamChunk {
    let text: String?
    let usage: GeminiResponse.UsageMetadata?
    let groundingSources: [String]
}

/// Errors thrown by the REST client. Surfaced through `ErrorPresenter` later.
enum GeminiRESTError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case emptyResponse
    case decodingFailed(underlying: Error)
    case blocked(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Ingen Gemini API-nøgle fundet. Tilføj den i Settings."
        case .invalidURL:
            return "Intern fejl: ugyldig URL."
        case .httpError(let code, _):
            return "Gemini returnerede HTTP \(code)."
        case .emptyResponse:
            return "Gemini returnerede et tomt svar."
        case .decodingFailed:
            return "Kunne ikke læse svar fra Gemini."
        case .blocked(let reason):
            return "Gemini blokerede svaret: \(reason)"
        }
    }
}
