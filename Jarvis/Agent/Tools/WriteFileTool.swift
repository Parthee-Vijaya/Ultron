import Foundation

/// `write_file` — atomic text write. Destructive: overwrites existing content
/// if the file already exists, so the user always gets a confirmation prompt
/// before execution.
enum WriteFileTool {
    static let tool = AgentTool(
        name: "write_file",
        description: """
        Write text content to a file at the given path. Creates the file if it \
        doesn't exist, overwrites it if it does (the user is asked to confirm). \
        Path must live inside the allowed workspace roots. Writes are atomic — \
        partial data is never left on disk if the write fails mid-stream.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or tilde-expanded path to the file to write."
                ],
                "content": [
                    "type": "string",
                    "description": "Full new text content for the file (UTF-8)."
                ],
                "create_parent": [
                    "type": "boolean",
                    "description": "If true, creates the parent directory when missing (default false)."
                ]
            ],
            "required": ["path", "content"]
        ],
        requiresConfirmation: true,
        execute: { input, context in
            guard let path = input["path"] as? String, !path.isEmpty else {
                throw AgentError.invalidInput(message: "'path' is required")
            }
            guard let content = input["content"] as? String else {
                throw AgentError.invalidInput(message: "'content' is required")
            }
            let createParent = (input["create_parent"] as? Bool) ?? false

            let url = try context.resolveAndCheck(path: path)
            let parent = url.deletingLastPathComponent()

            // Verify parent exists (or create it if allowed).
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) {
                guard createParent else {
                    throw AgentError.toolFailed(
                        name: "write_file",
                        underlying: "Parent directory '\(parent.path)' doesn't exist. Pass create_parent=true to create it."
                    )
                }
                _ = try context.resolveAndCheck(path: parent.path)  // enforce workspace
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    throw AgentError.toolFailed(name: "write_file",
                                                underlying: "Could not create parent: \(error.localizedDescription)")
                }
            }

            let existed = FileManager.default.fileExists(atPath: url.path)
            let existingSize: Int = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw AgentError.toolFailed(name: "write_file", underlying: error.localizedDescription)
            }

            let newSize = content.utf8.count
            if existed {
                return "Overwrote \(url.path) — \(existingSize) → \(newSize) bytes"
            } else {
                return "Created \(url.path) — \(newSize) bytes"
            }
        }
    )
}
