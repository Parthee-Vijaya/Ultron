import Foundation

/// Reads the widget-facing state blob written by the main app. Kept
/// intentionally tiny — the widget extension has severe memory and CPU
/// caps (the process is killed aggressively), so no networking, no
/// async, no expensive decoding happens here.
///
/// If the file is missing, malformed, or writes a future schema version,
/// we return `WidgetSnapshot.placeholder` so every widget still renders
/// its template. The main app's `WidgetStateWriter` is the producer.
enum WidgetSnapshotReader {
    /// App group identifier — must match the entitlement on both the
    /// main app target and the widget extension target.
    static let appGroupID = "group.pavi.Jarvis"
    static let filename = "widget-state.json"

    static func read() -> WidgetSnapshot {
        guard let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return .placeholder
        }
        let fileURL = containerURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder.widget.decode(WidgetSnapshot.self, from: data) else {
            return .placeholder
        }
        // Reject future schema versions — better a stale placeholder than
        // a field-level crash on unexpected shape.
        guard snapshot.version <= WidgetSnapshot.currentVersion else {
            return .placeholder
        }
        return snapshot
    }
}

private extension JSONDecoder {
    static let widget: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
