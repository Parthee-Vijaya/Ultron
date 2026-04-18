import Foundation

/// Minimal MCP (Model Context Protocol) client — stdio transport, JSON-RPC 2.0.
///
/// Design scope (v1.1.7-α.1): spawn a locally-defined MCP server as a child
/// process, send `initialize`, then `tools/list`, and adapt each returned tool
/// into an `AgentTool` registered with `AgentToolRegistry.shared`. `tools/call`
/// piping is implemented but server-sent notifications + resources/prompts
/// capabilities are intentionally left for later.
///
/// Config location: `~/.jarvis/mcp.json`
/// Schema:
/// ```json
/// {
///   "servers": {
///     "filesystem": {
///       "command": "npx",
///       "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
///       "env": {"FOO": "bar"}
///     }
///   }
/// }
/// ```
@MainActor
final class MCPClient {
    enum MCPError: LocalizedError {
        case processSpawnFailed(String)
        case transportClosed
        case rpcError(code: Int, message: String)
        case timeout
        case malformedResponse(String)
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .processSpawnFailed(let err):  return "MCP server couldn't start: \(err)"
            case .transportClosed:               return "MCP server closed the pipe"
            case .rpcError(let code, let msg):   return "MCP error \(code): \(msg)"
            case .timeout:                       return "MCP server didn't respond in time"
            case .malformedResponse(let reason): return "Malformed MCP response: \(reason)"
            case .notInitialized:                return "MCP client called before initialize()"
            }
        }
    }

    let name: String
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    /// Line-buffered stdout reader state — MCP is newline-delimited JSON-RPC.
    nonisolated(unsafe) private var readBuffer = Data()
    /// Next request ID. MCP requires monotonically-increasing ids per client.
    private var nextID: Int = 1
    /// Promises awaiting responses keyed on id.
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var initialized = false

    init(name: String, command: String, args: [String], env: [String: String]) throws {
        self.name = name
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        // Use /usr/bin/env so PATH lookup works for npx/uvx/python/etc.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Merge user env over current process env (PATH / HOME preserved).
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        process.environment = merged

        do {
            try process.run()
        } catch {
            throw MCPError.processSpawnFailed(error.localizedDescription)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.handleStdoutChunk(chunk) }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    // MARK: - Public API

    func initializeAndListTools() async throws -> [MCPTool] {
        // Step 1: initialize
        let initResult = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": [
                    "name": "Jarvis",
                    "version": Constants.appVersion
                ] as [String: Any]
            ]
        )
        _ = initResult  // we don't surface server capabilities in α.1
        initialized = true

        // Send the initialized notification — per MCP spec.
        try sendNotification(method: "notifications/initialized", params: [:] as [String: Any])

        // Step 2: list tools
        let listResult = try await sendRequest(method: "tools/list", params: [:] as [String: Any])
        guard let dict = listResult as? [String: Any],
              let rawTools = dict["tools"] as? [[String: Any]] else {
            throw MCPError.malformedResponse("tools/list missing 'tools' array")
        }
        return rawTools.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let description = (entry["description"] as? String) ?? ""
            let schema = (entry["inputSchema"] as? [String: Any]) ?? [:]
            return MCPTool(name: name, description: description, inputSchema: schema)
        }
    }

    /// Invoke a tool by name. Returns the raw content string returned by
    /// the server (concatenated if multiple content parts were returned).
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        guard initialized else { throw MCPError.notInitialized }
        let result = try await sendRequest(
            method: "tools/call",
            params: [
                "name": name,
                "arguments": arguments
            ] as [String: Any]
        )
        // Server returns: { content: [{type: "text", text: "..."}], isError: false }
        guard let dict = result as? [String: Any] else {
            throw MCPError.malformedResponse("tools/call result is not an object")
        }
        if (dict["isError"] as? Bool) == true {
            let errText = (dict["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "unknown"
            throw MCPError.rpcError(code: -32000, message: errText)
        }
        let parts = (dict["content"] as? [[String: Any]]) ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    func shutdown() {
        if process.isRunning { process.terminate() }
    }

    // MARK: - JSON-RPC plumbing

    private func sendRequest(method: String, params: Any) async throws -> Any {
        let id = nextID
        nextID += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = data + Data([0x0A])  // newline
        return try await withCheckedThrowingContinuation { continuation in
            self.pending[id] = continuation
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                self.pending[id] = nil
                continuation.resume(throwing: MCPError.transportClosed)
                return
            }
            // 20 s timeout per request — generous for local tool servers.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                if let pending = self.pending[id] {
                    self.pending[id] = nil
                    pending.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    private func sendNotification(method: String, params: Any) throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    private func handleStdoutChunk(_ chunk: Data) {
        readBuffer.append(chunk)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(0...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handleMessage(json)
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let id = message["id"] as? Int,
              let continuation = pending.removeValue(forKey: id) else {
            // Notifications + server-originated requests ignored for α.1.
            return
        }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            let msg = (error["message"] as? String) ?? "unknown"
            continuation.resume(throwing: MCPError.rpcError(code: code, message: msg))
        } else if let result = message["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: MCPError.malformedResponse("missing both result and error"))
        }
    }
}

/// Plain-data view of an MCP tool descriptor.
struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}
