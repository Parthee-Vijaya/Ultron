import AppKit
import Foundation
import Observation
import UserNotifications

/// Fires an AI-briefing regeneration at a user-configured time each day.
///
/// Design:
/// - Not timer-per-second; we schedule exactly one Timer for the next fire
///   date, and reschedule after each run. Handles sleep/wake, DST, and
///   timezone changes correctly because we recompute the next date every
///   time.
/// - Observer on `NSWorkspace.didWakeNotification` so a Mac that slept
///   through the scheduled time still fires the briefing on wake (within a
///   grace window) rather than missing the day.
/// - UserNotifications permission requested on first toggle-on. Silent
///   delivery (no sound) — the user is waking up, not being paged.
///
/// Not in this slice:
/// - Multiple schedules (e.g. evening recap). Could be added later by making
///   `schedule` a list.
/// - TTS narration of the briefing. Covered by the existing TTSService; a
///   future flag could wire it here.
@MainActor
@Observable
final class BriefingScheduler {
    /// Mirrors UserDefaults so the Settings UI can bind directly.
    var enabled: Bool {
        didSet { persistEnabled(); reschedule() }
    }
    var hour: Int {
        didSet { persistHour(); reschedule() }
    }
    var minute: Int {
        didSet { persistMinute(); reschedule() }
    }

    private(set) var nextFireDate: Date?
    private(set) var lastFireDate: Date?
    private(set) var lastFireResult: String?  // "ok" / "error: ..." / nil when no run yet

    private var timer: Timer?
    private var wakeObserverToken: NSObjectProtocol?

    /// Closure wired by AppDelegate — runs the actual briefing generation.
    /// Decoupled so the scheduler has no dependency on InfoModeService.
    var onFire: (@MainActor () async -> String?)?

    init() {
        let defaults = UserDefaults.standard
        self.enabled = defaults.bool(forKey: Constants.Defaults.briefingScheduleEnabled)
        self.hour = (defaults.object(forKey: Constants.Defaults.briefingScheduleHour) as? Int) ?? 7
        self.minute = (defaults.object(forKey: Constants.Defaults.briefingScheduleMinute) as? Int) ?? 0

        wakeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    // Singleton-lifetime object (held by AppDelegate for the full app lifetime),
    // so no deinit cleanup is needed — the MainActor isolation would require
    // hopping off-actor anyway and the process is about to exit.

    // MARK: - Public

    func start() {
        reschedule()
    }

    func requestNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings()
        if status.authorizationStatus == .authorized || status.authorizationStatus == .provisional {
            return true
        }
        if status.authorizationStatus == .denied {
            return false
        }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            LoggingService.shared.log("Notification auth failed: \(error)", level: .warning)
            return false
        }
    }

    // MARK: - Scheduling

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        nextFireDate = nil

        guard enabled else { return }

        let now = Date()
        let next = Self.nextFireDate(hour: hour, minute: minute, after: now)
        nextFireDate = next

        let delay = next.timeIntervalSince(now)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fire() }
        }
        // Common modes so the fire isn't delayed by modal dialogs / tracking loops.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func handleWake() {
        // After a sleep, the scheduled Timer may be in the past — reschedule
        // from "now". If the intended fire was within the last 10 minutes
        // while asleep, treat it as missed-today and fire immediately.
        guard enabled, let planned = nextFireDate else { return }
        let now = Date()
        if planned < now && now.timeIntervalSince(planned) < 600 {
            Task { await fire() }
        } else {
            reschedule()
        }
    }

    private func fire() async {
        lastFireDate = Date()
        guard let onFire else {
            lastFireResult = "error: no handler wired"
            reschedule()
            return
        }
        let result = await onFire()
        lastFireResult = result ?? "ok"
        await postNotification(summary: result)
        reschedule()
    }

    private func postNotification(summary: String?) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Ultron morgen-briefing"
        if let summary, !summary.isEmpty, summary != "ok" {
            content.body = String(summary.prefix(240))
        } else {
            content.body = "Ny briefing klar. Åbn Cockpit for at læse den."
        }
        content.sound = nil
        content.userInfo = ["ultron.action": "openCockpit"]

        let request = UNNotificationRequest(
            identifier: "ultron.briefing.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await center.add(request)
    }

    // MARK: - Persistence

    private func persistEnabled() {
        UserDefaults.standard.set(enabled, forKey: Constants.Defaults.briefingScheduleEnabled)
    }
    private func persistHour() {
        UserDefaults.standard.set(hour, forKey: Constants.Defaults.briefingScheduleHour)
    }
    private func persistMinute() {
        UserDefaults.standard.set(minute, forKey: Constants.Defaults.briefingScheduleMinute)
    }

    // MARK: - Date math

    /// Next `hour:minute` strictly after `date`. If today's time already passed,
    /// returns tomorrow's. Uses the user's current calendar + timezone.
    static func nextFireDate(hour: Int, minute: Int, after date: Date) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let candidate = calendar.date(from: components) else {
            return date.addingTimeInterval(86_400)
        }
        if candidate <= date {
            return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86_400)
        }
        return candidate
    }
}
