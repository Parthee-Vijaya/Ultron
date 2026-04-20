import AppKit
import Foundation
import Observation

/// Observes system-level "quiet" signals (screen locked, display asleep) so
/// Ultron can suppress the HUD when the user isn't actively at the Mac.
/// Full macOS "Focus" mode detection requires private APIs or the MDM
/// pathway; this observer handles the reliably-public signals and leaves
/// the harder ones for a future commit.
///
/// Current signals:
///  - `NSWorkspace.screensDidSleepNotification` / `…didWakeNotification`
///  - Distributed notification `com.apple.screenIsLocked` / `…screenIsUnlocked`
///
/// Consumer pattern:
/// ```swift
/// if !focusObserver.isQuiet { hudController.showRecording() }
/// ```
@MainActor
@Observable
final class FocusModeObserver {
    /// True when the user appears to be away or in a do-not-interrupt state.
    /// HUD-opening code should treat this as a gentle suggestion — the user
    /// can still invoke Ultron via explicit action; this only stops
    /// unsolicited HUD presentations (auto-close timers, wake-word, etc.).
    private(set) var isQuiet: Bool = false

    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isQuiet = true }
            }
        )
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isQuiet = false }
            }
        )

        // Screen lock/unlock comes through the distributed notification
        // centre, not the workspace centre. Apple hasn't blessed these
        // constants as public API but they've been stable for a decade +
        // used widely in third-party menu bar apps.
        let distCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isQuiet = true }
            }
        )
        distributedObservers.append(
            distCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isQuiet = false }
            }
        )
    }

    deinit {
        // MainActor-bound `self.observers` can't be torn down from a
        // nonisolated deinit — the notification centre removes its weak
        // references lazily when the receiver vanishes. Leaving both arrays
        // alone is safe: ownership is process-lifetime anyway (the app
        // delegate holds the single instance).
    }
}
