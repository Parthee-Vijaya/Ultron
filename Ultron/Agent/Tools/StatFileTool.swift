import Foundation

/// `stat_file` — return file metadata without reading contents. Cheap and safe;
/// useful for the agent to decide whether to `read_file` on something large.
enum StatFileTool {
    static let tool = AgentTool(
        name: "stat_file",
        description: """
        Return metadata (size, type, modified time) for a file or directory. \
        Does NOT read file contents. Useful for deciding whether to proceed \
        with a read when a file might be very large or binary.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or tilde-expanded path."
                ]
            ],
            "required": ["path"]
        ],
        requiresConfirmation: false,
        execute: { input, context in
            guard let path = input["path"] as? String, !path.isEmpty else {
                throw AgentError.invalidInput(message: "'path' is required")
            }
            let url = try context.resolveAndCheck(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentError.notFound(path: url.path)
            }

            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0
            let modified = (attrs[.modificationDate] as? Date)
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory

            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withTimeZone]

            var lines: [String] = []
            lines.append("path: \(url.path)")
            lines.append("type: \(isDir ? "directory" : "file")")
            lines.append("size: \(size) bytes")
            if let modified {
                lines.append("modified: \(df.string(from: modified))")
            }
            return lines.joined(separator: "\n")
        }
    )
}
