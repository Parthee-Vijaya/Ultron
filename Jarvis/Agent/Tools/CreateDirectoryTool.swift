import Foundation

/// `create_directory` — make a new directory (plus any missing parents).
/// Under confirmation because it introduces filesystem structure even if
/// it's a read/write-neutral operation.
enum CreateDirectoryTool {
    static let tool = AgentTool(
        name: "create_directory",
        description: """
        Create a directory at the given path. Creates missing parent \
        directories as needed. Path must lie inside the allowed workspace.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or tilde-expanded directory path."
                ]
            ],
            "required": ["path"]
        ],
        requiresConfirmation: true,
        execute: { input, context in
            guard let path = input["path"] as? String, !path.isEmpty else {
                throw AgentError.invalidInput(message: "'path' is required")
            }
            let url = try context.resolveAndCheck(path: path)

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return "Directory already exists: \(url.path)"
                } else {
                    throw AgentError.toolFailed(
                        name: "create_directory",
                        underlying: "A file already exists at \(url.path)"
                    )
                }
            }

            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw AgentError.toolFailed(name: "create_directory", underlying: error.localizedDescription)
            }
            return "Created directory \(url.path)"
        }
    )
}
