import Foundation

enum GeminiModel: String, Codable, CaseIterable {
    case flash = "gemini-2.5-flash"
    case pro = "gemini-2.5-pro"

    var displayName: String {
        switch self {
        case .flash: return "Gemini 2.5 Flash"
        case .pro: return "Gemini 2.5 Pro"
        }
    }
}

enum OutputType: String, Codable, CaseIterable {
    case paste
    case hud
    case chat

    var displayName: String {
        switch self {
        case .paste: return "Paste at cursor"
        case .hud: return "Show in HUD"
        case .chat: return "Chat window"
        }
    }
}

/// What kind of input the mode takes when launched from the chat command bar.
/// The command bar's send button adapts its behaviour per `InputKind`.
enum InputKind: String, Codable, CaseIterable {
    /// Plain text from the command bar's TextField.
    case text
    /// Mic capture — selecting the mode auto-starts recording; enter stops.
    case voice
    /// Trigger `ScreenCaptureService.captureActiveWindow()` + optional text prompt.
    case screenshot
    /// Open an `NSOpenPanel` for the user to pick a document.
    case document
}

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var model: GeminiModel
    var outputType: OutputType
    var maxTokens: Int
    var isBuiltIn: Bool
    /// If true, Gemini runs the `google_search` grounding tool when answering.
    /// Only honoured on non-paste output types (Q&A, Vision, Chat) — dictation-style
    /// rewrite modes are better left un-grounded.
    var webSearch: Bool
    /// Which upstream provider this mode talks to. Defaults to Gemini; agent
    /// modes use Anthropic. Added in v5.0.0-beta.1 — older JSON decodes as
    /// `.gemini`.
    var provider: AIProviderType
    /// If true, the mode routes through `AgentService` with the file-op tool
    /// registry enabled. Only honoured on Anthropic-provider modes.
    var agentTools: Bool
    /// SF Symbol name shown next to the mode in the chat command bar's mode
    /// picker. Added in v5.0.0-beta.11 — older JSON decodes to a default
    /// derived from `outputType`.
    var icon: String
    /// How the chat command bar should collect input for this mode when it's
    /// launched from there (direct hotkey invocations bypass this and keep
    /// their legacy paste/HUD flow). Added in v5.0.0-beta.11 — older JSON
    /// decodes as `.text`.
    var inputKind: InputKind

    init(
        id: UUID,
        name: String,
        systemPrompt: String,
        model: GeminiModel,
        outputType: OutputType,
        maxTokens: Int,
        isBuiltIn: Bool,
        webSearch: Bool = false,
        provider: AIProviderType = .gemini,
        agentTools: Bool = false,
        icon: String = "sparkles",
        inputKind: InputKind = .text
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.model = model
        self.outputType = outputType
        self.maxTokens = maxTokens
        self.isBuiltIn = isBuiltIn
        self.webSearch = webSearch
        self.provider = provider
        self.agentTools = agentTools
        self.icon = icon
        self.inputKind = inputKind
    }

    // Custom Codable so older JSON files (v3.0 custom modes without `webSearch`) decode cleanly.
    private enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, model, outputType, maxTokens, isBuiltIn, webSearch, provider, agentTools, icon, inputKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        model = try c.decode(GeminiModel.self, forKey: .model)
        outputType = try c.decode(OutputType.self, forKey: .outputType)
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? false
        provider = try c.decodeIfPresent(AIProviderType.self, forKey: .provider) ?? .gemini
        agentTools = try c.decodeIfPresent(Bool.self, forKey: .agentTools) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        inputKind = try c.decodeIfPresent(InputKind.self, forKey: .inputKind) ?? .text
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(model, forKey: .model)
        try c.encode(outputType, forKey: .outputType)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(webSearch, forKey: .webSearch)
        try c.encode(provider, forKey: .provider)
        try c.encode(agentTools, forKey: .agentTools)
        try c.encode(icon, forKey: .icon)
        try c.encode(inputKind, forKey: .inputKind)
    }

    static func == (lhs: Mode, rhs: Mode) -> Bool {
        lhs.id == rhs.id
    }
}
