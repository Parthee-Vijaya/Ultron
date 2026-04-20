import Foundation

/// Persists the user's hotkey bindings as JSON in `~/Library/Application Support/Ultron/hotkeys.json`.
/// Mirrors the `CustomModeStore` pattern. Seeds defaults on first launch so existing users get the
/// same bindings they had before v4.0.
final class HotkeyStore {
    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ultron")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storageURL = appSupport.appendingPathComponent("hotkeys.json")
    }

    /// Load the persisted map, filling in defaults for any action that isn't stored yet.
    func load() -> [HotkeyAction: HotkeyBinding] {
        var bindings = Self.defaults()
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return bindings
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let stored = try JSONDecoder().decode([HotkeyBinding].self, from: data)
            for binding in stored {
                bindings[binding.action] = binding
            }
        } catch {
            LoggingService.shared.log("Failed to load hotkeys, using defaults: \(error)", level: .error)
        }
        return bindings
    }

    func save(_ bindings: [HotkeyAction: HotkeyBinding]) {
        let array = HotkeyAction.allCases.compactMap { bindings[$0] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(array)
            try data.write(to: storageURL)
        } catch {
            LoggingService.shared.log("Failed to save hotkeys: \(error)", level: .error)
        }
    }

    /// Reset every binding to its shipped default and persist.
    func resetToDefaults() -> [HotkeyAction: HotkeyBinding] {
        let defaults = Self.defaults()
        save(defaults)
        return defaults
    }

    private static func defaults() -> [HotkeyAction: HotkeyBinding] {
        var result: [HotkeyAction: HotkeyBinding] = [:]
        for action in HotkeyAction.allCases {
            result[action] = action.defaultBinding
        }
        return result
    }
}
