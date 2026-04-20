import Foundation

// MARK: - Generic message / tool types

/// Which upstream AI a mode talks to. Persisted on `Mode` (default `.gemini`).
enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case gemini
    case anthropic
    case ollama
    /// Phase 3d: let the `ProviderRouter` pick at call time based on
    /// RoutingPolicy (battery, modality, task complexity, user history).
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .anthropic: return "Anthropic Claude"
        case .ollama: return "Ollama (lokal)"
        case .auto: return "Auto (local-first)"
        }
    }

    /// Whether the provider runs locally. Used by routing policy + Settings UI
    /// to distinguish privacy/cost tiers.
    var isLocal: Bool {
        switch self {
        case .gemini, .anthropic: return false
        case .ollama: return true
        case .auto: return false  // router decides per call
        }
    }
}

/// Provider-neutral message role.
enum AIRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// A single content part — text, image, or a structured tool call/result.
enum AIContentPart: Sendable {
    case text(String)
    case image(data: Data, mime: String)
    case audio(data: Data, mime: String)
    /// Model asked to run a tool. Carries name + input JSON + an id so the
    /// subsequent `.toolResult` can reference it.
    case toolUse(id: String, name: String, input: [String: Any])
    /// Result of running a tool, threaded back to the model in the next turn.
    case toolResult(id: String, content: String, isError: Bool)
}

struct AIMessage: Sendable {
    let role: AIRole
    let parts: [AIContentPart]

    init(role: AIRole, parts: [AIContentPart]) {
        self.role = role
        self.parts = parts
    }

    static func user(_ text: String) -> AIMessage {
        AIMessage(role: .user, parts: [.text(text)])
    }
    static func assistant(_ text: String) -> AIMessage {
        AIMessage(role: .assistant, parts: [.text(text)])
    }
    static func system(_ text: String) -> AIMessage {
        AIMessage(role: .system, parts: [.text(text)])
    }
}

/// Tool exposed to the model. Each provider serialises it into its own wire
/// format (Gemini expects `functionDeclarations`, Anthropic expects `tools[]`
/// with `input_schema`).
struct AITool: Sendable {
    let name: String
    let description: String
    /// JSON Schema object — `{ "type": "object", "properties": {...}, "required": [...] }`
    let inputSchema: [String: Any]

    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Options per request. Most defaults are sane.
struct AIRequestOptions: Sendable {
    var systemPrompt: String?
    var maxTokens: Int = 2048
    var temperature: Double? = nil
    var tools: [AITool] = []
    /// If true, the provider should enable its built-in web-search tool (Gemini's
    /// `googleSearch`, Anthropic's web search tool on 2025-06-01 beta header).
    var webSearch: Bool = false

    init(systemPrompt: String? = nil, maxTokens: Int = 2048) {
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }
}

/// A chunk emitted by `stream(...)`. Text deltas, tool calls, or usage arrive separately.
enum AIStreamChunk: Sendable {
    case textDelta(String)
    case toolCall(id: String, name: String, input: [String: Any])
    case usage(inputTokens: Int, outputTokens: Int)
    case groundingSources([String])
    case done
}

/// Final result of a non-streaming send.
struct AIResponse: Sendable {
    let text: String
    let toolCalls: [(id: String, name: String, input: [String: Any])]
    let inputTokens: Int
    let outputTokens: Int
    let groundingSources: [String]
}

// MARK: - Provider protocol

/// Shared surface for every upstream AI. Gemini + Anthropic implementations
/// live in sibling files; future Ollama/OpenAI would slot in the same way.
///
/// All methods are `async throws`. Each provider is responsible for mapping its
/// transport errors into domain-specific `LocalizedError`s that `ErrorPresenter`
/// can surface.
protocol AIProvider: Sendable {
    /// Which model identifier the provider uses (e.g. "gemini-2.5-flash",
    /// "claude-sonnet-4-6"). Mode supplies this.
    func send(model: String, messages: [AIMessage], options: AIRequestOptions) async throws -> AIResponse

    /// Streaming variant. Caller consumes chunks until `.done` or an error.
    func stream(model: String, messages: [AIMessage], options: AIRequestOptions) -> AsyncThrowingStream<AIStreamChunk, Error>
}
