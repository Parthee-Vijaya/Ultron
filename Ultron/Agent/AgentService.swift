import Foundation

/// Orchestrates an agent query end-to-end:
///   user prompt → Anthropic → optional tool_use → execute via registry →
///   tool_result → Anthropic → … → final text
///
/// Runs up to `maxIterations` rounds (20) to bound runaway loops. Every tool
/// call is stamped into `AgentAuditLog` with input + output summaries so the
/// user can review what Ultron did after the fact.
/// A pending tool call awaiting user approval. Emitted by AgentService when
/// a `requiresConfirmation=true` tool is about to run.
struct PendingToolCall: Sendable, Equatable {
    let id: String
    let toolName: String
    let humanSummary: String
    let arguments: [(key: String, value: String)]

    static func == (lhs: PendingToolCall, rhs: PendingToolCall) -> Bool {
        lhs.id == rhs.id && lhs.toolName == rhs.toolName
    }
}

@MainActor
final class AgentService {
    private let provider: AnthropicProvider
    private let registry: AgentToolRegistry
    private let auditLog = AgentAuditLog()
    private let maxIterations = 20

    /// Closure the owning pipeline sets to render a confirmation card in chat
    /// and resume with the user's decision. Returns true = proceed, false = reject.
    /// If unset, destructive tools are auto-rejected for safety.
    var confirmationProvider: (@MainActor (PendingToolCall) async -> Bool)?

    /// Default system prompt — narrow scope, demand citation of file paths when
    /// the agent draws conclusions from file contents.
    static let defaultSystemPrompt = """
    You are J.A.R.V.I.S acting as a file-system agent on the user's macOS machine.

    You have access to a small set of READ-ONLY tools to inspect files and
    directories inside a user-approved workspace. You cannot yet modify, delete
    or rename anything — attempts to do so will fail.

    Guidelines:
    - Use tools liberally to gather evidence before answering.
    - When you quote, summarise, or draw conclusions from file contents, cite the
      exact path you read from.
    - If a path lies outside the allowed workspace, tell the user and suggest
      they widen it in Settings → Agent.
    - Keep explanations concise. Reply in the user's language (Danish or English).

    Workspace roots (every file path must live under one of these):
    {ALLOWED_ROOTS}
    """

    struct AgentResult: Sendable {
        let finalAnswer: String
        let toolInvocations: [ToolInvocation]
        let conversationID: UUID
    }

    struct ToolInvocation: Sendable {
        let name: String
        let inputSummary: String
        let resultSummary: String
        let success: Bool
        let durationMs: Int
    }

    init(provider: AnthropicProvider, registry: AgentToolRegistry = .shared) {
        self.provider = provider
        self.registry = registry
    }

    /// Run a single user prompt through the agent loop.
    ///
    /// - Parameters:
    ///   - prompt: Free-form request from the user.
    ///   - model: Claude model id ("claude-sonnet-4-6" by default).
    ///   - allowedRoots: Workspace boundary.
    func run(prompt: String,
             model: String = "claude-sonnet-4-6",
             allowedRoots: [URL]? = nil) async throws -> AgentResult {

        let roots = allowedRoots ?? AgentContext.defaultAllowedRoots()
        let context = AgentContext(allowedRoots: roots, audit: auditLog)
        auditLog.recordConversationStart(conversation: context.conversationID, userPrompt: prompt)

        let systemPrompt = Self.defaultSystemPrompt.replacingOccurrences(
            of: "{ALLOWED_ROOTS}",
            with: roots.map { "- \($0.path)" }.joined(separator: "\n")
        )

        var messages: [AIMessage] = [.user(prompt)]
        var tools: [AITool] = []
        for toolJSON in registry.anthropicToolsJSON() {
            guard let name = toolJSON["name"] as? String,
                  let description = toolJSON["description"] as? String,
                  let schema = toolJSON["input_schema"] as? [String: Any] else { continue }
            tools.append(AITool(name: name, description: description, inputSchema: schema))
        }
        var requestOptions = AIRequestOptions(systemPrompt: systemPrompt, maxTokens: 4096)
        requestOptions.temperature = 0.2
        requestOptions.tools = tools

        var invocations: [ToolInvocation] = []

        for iteration in 1...maxIterations {
            LoggingService.shared.log("Agent loop iter=\(iteration), messages=\(messages.count)")
            let response = try await provider.send(model: model, messages: messages, options: requestOptions)

            // If the model produced no tool calls, this is the final answer.
            if response.toolCalls.isEmpty {
                auditLog.recordConversationEnd(
                    conversation: context.conversationID,
                    finalResponse: response.text,
                    toolCount: invocations.count
                )
                return AgentResult(
                    finalAnswer: response.text,
                    toolInvocations: invocations,
                    conversationID: context.conversationID
                )
            }

            // Echo assistant's tool_use turn back into the transcript.
            var assistantParts: [AIContentPart] = []
            if !response.text.isEmpty {
                assistantParts.append(.text(response.text))
            }
            for call in response.toolCalls {
                assistantParts.append(.toolUse(id: call.id, name: call.name, input: call.input))
            }
            messages.append(AIMessage(role: .assistant, parts: assistantParts))

            // Execute each tool and collect tool_result parts.
            var resultParts: [AIContentPart] = []
            for call in response.toolCalls {
                let invocation = await runTool(call: call, context: context)
                invocations.append(invocation)
                resultParts.append(.toolResult(
                    id: call.id,
                    content: invocation.resultSummary,
                    isError: !invocation.success
                ))
            }
            messages.append(AIMessage(role: .user, parts: resultParts))
        }

        auditLog.recordConversationEnd(
            conversation: context.conversationID,
            finalResponse: "[iteration limit]",
            toolCount: invocations.count
        )
        throw AgentError.iterationLimitReached(max: maxIterations)
    }

