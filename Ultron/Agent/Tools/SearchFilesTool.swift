import Foundation

/// `search_files` — glob-style file search inside the allowed workspace.
/// Uses NSMetadataQuery-free recursion via FileManager since we stay on-device
/// and want deterministic results.
enum SearchFilesTool {
    static let tool = AgentTool(
        name: "search_files",
        description: """
        Recursively find files matching a glob pattern within a directory. \
        Case-insensitive. Returns up to `limit` absolute paths. Glob syntax: \
        `*` for any chars (no slashes), `**/*.md` is not supported — use the \
        simpler `*.md` pattern with a scoped `base` directory instead.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "base": [
                    "type": "string",
                    "description": "Directory to search inside (absolute or tilde-expanded)."
                ],
                "pattern": [
                    "type": "string",
                    "description": "Glob-style filename pattern, e.g. '*.pdf' or 'TODO*.md'."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Max number of results (default 50, hard cap 500)."
                ]
            ],
            "required": ["base", "pattern"]
        ],
        requiresConfirmation: false,
        execute: { input, context in
            guard let base = input["base"] as? String, !base.isEmpty else {
                throw AgentError.invalidInput(message: "'base' is required")
            }
            guard let pattern = input["pattern"] as? String, !pattern.isEmpty else {
                throw AgentError.invalidInput(message: "'pattern' is required")
            }
            let limit = min((input["limit"] as? Int) ?? 50, 500)

            let baseURL = try context.resolveAndCheck(path: base)
            let regex = Self.globToRegex(pattern)
            guard let nsRegex = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else {
                throw AgentError.invalidInput(message: "'pattern' is not a valid glob")
            }

            var matches: [String] = []
            guard let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw AgentError.toolFailed(name: "search_files", underlying: "Cannot enumerate \(baseURL.path)")
            }

            for case let url as URL in enumerator {
                let filename = url.lastPathComponent
                let range = NSRange(filename.startIndex..., in: filename)
                if nsRegex.firstMatch(in: filename, range: range) != nil {
                    matches.append(url.path)
                    if matches.count >= limit { break }
                }
            }

            if matches.isEmpty {
                return "No files matching '\(pattern)' under \(baseURL.path)"
            }
            return "Found \(matches.count) match\(matches.count == 1 ? "" : "es") for '\(pattern)':\n"
                + matches.joined(separator: "\n")
        }
    )

    /// Convert a simple glob (`*.md`, `TODO*.txt`) to a regex. Only handles
    /// `*` and `?`. `**` is NOT supported — callers can scope via `base`.
    private static func globToRegex(_ glob: String) -> String {
        var result = "^"
        for char in glob {
            switch char {
            case "*": result += ".*"
            case "?": result += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                result += "\\\(char)"
            default:
                result += String(char)
            }
        }
        result += "$"
        return result
    }
}
