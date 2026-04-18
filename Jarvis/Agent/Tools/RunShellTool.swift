import Foundation

/// `run_shell` — execute a whitelisted shell command. The whitelist lives in
/// UserDefaults under `Constants.Defaults.shellCommandWhitelist` (settable in
/// Settings → Agent) and defaults to a safe read-only set: ls, cat, grep,
/// find, git (status/log/diff), swift (build), xcodebuild, sw_vers, uname,
/// pwd, whoami. The user approves each invocation before it runs.
///
/// Commands are parsed with POSIX argv semantics — quoted args are preserved,
/// shell metacharacters (`|`, `&`, `;`, `>`, backticks, `$()`) are rejected.
/// No subshell, no environment inheritance. Output capped at 64 KiB.
enum RunShellTool {
    /// Built-in whitelist — union'd with any user additions from Settings.
    /// Deliberately conservative: read-only commands that can't mutate disk
    /// state on their own. Destructive tools (rm, cp, mv, chmod) are NOT here.
    static let defaultAllowedPrograms: [String] = [
        "ls", "cat", "head", "tail", "wc", "file", "which",
        "grep", "find", "tree",
        "git",           // limited below via subcommand whitelist
        "swift",
        "xcodebuild",
        "sw_vers", "uname", "pwd", "whoami", "date", "uptime",
        "ifconfig", "arp", "networkQuality",
        "defaults"       // read-only via subcommand whitelist
    ]

    /// Subcommand-level whitelist for tools that can also mutate state.
    static let subcommandWhitelist: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "branch", "remote", "config"],
        "defaults": ["read"]
    ]

    static let tool = AgentTool(
        name: "run_shell",
        description: """
        Execute a read-only shell command and return its stdout + stderr. \
        Only commands on the whitelist run — the whitelist is conservative \
        and read-only by default (ls, cat, grep, find, git-read, swift build, \
        xcodebuild, etc.). Shell metacharacters (`|`, `&`, `;`, `>`, \
        backticks, `$()`) are rejected — each call is a single program + args. \
        Use this to inspect project state, not to mutate it. The user \
        approves each invocation before it runs.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "Full command line, e.g. 'git log --oneline -10' or 'ls -la /tmp'. No pipes / redirects."
                ],
                "workdir": [
                    "type": "string",
                    "description": "Optional working directory for the command. Defaults to first allowed workspace root."
                ]
            ],
            "required": ["command"]
        ],
        requiresConfirmation: true,
        execute: { input, context in
            guard let commandLine = input["command"] as? String, !commandLine.isEmpty else {
                throw AgentError.invalidInput(message: "'command' is required")
            }

            // Reject shell metacharacters outright. We run a single program,
            // not a subshell, so pipes / redirects / command substitution
            // would just fail anyway — failing fast gives a clearer error.
            let forbidden = ["|", "&", ";", ">", "<", "`", "$("]
            if let bad = forbidden.first(where: { commandLine.contains($0) }) {
                throw AgentError.invalidInput(message: "Shell metacharacter '\(bad)' not allowed in run_shell")
            }

            let tokens = tokenize(commandLine)
            guard let program = tokens.first else {
                throw AgentError.invalidInput(message: "command is empty after tokenising")
            }

            try enforceWhitelist(program: program, tokens: tokens)

            // Resolve workdir — defaults to the first allowed workspace root
            // so commands don't accidentally run against $HOME.
            let workdir: URL
            if let workdirString = input["workdir"] as? String, !workdirString.isEmpty {
                workdir = try context.resolveAndCheck(path: workdirString)
            } else if let first = context.allowedRoots.first {
                workdir = first
            } else {
                throw AgentError.toolFailed(name: "run_shell", underlying: "No allowed workspace root to run in")
            }

            // Resolve the absolute path via /usr/bin/env so we don't have to
            // hard-code Xcode toolchain paths etc.
            return try await runProcess(
                program: program,
                args: Array(tokens.dropFirst()),
                workdir: workdir
            )
        }
    )

    // MARK: - Whitelist enforcement

    private static func enforceWhitelist(program: String, tokens: [String]) throws {
        // Strip any leading directory — we compare the basename.
        let programName = (program as NSString).lastPathComponent
        let effectiveWhitelist = Set(defaultAllowedPrograms)
            .union(userAddedPrograms())

        guard effectiveWhitelist.contains(programName) else {
            throw AgentError.invalidInput(
                message: "'\(programName)' is not on the run_shell whitelist. Whitelist lives in Settings → Agent."
            )
        }

        // If the program has a subcommand whitelist, enforce it.
        if let allowedSubs = subcommandWhitelist[programName] {
            let subcommand = tokens.dropFirst().first(where: { !$0.hasPrefix("-") })
            guard let sub = subcommand, allowedSubs.contains(sub) else {
                throw AgentError.invalidInput(
                    message: "'\(programName) \(subcommand ?? "(no subcommand)")' is not on the read-only subcommand whitelist. Allowed: \(allowedSubs.sorted().joined(separator: ", "))."
                )
            }
        }
    }

    private static func userAddedPrograms() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: Constants.Defaults.shellCommandWhitelist) ?? ""
        return Set(
            raw.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - POSIX-ish tokeniser

    private static func tokenize(_ commandLine: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character? = nil

        for char in commandLine {
            if let q = inQuote {
                if char == q { inQuote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                inQuote = char
            } else if char.isWhitespace {
                if !current.isEmpty { tokens.append(current); current.removeAll() }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Process execution

    private static func runProcess(program: String, args: [String], workdir: URL) async throws -> String {
        let process = Process()
        // Go through /usr/bin/env so we get PATH lookup. If program is already
        // an absolute path, env just execs it directly.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + args
        process.currentDirectoryURL = workdir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AgentError.toolFailed(name: "run_shell", underlying: "Could not start '\(program)': \(error.localizedDescription)")
        }

        // Timeout after 30 s — a longer-running command should be run as its
        // own process outside the agent loop.
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let cappedStdout = cap(stdout, to: 65_536)
        let cappedStderr = cap(stderr, to: 8_192)

        var result = "$ \(program) \(args.joined(separator: " "))\n"
        result += "exit: \(process.terminationStatus)\n"
        if !cappedStdout.isEmpty { result += "--- stdout ---\n\(cappedStdout)\n" }
        if !cappedStderr.isEmpty { result += "--- stderr ---\n\(cappedStderr)\n" }
        return result
    }

    private static func cap(_ text: String, to maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let truncated = String(text.prefix(maxBytes))
        return truncated + "\n… (truncated \(text.utf8.count - maxBytes) bytes)"
    }
}
