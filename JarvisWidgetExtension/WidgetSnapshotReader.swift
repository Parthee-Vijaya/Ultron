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
        // Debug diagnostic: write every outcome to a sidecar file so we
        // can see exactly what the widget process observed. `print()` in
        // widget extensions doesn't reliably reach unified logging.
        func trace(_ msg: String) {
            guard let c = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
                return
            }
            let line = "[\(Date())] \(msg)\n"
            let traceURL = c.appendingPathComponent("widget-read.log")
            if let handle = try? FileHandle(forWritingTo: traceURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: traceURL)
            }
        }

        guard let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return .placeholder
        }
        let fileURL = containerURL.appendingPathComponent(filename)
        trace("read attempt from \(fileURL.path)")
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            trace("Data(contentsOf:) threw \(error)")
            return .placeholder
        }
        let snapshot: WidgetSnapshot
        do {
            snapshot = try JSONDecoder.widget.decode(WidgetSnapshot.self, from: data)
        } catch {
            trace("JSON decode threw \(error)")
            return .placeholder
        }
        guard snapshot.version <= WidgetSnapshot.currentVersion else {
            trace("snapshot version \(snapshot.version) > currentVersion \(WidgetSnapshot.currentVersion)")
            return .placeholder
        }
        trace("decoded OK — weather.temp=\(snapshot.weather?.tempC ?? -999) claude.today=\(snapshot.claude?.todayTokens ?? -1)")
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
