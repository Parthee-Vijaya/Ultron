import Foundation

/// Reads `~/.jarvis/mcp.json`, spawns each configured MCP server, and adapts
/// its `tools/list` entries into `AgentTool` instances registered with
/// `AgentToolRegistry.shared`. Non-fatal: individual server failures are
/// logged and skipped so one broken server doesn't block the others.
@MainActor
final class MCPRegistry {
    static let shared = MCPRegistry()

    private var clients: [String: MCPClient] = [:]
    /// v1.4 Fase 4 slice: track each server's restart attempts so a
    /// consistently failing server doesn't go into an infinite respawn loop.
    /// Keyed by server name; reset on successful re-initialise.
    private var restartAttempts: [String: Int] = [:]
    private let maxRestartAttempts = 3
    private var serverConfigs: [String: MCPConfig.Server] = [:]

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

        serverConfigs = config.servers
        for (name, server) in config.servers {
            await startServer(name: name, server: server)
        }
    }

    /// v1.4 Fase 4 slice: restart a previously-running MCP server after it
    /// disappeared (process exit / stdio pipe broke). Call sites are in
    /// `MCPClient` — when it detects a dead process it asks the registry to
    /// respawn. We cap attempts per server so a server that refuses to start
    /// doesn't spin forever.
    func requestRestart(name: String) async {
        guard let server = serverConfigs[name] else { return }
        let attempts = restartAttempts[name, default: 0]
        guard attempts < maxRestartAttempts else {
            LoggingService.shared.log("MCP server '\(name)' exceeded \(maxRestartAttempts) restart attempts — giving up", level: .error)
            return
        }
        restartAttempts[name] = attempts + 1
        LoggingService.shared.log("MCP server '\(name)' restarting (attempt \(attempts + 1)/\(maxRestartAttempts))", level: .warning)
        clients[name]?.shutdown()
        clients.removeValue(forKey: name)
        // Exponential backoff — 1s, 2s, 4s. Prevents hammering a flaky
        // server while still recovering from transient crashes quickly.
        let delay = UInt64(pow(2.0, Double(attempts))) * 1_000_000_000
        try? await Task.sleep(nanoseconds: delay)
        await startServer(name: name, server: server)
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
            // Successful init — clear the restart counter so future crashes
            // get a fresh 3-attempt budget.
            restartAttempts.removeValue(forKey: name)
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
