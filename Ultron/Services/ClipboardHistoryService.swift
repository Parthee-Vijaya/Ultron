import AppKit
import Foundation
import Observation

/// Remembers the last N strings the user copied to the system clipboard.
///
/// Polls `NSPasteboard.changeCount` once per second; on change we read the
/// current plain-text string + push it onto a capped buffer. Binary pasteboard
/// types (images, file URLs) are intentionally skipped — this view is about
/// text recall, not a full pasteboard manager.
///
/// Memory-only by design: clipboard content is often sensitive (passwords,
/// tokens). Not persisted anywhere on disk, gone when Ultron quits.
@MainActor
@Observable
final class ClipboardHistoryService {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let text: String
        let capturedAt: Date
        /// Truncated single-line preview for the list row.
        let preview: String
    }

    /// Cap chosen to keep memory bounded while still covering a normal day.
    static let capacity = 30

    private(set) var entries: [Entry] = []
    var isPaused: Bool = false {
        didSet { persistPause() }
    }

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    init() {
        self.lastChangeCount = pasteboard.changeCount
        self.isPaused = UserDefaults.standard.bool(forKey: Constants.Defaults.clipboardHistoryPaused)
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-copy an entry to the system pasteboard. Also bumps it to the top
    /// of the list so subsequent copy-again workflows find it quickly.
    func recopy(_ entry: Entry) {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        // Push a fresh entry at the top so the list reflects "most recently
        // used" rather than "most recently copied". tick() will swallow the
        // pasteboard change we just made because it matches the top entry.
        entries.removeAll { $0.id == entry.id }
        entries.insert(
            Entry(id: UUID(), text: entry.text, capturedAt: Date(), preview: preview(for: entry.text)),
            at: 0
        )
        trimIfNeeded()
        lastChangeCount = pasteboard.changeCount
    }

    func clearAll() {
        entries.removeAll()
    }

    // MARK: - Private

    private func tick() {
        guard !isPaused else { return }
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        // Only care about plain text. NSPasteboard may hold images/URLs too —
        // skip silently.
        guard let text = pasteboard.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Skip exact duplicates of the most recent entry (user pasted the
        // same thing back).
        if let top = entries.first, top.text == text { return }

        let entry = Entry(id: UUID(), text: text, capturedAt: Date(), preview: preview(for: text))
        entries.insert(entry, at: 0)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        if entries.count > Self.capacity {
            entries = Array(entries.prefix(Self.capacity))
        }
    }

    private func preview(for text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if singleLine.count <= 120 { return singleLine }
        return String(singleLine.prefix(117)) + "…"
    }

    private func persistPause() {
        UserDefaults.standard.set(isPaused, forKey: Constants.Defaults.clipboardHistoryPaused)
    }
}
