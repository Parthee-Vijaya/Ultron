import AppKit

/// NSPanel subclass that accepts keyboard input even in nonactivating-panel
/// mode. Without these overrides a `.nonactivatingPanel` can't become key,
/// which means the chat TextField in v4.x and v5.0.0-alpha.4 silently ignored
/// keystrokes — the user would click the input, see the cursor, and typing
/// went nowhere.
///
/// Fix: override both `canBecomeKey` and `canBecomeMain` to true for our
/// chat window. The mic and hotkey plumbing still works because we never
/// actually activate the app as frontmost — we just let this one panel grab
/// the first-responder chain.
final class JarvisChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override var acceptsFirstResponder: Bool { true }
}
