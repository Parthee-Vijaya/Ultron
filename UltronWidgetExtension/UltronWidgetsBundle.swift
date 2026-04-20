import SwiftUI
import WidgetKit

/// Entry point for the Ultron widget extension. Lists every widget kind
/// the extension provides. The main app writes a shared
/// `WidgetSnapshot` JSON to the app group container; each widget timeline
/// provider reads that file and decodes the slice it needs.
///
/// See `README.md` + `docs/widgets-setup.md` for the one-time Xcode
/// steps (create the Widget Extension target, enable the shared app
/// group, add all files in `UltronWidgetExtension/` to the target).
@main
struct UltronWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CockpitMiniWidget()
        CommuteWidget()
        ClaudeUsageWidget()
    }
}
