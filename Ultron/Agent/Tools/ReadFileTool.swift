import Foundation

/// `read_file` — fetch the textual contents of a file inside the agent's
/// workspace. Read-only, safe to run without confirmation.
enum ReadFileTool {
    static let tool = AgentTool(
        name: "read_file",
        description: """
        Read the full text contents of a file at the given path. Returns the \
        file's text content, or an error if the file doesn't exist, isn't a \
        text file, or falls outside the allowed workspace roots.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or tilde-expanded path to the file."
                ],
                "max_bytes": [
                    "type": "integer",
                    "description": "Optional safety cap on how many bytes to read (default 500_000)."
                ]
            ],
            "required": ["path"]
        ],
        requiresConfirmation: false,
        execute: { input, context in
            guard let path = input["path"] as? String, !path.isEmpty else {
                throw AgentError.invalidInput(message: "'path' is required")
            }
            let maxBytes = (input["max_bytes"] as? Int) ?? 500_000

            let url = try context.resolveAndCheck(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentError.notFound(path: url.path)
            }

            let fileHandle: FileHandle
            do {
                fileHandle = try FileHandle(forReadingFrom: url)
            } catch {
                throw AgentError.toolFailed(name: "read_file", underlying: error.localizedDescription)
            }
            defer { try? fileHandle.close() }
            let data = fileHandle.readData(ofLength: maxBytes)

            guard let text = String(data: data, encoding: .utf8) else {
                // Retry once with ISO Latin for legacy files.
                guard let text = String(data: data, encoding: .isoLatin1) else {
                    throw AgentError.toolFailed(name: "read_file", underlying: "File is not text")
                }
                return text
            }

            let bytesRead = data.count
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let totalSize = (attrs[.size] as? Int) ?? bytesRead
            let truncatedNote = bytesRead < totalSize ? "\n\n[truncated — \(bytesRead) / \(totalSize) bytes shown]" : ""

            return text + truncatedNote
        }
    )
}
