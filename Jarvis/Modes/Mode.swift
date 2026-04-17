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

    var displayName: String {
        switch self {
        case .paste: return "Paste at cursor"
        case .hud: return "Show in HUD"
        }
    }
}

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var model: GeminiModel
    var outputType: OutputType
    var maxTokens: Int
    var isBuiltIn: Bool

    static func == (lhs: Mode, rhs: Mode) -> Bool {
        lhs.id == rhs.id
    }
}
