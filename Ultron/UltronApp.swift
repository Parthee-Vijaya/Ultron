import SwiftUI

@main
struct UltronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // AppDelegate owns its own Settings NSWindow — this empty scene exists only
        // because SwiftUI requires at least one `Scene`.
        Settings { EmptyView() }
    }
}