    // MARK: - Tool execution

    private func runTool(call: (id: String, name: String, input: [String: Any]),
                         context: AgentContext) async -> ToolInvocation {
        let start = Date()
        let inputSummary = Self.summariseInput(call.input)
        auditLog.recordToolCall(conversation: context.conversationID, tool: call.name, inputSummary: inputSummary)

        guard let tool = registry.tool(named: call.name) else {
            let msg = "Unknown tool '\(call.name)'"
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            auditLog.recordToolResult(conversation: context.conversationID, tool: call.name, success: false, resultSummary: msg, durationMs: durationMs)
            return ToolInvocation(name: call.name, inputSummary: inputSummary, resultSummary: msg, success: false, durationMs: durationMs)
        }

        // Destructive-tool confirmation gate. If no provider is wired, refuse
        // — better to fail than silently perform a destructive op.
        if tool.requiresConfirmation {
            let pending = PendingToolCall(
                id: call.id,
                toolName: call.name,
                humanSummary: Self.humanSummary(for: call.name, input: call.input),
                arguments: Self.argumentPairs(call.input)
            )
            let approved = await confirmationProvider?(pending) ?? false
            if !approved {
                let msg = "User rejected confirmation for \(call.name)"
                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                auditLog.recordToolResult(conversation: context.conversationID, tool: call.name, success: false, resultSummary: msg, durationMs: durationMs)
                return ToolInvocation(name: call.name, inputSummary: inputSummary, resultSummary: msg, success: false, durationMs: durationMs)
            }
        }

        do {
            let result = try await tool.execute(call.input, context)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let summary = result.count > 200 ? String(result.prefix(200)) + "… [truncated]" : result
            auditLog.recordToolResult(conversation: context.conversationID, tool: call.name, success: true, resultSummary: summary, durationMs: durationMs)
            return ToolInvocation(name: call.name, inputSummary: inputSummary, resultSummary: result, success: true, durationMs: durationMs)
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let message = error.localizedDescription
            auditLog.recordToolResult(conversation: context.conversationID, tool: call.name, success: false, resultSummary: message, durationMs: durationMs)
            return ToolInvocation(name: call.name, inputSummary: inputSummary, resultSummary: message, success: false, durationMs: durationMs)
        }
    }

    /// One-line Danish summary shown on the confirmation card.
    private static func humanSummary(for toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "write_file":
            let path = (input["path"] as? String) ?? "?"
            return "Skriv til \(path)"
        case "rename_file":
            let src = (input["source"] as? String) ?? "?"
            let dst = (input["destination"] as? String) ?? "?"
            return "Flyt \(src) → \(dst)"
        case "delete_file":
            let path = (input["path"] as? String) ?? "?"
            return "Flyt \(path) til papirkurven"
        case "create_directory":
            let path = (input["path"] as? String) ?? "?"
            return "Opret mappe \(path)"
        default:
            return "Kør værktøj \(toolName)"
        }
    }

    private static func argumentPairs(_ input: [String: Any]) -> [(key: String, value: String)] {
        input.map { (key, value) in
            let valueStr: String
            if let str = value as? String {
                valueStr = str.count > 120 ? String(str.prefix(120)) + "…" : str
            } else {
                valueStr = "\(value)"
            }
            return (key, valueStr)
        }.sorted { $0.key < $1.key }
    }

    private static func summariseInput(_ input: [String: Any]) -> String {
        // Keep it short — full JSON dump is overkill in logs. Show 2 key=value pairs max.
        let pairs = input.prefix(3).map { (key, value) -> String in
            let valueStr: String
            if let str = value as? String, str.count > 60 {
                valueStr = "\"\(str.prefix(60))…\""
            } else if let str = value as? String {
                valueStr = "\"\(str)\""
            } else {
                valueStr = "\(value)"
            }
            return "\(key)=\(valueStr)"
        }
        return pairs.joined(separator: ", ")
    }
}
