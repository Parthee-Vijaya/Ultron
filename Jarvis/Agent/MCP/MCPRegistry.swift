import Foundation

/// Reads `~/.jarvis/mcp.json`, spawns each configured MCP server, and adapts
/// its `tools/list` entries into `AgentTool` instances registered with
/// `AgentToolRegistry.shared`. Non-fatal: individual server failures are
/// logged and skipped so one broken server doesn't block the others.
@MainActor
final class MCPRegistry {
    static let shared = MCPRegistry()

    private var clients: [String: MCPClient] = [:]

    private init() {}

    /// Entry point called from `AppDelegate.applicationDidFinishLaunching`.
    /// Reads config, spawns servers, registers tools. Idempotent — safe to
    /// call multiple times (re-registers tools but leaves running servers).
    func bootstrap() async {
        let config: MCPConfig
        do {
            config = try Self.loadConfig()
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            // No config = no MCP servers. Not an error.
            return
        } catch {
            LoggingService.shared.log("Failed to read mcp.json: \(error)", level: .warning)
            return
        }

        for (name, server) in config.servers {
            await startServer(name: name, server: server)
        }
    }

    /// Stop every running server — wired to AppDelegate's applicationWillTerminate.
    func shutdown() {
        for client in clients.values { client.shutdown() }
        clients.removeAll()
    }

    // MARK: - Per-server startup

    private func startServer(name: String, server: MCPConfig.Server) async {
        do {
            let client = try MCPClient(
                name: name,
                command: server.command,
                args: server.args ?? [],
                env: server.env ?? [:]
            )
            clients[name] = client

            let tools = try await client.initializeAndListTools()
            for tool in tools {
                let adapter = Self.adapter(serverName: name, tool: tool, client: client)
                AgentToolRegistry.shared.register(adapter)
            }
            LoggingService.shared.log("MCP server '\(name)' → \(tools.count) tools registered")
        } catch {
            LoggingService.shared.log("MCP server '\(name)' failed: \(error.localizedDescription)", level: .warning)
        }
    }

    // MARK: - AgentTool adapter

    private static func adapter(serverName: String, tool: MCPTool, client: MCPClient) -> AgentTool {
        // MCP tool names get namespaced with the server name so two servers
        // with a `read` tool don't collide in the registry.
        let qualifiedName = "\(serverName)__\(tool.name)"
        return AgentTool(
            name: qualifiedName,
            description: "[MCP · \(serverName)] \(tool.description)",
            inputSchema: tool.inputSchema.isEmpty
                ? ["type": "object", "properties": [:] as [String: Any]]
                : tool.inputSchema,
            requiresConfirmation: true,  // all MCP tools gated; they're external code
            execute: { input, _ in
                do {
                    return try await client.callTool(name: tool.name, arguments: input)
                } catch {
                    throw AgentError.toolFailed(name: qualifiedName, underlying: error.localizedDescription)
                }
            }
        )
    }

    // MARK: - Config loader

    struct MCPConfig: Decodable {
        let servers: [String: Server]

        struct Server: Decodable {
            let command: String
            let args: [String]?
            let env: [String: String]?
        }
    }

    private static func loadConfig() throws -> MCPConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis/mcp.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MCPConfig.self, from: data)
    }
}
