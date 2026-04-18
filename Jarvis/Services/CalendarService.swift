import EventKit
import Foundation

/// v1.1.8: next upcoming calendar event surfaced as a Cockpit tile.
/// Permission-gated — the tile shows a "Giv adgang" hint when EventKit auth
/// hasn't been granted, and silently renders nothing when the user denies.
struct CalendarEventSnapshot: Equatable {
    let title: String
    let start: Date
    let end: Date?
    let location: String?
    let calendarName: String

    /// Minutes until the event starts. Negative when the event is already
    /// underway. Nil when the event is "all-day" (too vague for a tile).
    var minutesUntilStart: Int? {
        let seconds = start.timeIntervalSince(Date())
        return Int(seconds / 60)
    }

    var prettyStart: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "da_DK")
        let cal = Calendar(identifier: .gregorian)
        if cal.isDateInToday(start) {
            df.dateFormat = "HH:mm"
            return df.string(from: start)
        }
        if cal.isDateInTomorrow(start) {
            df.dateFormat = "HH:mm"
            return "i morgen \(df.string(from: start))"
        }
        df.dateFormat = "d. MMM HH:mm"
        return df.string(from: start)
    }
}

@MainActor
final class CalendarService {
    enum AccessState: Equatable {
        case notDetermined
        case denied
        case granted
        /// macOS 14+ added `fullAccess` / `writeOnly` — treat writeOnly as
        /// denied for read purposes.
        case writeOnly
    }

    private let store = EKEventStore()

    var accessState: AccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .authorized, .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    /// Request calendar read access. Uses the macOS 14+ fullAccess API when
    /// available, falls back to the legacy one-shot request.
    func requestAccess() async -> AccessState {
        if #available(macOS 14.0, *) {
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                LoggingService.shared.log("Calendar access request failed: \(error)", level: .warning)
            }
        } else {
            await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { _, _ in
                    continuation.resume()
                }
            }
        }
        return accessState
    }

    /// Next upcoming event within the next 7 days. Nil when no events or when
    /// access isn't granted.
    func nextEvent() async -> CalendarEventSnapshot? {
        guard accessState == .granted else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let end = cal.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        // Skip all-day events — a tile for "Dagsrapport (hele dagen)" is
        // noise; the user has a real calendar app for that.
        let upcoming = events
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }

        guard let first = upcoming.first else { return nil }

        return CalendarEventSnapshot(
            title: first.title ?? "(uden titel)",
            start: first.startDate,
            end: first.endDate,
            location: first.location,
            calendarName: first.calendar.title
        )
    }
}
