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
    private let queue = DispatchQueue(label: "pavi.Jarvis.logging")

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        logDirectoryURL = homeDir.appendingPathComponent("Library/Logs/Jarvis")
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        createLogDirectoryIfNeeded()
    }

    private func createLogDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
    }

    func log(_ message: String, level: Level = .info) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            let logFileURL = self.logDirectoryURL.appendingPathComponent("jarvis.log")

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
}
