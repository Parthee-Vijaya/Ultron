import AppKit
import Foundation

/// Two-way backup for dictation output: NSPasteboard (so the user can ⌘V
/// again anywhere) + Notes.app (so there's a permanent record outside any
/// single app's undo stack). Both sinks are fire-and-forget from the paste
/// path — neither should ever block the primary text-insertion flow.
enum DictationPersistence {
    /// Dual-persist a freshly dictated line: copy to the general pasteboard
    /// and append a new note to the default Notes account. Runs in a detached
    /// Task so the caller returns immediately.
    ///
    /// The Notes append uses AppleScript (osascript) because Apple doesn't
    /// ship a first-party Swift API for Notes. Script execution is gated on
    /// TCC "Automation → Notes" — the user sees a one-time permission prompt
    /// on first dictation after install.
    static func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1) Clipboard — synchronous, tiny cost.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        LoggingService.shared.log("Dictation → pasteboard (\(trimmed.count) chars)")

        // 2) Notes.app — off main thread, AppleScript can take 100-400 ms.
        Task.detached(priority: .utility) {
            appendToNotes(trimmed)
        }
    }

    /// AppleScript body: create a new note in the default account with a
    /// timestamped title + the dictated body. Escaping is deliberately
    /// conservative — only double-quotes and backslashes are replaced.
    private static func appendToNotes(_ text: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let title = "Ultron dictation · \(timestamp)"

        let escapedTitle = escapeForAppleScript(title)
        let escapedBody = escapeForAppleScript(text)

        let script = """
        tell application "Notes"
            tell default account
                make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
            end tell
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()   // discard stdout

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                LoggingService.shared.log("Dictation → Notes.app (\(text.count) chars, title=\(title))")
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? "unknown osascript error"
                LoggingService.shared.log("Notes append failed (exit=\(process.terminationStatus)): \(errText.trimmingCharacters(in: .whitespacesAndNewlines))", level: .warning)
            }
        } catch {
            LoggingService.shared.log("Notes append could not launch osascript: \(error)", level: .warning)
        }
    }

    /// Escape for an AppleScript double-quoted string literal. Only `\` and
    /// `"` need escaping; newlines and unicode pass through fine (Notes
    /// renders them as <br> / UTF-8).
    private static func escapeForAppleScript(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "d. MMM yyyy · HH:mm"
        df.locale = Locale(identifier: "da_DK")
        return df
    }()
}
