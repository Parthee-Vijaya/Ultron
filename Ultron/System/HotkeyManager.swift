import AppKit
import Carbon
import HotKey

/// Registers global hotkeys via `soffes/HotKey` and forwards key-down/up events to
/// action-specific callbacks. As of v4.0 bindings are dynamic: the owner calls
/// `register(bindings:)` once at startup and `rebind(action:to:)` whenever the
/// user changes a shortcut in Settings.
final class HotkeyManager {
    // One HotKey instance per action (recreated on rebind).
    private var hotKeys: [HotkeyAction: HotKey] = [:]
    private var currentBindings: [HotkeyAction: HotkeyBinding] = [:]

    // Action callbacks wired by AppDelegate.
    var onDictationKeyDown: (() -> Void)?
    var onDictationKeyUp: (() -> Void)?
    var onQnAKeyDown: (() -> Void)?
    var onQnAKeyUp: (() -> Void)?
    var onVisionKeyDown: (() -> Void)?
    var onVisionKeyUp: (() -> Void)?
    var onTranslateKeyDown: (() -> Void)?
    var onTranslateKeyUp: (() -> Void)?
    var onModeCycle: (() -> Void)?
    var onChatToggle: (() -> Void)?
    var onUptodate: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onInfoMode: (() -> Void)?
    var onAgent: (() -> Void)?
    var onGenerateDigest: (() -> Void)?
    var onClipboardHistory: (() -> Void)?

    /// Install all bindings. Call once at app start after loading from `HotkeyStore`.
    func register(bindings: [HotkeyAction: HotkeyBinding]) {
        unregisterAll()
        currentBindings = bindings
        for action in HotkeyAction.allCases {
            guard let binding = bindings[action] else { continue }
            install(binding)
        }
        LoggingService.shared.log("Hotkeys registered (\(hotKeys.count) bindings active)")
        if let dictation = bindings[.dictation], dictation.keyCode == Key.space.carbonKeyCode,
           dictation.modifiers == .option {
            LoggingService.shared.log("Note: ⌥Space is Spotlight's default shortcut — remap in Settings → Hotkeys if it conflicts.", level: .info)
        }
    }

    /// Replace one binding in-place. Store persistence is the caller's responsibility.
    func rebind(action: HotkeyAction, to binding: HotkeyBinding) {
        // Tear down existing HotKey for this action (deinit unregisters).
        hotKeys[action] = nil
        currentBindings[action] = binding
        install(binding)
        LoggingService.shared.log("Hotkey rebound: \(action.rawValue) → \(binding.displayString)")
    }

    func unregisterAll() {
        hotKeys.removeAll()
        currentBindings.removeAll()
    }

    // MARK: - Private

    private func install(_ binding: HotkeyBinding) {
        guard let key = binding.hotkeyKey else {
            LoggingService.shared.log("Unknown key code \(binding.keyCode) for \(binding.action.rawValue) — skipping", level: .warning)
            return
        }

        let hotKey = HotKey(key: key, modifiers: binding.modifiers)
        wireHandlers(for: binding.action, on: hotKey)
        hotKeys[binding.action] = hotKey
    }

    private func wireHandlers(for action: HotkeyAction, on hotKey: HotKey) {
        switch action {
        case .dictation:
            hotKey.keyDownHandler = { [weak self] in self?.onDictationKeyDown?() }
            hotKey.keyUpHandler   = { [weak self] in self?.onDictationKeyUp?() }
        case .qna:
            hotKey.keyDownHandler = { [weak self] in self?.onQnAKeyDown?() }
            hotKey.keyUpHandler   = { [weak self] in self?.onQnAKeyUp?() }
        case .vision:
            hotKey.keyDownHandler = { [weak self] in self?.onVisionKeyDown?() }
            hotKey.keyUpHandler   = { [weak self] in self?.onVisionKeyUp?() }
        case .translate:
            hotKey.keyDownHandler = { [weak self] in self?.onTranslateKeyDown?() }
            hotKey.keyUpHandler   = { [weak self] in self?.onTranslateKeyUp?() }
        case .cycleMode:
            hotKey.keyDownHandler = { [weak self] in self?.onModeCycle?() }
        case .toggleChat:
            hotKey.keyDownHandler = { [weak self] in self?.onChatToggle?() }
        case .uptodate:
            hotKey.keyDownHandler = { [weak self] in self?.onUptodate?() }
        case .summarize:
            hotKey.keyDownHandler = { [weak self] in self?.onSummarize?() }
        case .infoMode:
            hotKey.keyDownHandler = { [weak self] in self?.onInfoMode?() }
        case .agent:
            hotKey.keyDownHandler = { [weak self] in self?.onAgent?() }
        case .generateDigest:
            hotKey.keyDownHandler = { [weak self] in self?.onGenerateDigest?() }
        case .clipboardHistory:
            hotKey.keyDownHandler = { [weak self] in self?.onClipboardHistory?() }
        }
    }
}
