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
    private let appGroup = "group.pavi.Ultron"
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
        guard let container = containerURL() else {
            // Before the App Group entitlement lands this just no-ops.
            return
        }
        // macOS creates the container *path* as soon as the entitlement is
        // granted but doesn't materialise the directory until something
        // writes to it. First write() call on a fresh install lands before
        // the system has created the folder, so `Data.write` hits ENOENT.
        // Create the directory ourselves so the first snapshot lands.
        if !FileManager.default.fileExists(atPath: container.path) {
            try? FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true
            )
        }
        let url = container.appendingPathComponent(filename)
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
        // force the whole bundle to re-render. Kinds here MUST match the
        // `kind:` string each Widget struct declares in the extension target.
        WidgetCenter.shared.reloadTimelines(ofKind: "dk.pavi.ultron.cockpit-mini")
        WidgetCenter.shared.reloadTimelines(ofKind: "dk.pavi.ultron.commute")
        WidgetCenter.shared.reloadTimelines(ofKind: "dk.pavi.ultron.claude-usage")
        #endif
    }

    /// Location of the shared container. Returns nil until the App Group
    /// entitlement is attached to the target — checked at write time so
    /// this file compiles + links regardless of entitlement state.
    private func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}
