import AppKit

/// NSPanel subclass that accepts keyboard input even in nonactivating-panel
/// mode. Without these overrides a `.nonactivatingPanel` can't become key,
/// which means TextFields hosted inside silently ignore keystrokes — the user
/// clicks the input, sees a cursor, and typing goes nowhere.
///
/// Used by the chat window and the Info-mode panel (which added a route
/// destination text field in β.5 that hit this exact regression). The mic
/// and hotkey plumbing still works because we never activate the app as
/// frontmost — we just let the panel grab the first-responder chain.
final class UltronKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override var acceptsFirstResponder: Bool { true }
}

/// Back-compat alias — earlier call sites used `UltronChatPanel`. Keep the
/// name to avoid a wide rename while the subclass is generic enough to serve
/// both panels.
typealias UltronChatPanel = UltronKeyablePanel
