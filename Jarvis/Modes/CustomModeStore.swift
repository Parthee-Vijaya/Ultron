import Foundation

class CustomModeStore {
    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storageURL = appSupport.appendingPathComponent("modes.json")
    }

    func loadModes() -> [Mode] {
        guard let data = try? Data(contentsOf: storageURL),
              let modes = try? JSONDecoder().decode([Mode].self, from: data) else {
            return []
        }
        return modes
    }

    func saveModes(_ modes: [Mode]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(modes) else { return }
        try? data.write(to: storageURL)
    }
}
