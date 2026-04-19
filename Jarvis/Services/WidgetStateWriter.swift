import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// v1.4 Fase 4 (Widgets) — writes a `WidgetSnapshot` to the shared App Group
/// container so the widget extension can read it without a cross-process
/// messaging channel. Called after every `InfoModeService.refresh()` success.
///
/// Widget extension isn't wired to the Xcode project yet — this writer is
/// the preparation layer so when the extension target is added (Xcode GUI
/// step per the widgets plan), flipping the consumer on is a one-line task.
/// Until then the JSON just sits in the container; harmless.
@MainActor
final class WidgetStateWriter {
    static let shared = WidgetStateWriter()

    /// App Group ID — matches the entitlement that will be added to both
    /// the main app and the widget extension when the target lands.
    private let appGroup = "group.pavi.Jarvis"
    private let filename = "widget-state.json"

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private init() {}

    /// Persist the snapshot + reload any widget timelines so the new data
    /// shows up on the desktop immediately. Both operations are best-effort
    /// — a missing container (app group not configured yet) is logged but
    /// never thrown.
    func write(_ snapshot: WidgetSnapshot) {
        guard let url = containerURL()?.appendingPathComponent(filename) else {
            // Before the App Group entitlement lands this just no-ops.
            return
        }
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            LoggingService.shared.log("Widget state written (\(data.count) bytes, \(url.lastPathComponent))")
        } catch {
            LoggingService.shared.log("Widget state write failed: \(error)", level: .warning)
            return
        }

        #if canImport(WidgetKit)
        // Each widget kind reloads separately so a weather-only update doesn't
        // force the briefing widget to re-render. Kinds here must match the
        // `kind:` string each Widget struct declares once the extension exists.
        WidgetCenter.shared.reloadTimelines(ofKind: "CockpitWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "CommuteWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "BriefingWidget")
        #endif
    }

    /// Location of the shared container. Returns nil until the App Group
    /// entitlement is attached to the target — checked at write time so
    /// this file compiles + links regardless of entitlement state.
    private func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}
