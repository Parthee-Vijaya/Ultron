import AppKit
import Foundation
import Observation

/// Observable wrapper that bridges `HotkeyStore` + `HotkeyManager` into SwiftUI.
/// Owned by `AppDelegate` and injected into `SettingsView` via `@Environment`.
@Observable
final class HotkeyBindings {
    private(set) var bindings: [HotkeyAction: HotkeyBinding]

    private let store: HotkeyStore
    private let manager: HotkeyManager

    init(store: HotkeyStore, manager: HotkeyManager) {
        self.store = store
        self.manager = manager
        self.bindings = store.load()
    }

    /// Apply the current bindings to the global hotkey manager. Call once at startup.
    func applyAll() {
        manager.register(bindings: bindings)
    }

    /// Update one binding — validates, persists, and re-registers with the OS.
    /// Returns `.valid` on success, `.invalid(message)` if rejected.
    @discardableResult
    func update(_ action: HotkeyAction, keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> HotkeyBinding.ValidationResult {
        let candidate = HotkeyBinding(action: action, keyCode: keyCode, modifiersRaw: modifiers.rawValue)
        let result = candidate.validate()
        guard result.isValid else { return result }
        bindings[action] = candidate
        store.save(bindings)
        manager.rebind(action: action, to: candidate)
        return .valid
    }

    /// Restore every binding to its shipped default.
    func resetAll() {
        bindings = store.resetToDefaults()
        manager.register(bindings: bindings)
    }

    func binding(for action: HotkeyAction) -> HotkeyBinding {
        bindings[action] ?? action.defaultBinding
    }
}
