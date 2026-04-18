import Foundation

/// `list_directory` — enumerate files and sub-folders at a given path.
/// Read-only.
enum ListDirectoryTool {
    static let tool = AgentTool(
        name: "list_directory",
        description: """
        List the immediate contents (files + sub-folders) of a directory. \
        Returns a newline-separated list where each line is \
        "<type> <name> <size-bytes>" (type = "dir" or "file"). Hidden \
        dotfiles are included unless `include_hidden` is set to false.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or tilde-expanded directory path."
                ],
                "include_hidden": [
                    "type": "boolean",
                    "description": "Include dotfiles (default true)."
                ]
            ],
            "required": ["path"]
        ],
        requiresConfirmation: false,
        execute: { input, context in
            guard let path = input["path"] as? String, !path.isEmpty else {
                throw AgentError.invalidInput(message: "'path' is required")
            }
            let includeHidden = (input["include_hidden"] as? Bool) ?? true
            let url = try context.resolveAndCheck(path: path)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                throw AgentError.notFound(path: url.path)
            }

            let options: FileManager.DirectoryEnumerationOptions =
                includeHidden ? [] : [.skipsHiddenFiles]
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: options
                )
            } catch {
                throw AgentError.toolFailed(name: "list_directory", underlying: error.localizedDescription)
            }

            let rows: [String] = entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .map { entry -> String in
                    let values = (try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]))
                    let isDirectory = values?.isDirectory ?? false
                    let size = values?.fileSize ?? 0
                    let type = isDirectory ? "dir " : "file"
                    let sizeLabel = isDirectory ? "-" : String(size)
                    return "\(type) \(entry.lastPathComponent) \(sizeLabel)"
                }

            if rows.isEmpty {
                return "(empty directory)"
            }
            return "Listed \(rows.count) entries in \(url.path):\n" + rows.joined(separator: "\n")
        }
    )
}
