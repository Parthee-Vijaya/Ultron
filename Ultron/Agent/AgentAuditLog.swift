import Foundation

/// Dedicated append-only log for agent tool calls. Separate from `ultron.log`
/// so `grep`-ing it is straightforward and so rotation can be tuned
/// independently (agent logs are verbose; 10 MB cap with 3 rotations).
final class AgentAuditLog: @unchecked Sendable {
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "pavi.Ultron.AgentAuditLog", qos: .utility)
    private let dateFormatter: DateFormatter
    private let maxBytes: UInt64 = 10 * 1_024 * 1_024
    private let keepRotations = 3

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ultron")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logFileURL = dir.appendingPathComponent("agent.log")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = df
    }

    /// One entry per tool call — before-execution summary.
    func recordToolCall(conversation: UUID, tool: String, inputSummary: String) {
        let line = "[\(timestamp())] [\(conversation.uuidString.prefix(8))] CALL  \(tool) :: \(inputSummary)\n"
        append(line)
    }

    /// Companion entry after execution — success, truncated result, duration.
    func recordToolResult(conversation: UUID, tool: String, success: Bool, resultSummary: String, durationMs: Int) {
        let status = success ? "OK  " : "FAIL"
        let line = "[\(timestamp())] [\(conversation.uuidString.prefix(8))] \(status) \(tool) (\(durationMs)ms) :: \(resultSummary)\n"
        append(line)
    }

    /// Conversation boundary marker, for easier grepping.
    func recordConversationStart(conversation: UUID, userPrompt: String) {
        let preview = userPrompt.prefix(160).replacingOccurrences(of: "\n", with: " ")
        let line = "[\(timestamp())] [\(conversation.uuidString.prefix(8))] BEGIN :: \(preview)\n"
        append(line)
    }

    func recordConversationEnd(conversation: UUID, finalResponse: String, toolCount: Int) {
        let preview = finalResponse.prefix(160).replacingOccurrences(of: "\n", with: " ")
        let line = "[\(timestamp())] [\(conversation.uuidString.prefix(8))] END   (tools=\(toolCount)) :: \(preview)\n"
        append(line)
    }

    // MARK: - Internals

    private func timestamp() -> String {
        dateFormatter.string(from: Date())
    }

    private func append(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeeded()

            if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                    handle.seekToEndOfFile()
                    if let data = line.data(using: .utf8) {
                        handle.write(data)
                    }
                    try? handle.close()
                }
            } else {
                try? line.write(to: self.logFileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxBytes else { return }

        let deepest = logFileURL.appendingPathExtension("\(keepRotations)")
        try? fm.removeItem(at: deepest)
        for i in stride(from: keepRotations - 1, through: 1, by: -1) {
            let from = logFileURL.appendingPathExtension("\(i)")
            let to = logFileURL.appendingPathExtension("\(i + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        try? fm.moveItem(at: logFileURL, to: logFileURL.appendingPathExtension("1"))
    }
}
