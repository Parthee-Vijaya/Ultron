import Foundation

class CustomModeStore {
    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ultron")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storageURL = appSupport.appendingPathComponent("modes.json")
    }

    func loadModes() -> [Mode] {
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode([Mode].self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            LoggingService.shared.log("Failed to load custom modes: \(error)", level: .error)
            return []
        }
    }

    func saveModes(_ modes: [Mode]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(modes)
            try data.write(to: storageURL)
        } catch {
            LoggingService.shared.log("Failed to save custom modes: \(error)", level: .error)
        }
    }
}
