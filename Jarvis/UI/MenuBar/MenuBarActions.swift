import Foundation

/// Plain struct of closures the menu-bar SwiftUI scene (coming in Step 3 of
/// the MenuBarExtra migration) will invoke. Wrapping everything in a single
/// value type means the SwiftUI side never has to know about AppDelegate —
/// it just gets actions.
///
/// Order mirrors the existing NSMenu layout so the visual diff during the
/// transition is minimal.
@MainActor
struct MenuBarActions: Sendable {
    var switchMode: (UUID) -> Void
    var openInfoMode: () -> Void
    var openUptodate: () -> Void
    var openSettings: () -> Void
    var openHotkeysSettings: () -> Void
    var openCheatSheet: () -> Void
    var checkForUpdates: () -> Void
    var quit: () -> Void

    /// Placeholder used by the SwiftUI scaffolding when AppDelegate hasn't
    /// wired real actions yet. Every closure no-ops; safe for previews and
    /// tests that exercise layout without side effects.
    static var noop: MenuBarActions {
        .init(
            switchMode: { _ in },
            openInfoMode: {},
            openUptodate: {},
            openSettings: {},
            openHotkeysSettings: {},
            openCheatSheet: {},
            checkForUpdates: {},
            quit: {}
        )
    }
}
