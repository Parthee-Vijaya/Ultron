import Foundation
import Observation

/// Live status for a single MCP server. Surfaced via `MCPRegistryState` so the
/// Settings pane can render status chips without polling the registry itself.
@MainActor
struct MCPServerStatus: Identifiable, Equatable {
    enum ConnectionState: Equatable {
        case starting
        case running(toolCount: Int)
        case crashed(String)
        case stopped
    }

    let name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var state: ConnectionState
    var id: String { name }
}

/// Sidecar observable state for `MCPRegistry`. Kept as a separate class so the
/// registry itself can stay free of `@Observable` macro overhead while the UI
/// still gets diff-based updates when statuses change.
@MainActor
@Observable
final class MCPRegistryState {
    var servers: [MCPServerStatus] = []

    /// Upserts a status entry. Preserves list ordering on updates.
    func upsert(_ status: MCPServerStatus) {
        if let idx = servers.firstIndex(where: { $0.name == status.name }) {
            servers[idx] = status
        } else {
            servers.append(status)
        }
    }

    func remove(name: String) {
        servers.removeAll { $0.name == name }
    }

    func setState(name: String, to state: MCPServerStatus.ConnectionState) {
        guard let idx = servers.firstIndex(where: { $0.name == name }) else { return }
        servers[idx].state = state
    }
}

/// Reads `~/.ultron/mcp.json`, spawns each configured MCP server, and adapts
/// its `tools/list` entries into `AgentTool` instances registered with
/// `AgentToolRegistry.shared`. Non-fatal: individual server failures are
/// logged and skipped so one broken server doesn't block the others.
@MainActor
final class MCPRegistry {
    static let shared = MCPRegistry()

    /// Exposed for the Settings MCP pane. Mutated from `startServer`,
    /// `requestRestart`, `shutdown`, and the termination callback wired into
    /// each `MCPClient`.
    let state = MCPRegistryState()

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
    ///
    /// Config assembly order:
    /// 1. Built-in `ultron` sidecar entry from `BuiltInSidecar.builtInServer()`
    ///    — auto-registered so users don't have to hand-edit mcp.json.
    /// 2. User-configured servers from `~/.ultron/mcp.json` — wins on name
    ///    collision so the user can override (different uv, disable by
    ///    pointing at /usr/bin/true, etc.).
    func bootstrap() async {
        var servers: [String: MCPConfig.Server] = [:]

        if let builtIn = BuiltInSidecar.builtInServer() {
            servers["ultron"] = builtIn
            LoggingService.shared.log("MCP built-in sidecar auto-registered: \(builtIn.command)")
        } else {
            LoggingService.shared.log(
                "MCP built-in sidecar skipped: \(BuiltInSidecar.resolved.diagnostic)",
                level: .warning
            )
        }

        do {
            let userConfig = try Self.loadConfig()
            for (name, server) in userConfig.servers {
                servers[name] = server
            }
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            // No user config is normal on first launch.
        } catch {
            LoggingService.shared.log("Failed to read mcp.json: \(error)", level: .warning)
        }

        guard !servers.isEmpty else { return }

        serverConfigs = servers
        // Seed the observable state with a .starting entry for each server so
        // the UI shows a yellow chip immediately, before the async spawn even
        // begins.
        for (name, server) in servers {
            state.upsert(MCPServerStatus(
                name: name,
                command: server.command,
                args: server.args ?? [],
                env: server.env ?? [:],
                state: .starting
            ))
        }
        for (name, server) in servers {
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
            state.setState(name: name, to: .crashed("Gav op efter \(maxRestartAttempts) genstarter"))
            return
        }
        restartAttempts[name] = attempts + 1
        LoggingService.shared.log("MCP server '\(name)' restarting (attempt \(attempts + 1)/\(maxRestartAttempts))", level: .warning)
        state.setState(name: name, to: .starting)
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
        for status in state.servers {
            state.setState(name: status.name, to: .stopped)
        }
    }

    // MARK: - Save / reload (Settings MCP pane)

    /// Persist a fresh server map to `~/.ultron/mcp.json` (pretty-printed) and
    /// reload the registry. Creates the `.ultron` dir if it doesn't exist yet.
    func save(servers: [String: MCPConfig.Server]) async throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ultron", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("mcp.json")
        let config = MCPConfig(servers: servers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
        await reload()
    }

    /// Shut down every running server and re-bootstrap from disk. Used when
    /// the user taps "Genindlæs alle" in Settings, or internally by `save(...)`.
    func reload() async {
        shutdown()
        state.servers.removeAll()
        restartAttempts.removeAll()
        serverConfigs.removeAll()
        await bootstrap()
    }

    // MARK: - Per-server startup

    private func startServer(name: String, server: MCPConfig.Server) async {
        // Ensure there's a status entry — `bootstrap` seeds one but
        // `requestRestart` calls here without going through bootstrap.
        state.upsert(MCPServerStatus(
            name: name,
            command: server.command,
            args: server.args ?? [],
            env: server.env ?? [:],
            state: .starting
        ))
        do {
            let client = try MCPClient(
                name: name,
                command: server.command,
                args: server.args ?? [],
                env: server.env ?? [:],
                onTermination: { [weak self] name in
                    guard let self else { return }
                    self.state.setState(name: name, to: .crashed("Proces lukkede"))
                    Task { await self.requestRestart(name: name) }
                }
            )
            clients[name] = client

            let tools = try await client.initializeAndListTools()
            for tool in tools {
                let adapter = Self.adapter(serverName: name, tool: tool, client: client)
                AgentToolRegistry.shared.register(adapter)
            }
            LoggingService.shared.log("MCP server '\(name)' → \(tools.count) tools registered")
            state.setState(name: name, to: .running(toolCount: tools.count))
            // Successful init — clear the restart counter so future crashes
            // get a fresh 3-attempt budget.
            restartAttempts.removeValue(forKey: name)
        } catch {
            LoggingService.shared.log("MCP server '\(name)' failed: \(error.localizedDescription)", level: .warning)
            state.setState(name: name, to: .crashed(error.localizedDescription))
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

    struct MCPConfig: Codable {
        let servers: [String: Server]

        struct Server: Codable, Equatable {
            let command: String
            let args: [String]?
            let env: [String: String]?

            init(command: String, args: [String]? = nil, env: [String: String]? = nil) {
                self.command = command
                self.args = args
                self.env = env
            }
        }
    }

    private static func loadConfig() throws -> MCPConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ultron/mcp.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MCPConfig.self, from: data)
    }

    /// Read the current on-disk config without mutating registry state. Used
    /// by the Settings MCP pane to seed its editable form.
    static func readConfigSnapshot() -> [String: MCPConfig.Server] {
        (try? loadConfig())?.servers ?? [:]
    }
}
