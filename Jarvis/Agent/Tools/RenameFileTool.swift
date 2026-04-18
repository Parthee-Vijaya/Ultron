import Foundation

/// `rename_file` — rename or move a file/directory inside the workspace.
/// Both source and destination must lie inside allowed roots. Destination
/// must not already exist (fails loud rather than silently clobbering).
enum RenameFileTool {
    static let tool = AgentTool(
        name: "rename_file",
        description: """
        Rename or move a file or directory within the allowed workspace. Both \
        source and destination paths must live inside the workspace roots. \
        Fails if the destination already exists (no silent overwrites).
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "source": [
                    "type": "string",
                    "description": "Current path (absolute or tilde-expanded)."
                ],
                "destination": [
                    "type": "string",
                    "description": "Target path (absolute or tilde-expanded)."
                ]
            ],
            "required": ["source", "destination"]
        ],
        requiresConfirmation: true,
        execute: { input, context in
            guard let sourceRaw = input["source"] as? String, !sourceRaw.isEmpty else {
                throw AgentError.invalidInput(message: "'source' is required")
            }
            guard let destinationRaw = input["destination"] as? String, !destinationRaw.isEmpty else {
                throw AgentError.invalidInput(message: "'destination' is required")
            }

            let source = try context.resolveAndCheck(path: sourceRaw)
            let destination = try context.resolveAndCheck(path: destinationRaw)

            guard FileManager.default.fileExists(atPath: source.path) else {
                throw AgentError.notFound(path: source.path)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                throw AgentError.toolFailed(
                    name: "rename_file",
                    underlying: "Destination already exists: \(destination.path)"
                )
            }

            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                throw AgentError.toolFailed(name: "rename_file", underlying: error.localizedDescription)
            }
            return "Moved \(source.path) → \(destination.path)"
        }
    )
}
