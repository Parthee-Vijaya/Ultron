import Foundation

/// Shared state passed into every tool execution. Lets tools consult the
/// workspace allowlist, write to the audit log, and reference the conversation
/// ID for cross-cutting observability.
@MainActor
final class AgentContext {
    /// Roots the agent is allowed to read from / write to. Anything outside
    /// these prefixes throws `AgentError.outsideWorkspace`. Defaults to the
    /// user's Desktop + Downloads + ~/Documents/Jarvis for safety.
    var allowedRoots: [URL]
    /// Audit log sink. Every tool execution reports here regardless of outcome.
    let audit: AgentAuditLog
    /// Conversation identifier stamped onto every audit record so post-hoc
    /// analysis can reconstruct a run from the log file.
    let conversationID: UUID

    init(allowedRoots: [URL], audit: AgentAuditLog, conversationID: UUID = UUID()) {
        self.allowedRoots = allowedRoots
        self.audit = audit
        self.conversationID = conversationID
    }

    /// Default roots shipped in β1. Users can widen/narrow via Settings in later β turns.
    static func defaultAllowedRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents/Jarvis")
        ]
    }

    /// Resolve a user-supplied path (possibly starting with `~`) to an absolute
    /// URL and verify it lies inside one of the allowed roots. Throws on escape.
    func resolveAndCheck(path rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

        let targetPath = url.path
        for root in allowedRoots {
            let rootPath = root.standardizedFileURL.path
            if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                return url
            }
        }
        throw AgentError.outsideWorkspace(path: url.path)
    }
}

/// Typed errors surfaced by the agent tool layer.
enum AgentError: LocalizedError, Sendable {
    case outsideWorkspace(path: String)
    case invalidInput(message: String)
    case toolFailed(name: String, underlying: String)
    case notFound(path: String)
    case confirmationRejected(tool: String)
    case iterationLimitReached(max: Int)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path):
            return "Stien '\(path)' ligger uden for Jarvis' tilladte arbejdsområde. Tilføj den under Settings → Agent → Allowed roots hvis du vil tillade adgang."
        case .invalidInput(let message):
            return "Ugyldig input: \(message)"
        case .toolFailed(let name, let underlying):
            return "Værktøj '\(name)' fejlede: \(underlying)"
        case .notFound(let path):
            return "Ingen fil eller mappe fundet ved '\(path)'."
        case .confirmationRejected(let tool):
            return "Du afviste tilladelse til at køre '\(tool)'."
        case .iterationLimitReached(let max):
            return "Agent-loop nåede \(max) iterationer uden et endeligt svar. Afbrudt af sikkerhedshensyn."
        }
    }
}
