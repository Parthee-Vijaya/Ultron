import Foundation

/// `delete_file` — remove a file or directory. Uses `trashItem` so deletions
/// are recoverable via macOS Trash — Jarvis never hard-unlinks files.
enum DeleteFileTool {
    static let tool = AgentTool(
        name: "delete_file",
        description: """
        Move a file or directory to the macOS Trash. Recoverable from Trash \
        until the user empties it. Path must lie inside an allowed workspace \
        root.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or tilde-expanded path to delete."
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
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentError.notFound(path: url.path)
            }

            var resultingURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                throw AgentError.toolFailed(name: "delete_file", underlying: error.localizedDescription)
            }

            if let trashed = resultingURL as URL? {
                return "Moved \(url.path) to Trash → \(trashed.path)"
            }
            return "Moved \(url.path) to Trash"
        }
    )
}
