import Foundation

/// A single capability Jarvis can expose to the LLM. Each tool owns its JSON
/// schema, its audit-log summary, and its execution logic. Destructive tools
/// also declare `requiresConfirmation = true` so the chat layer can prompt
/// before running (landed in β2).
struct AgentTool: @unchecked Sendable {
    /// Machine-id used in Anthropic's `tool_use` messages. Snake_case.
    let name: String
    /// Human description fed to the LLM so it knows when to reach for the tool.
    let description: String
    /// JSON Schema object — `{"type": "object", "properties": {…}, "required": […]}`.
    let inputSchema: [String: Any]
    /// If true, the UI must get an explicit user approval before the tool runs.
    let requiresConfirmation: Bool
    /// Execution closure. Returns a plain-text result that's threaded back to
    /// the model as a `tool_result` message.
    let execute: @MainActor @Sendable (_ input: [String: Any], _ context: AgentContext) async throws -> String
}

/// Global registry of tools available to the agent. Tools register themselves
/// via static factory methods on their own types; `AgentToolRegistry` just
/// collects them into a lookup table keyed on tool name.
@MainActor
final class AgentToolRegistry {
    static let shared = AgentToolRegistry()

    private var tools: [String: AgentTool] = [:]

    private init() {
        // Read-only tools shipped in β1. Write tools follow in β2 behind
        // confirmation UI.
        register(ReadFileTool.tool)
        register(ListDirectoryTool.tool)
        register(SearchFilesTool.tool)
        register(StatFileTool.tool)
    }

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func tool(named name: String) -> AgentTool? {
        tools[name]
    }

    /// All tools as the Anthropic `tools[]` array — `[{name, description, input_schema}]`.
    func anthropicToolsJSON() -> [[String: Any]] {
        tools.values.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema
            ]
        }
    }
}
