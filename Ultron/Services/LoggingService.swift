import Foundation

class LoggingService: @unchecked Sendable {
    static let shared = LoggingService()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    private let logDirectoryURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "pavi.Ultron.logging")

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        logDirectoryURL = homeDir.appendingPathComponent("Library/Logs/Ultron")
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        createLogDirectoryIfNeeded()
    }

    private func createLogDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
    }

    /// Cap for the primary log file. When exceeded, rotate to .1, .2, .3 and start fresh.
    private let maxLogSizeBytes: UInt64 = 5 * 1_024 * 1_024  // 5 MB
    private let keepRotations = 3

    func log(_ message: String, level: Level = .info) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            let logFileURL = self.logDirectoryURL.appendingPathComponent("ultron.log")

            self.rotateIfNeeded(logFileURL)

            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    if let data = logLine.data(using: .utf8) {
                        handle.write(data)
                    }
                    handle.closeFile()
                }
            } else {
                try? logLine.write(to: logFileURL, atomically: true, encoding: .utf8)
            }

            #if DEBUG
            print(logLine, terminator: "")
            #endif
        }
    }

    /// Move `ultron.log` → `.1`, `.1` → `.2`, `.2` → `.3`, drop `.3` if it exists.
    /// Cheap-to-run: the stat call is fast, and rotation is only triggered when
    /// the file actually exceeds the cap.
    private func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogSizeBytes else { return }

        // Delete oldest, shift everything up by one.
        let deepestURL = url.appendingPathExtension("\(keepRotations)")
        try? fm.removeItem(at: deepestURL)
        for i in stride(from: keepRotations - 1, through: 1, by: -1) {
            let from = url.appendingPathExtension("\(i)")
            let to = url.appendingPathExtension("\(i + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        let firstRotated = url.appendingPathExtension("1")
        try? fm.moveItem(at: url, to: firstRotated)
    }
}
