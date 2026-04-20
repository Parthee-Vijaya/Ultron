import Foundation

/// A notable Danish calendar day (public holiday or flag day). Used by the
/// Cockpit sun tile's "Næste helligdag" line.
struct DanishHoliday: Identifiable {
    let date: Date
    let name: String
    var id: String { "\(date)-\(name)" }
}

/// Pure-compute list of Danish public holidays + a few flag days. No network.
/// Easter-dependent holidays use Gauss's Easter formula (Gregorian variant).
enum DanishHolidays {
    /// The next notable day strictly after `reference`. Scans the current and
    /// next year so a query in late December still resolves to e.g. Nytårsdag.
    static func next(after reference: Date = Date(), calendar: Calendar = .current) -> DanishHoliday? {
        let year = calendar.component(.year, from: reference)
        let candidates = holidays(for: year, calendar: calendar) + holidays(for: year + 1, calendar: calendar)
        return candidates.first { $0.date > reference }
    }

    /// All Danish notable days for a given calendar year, sorted ascending.
    static func holidays(for year: Int, calendar: Calendar = .current) -> [DanishHoliday] {
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let easter = easterSunday(year: year, calendar: calendar)
        let fixed: [DanishHoliday] = [
            DanishHoliday(date: date(1, 1), name: "Nytårsdag"),
            DanishHoliday(date: calendar.date(byAdding: .day, value: -3, to: easter)!, name: "Skærtorsdag"),
            DanishHoliday(date: calendar.date(byAdding: .day, value: -2, to: easter)!, name: "Langfredag"),
            DanishHoliday(date: easter, name: "Påskedag"),
            DanishHoliday(date: calendar.date(byAdding: .day, value: 1, to: easter)!, name: "2. Påskedag"),
            DanishHoliday(date: calendar.date(byAdding: .day, value: 39, to: easter)!, name: "Kristi Himmelfart"),
            DanishHoliday(date: calendar.date(byAdding: .day, value: 49, to: easter)!, name: "Pinsedag"),
            DanishHoliday(date: calendar.date(byAdding: .day, value: 50, to: easter)!, name: "2. Pinsedag"),
            DanishHoliday(date: date(6, 5), name: "Grundlovsdag"),
            DanishHoliday(date: date(12, 24), name: "Juleaftensdag"),
            DanishHoliday(date: date(12, 25), name: "Juledag"),
            DanishHoliday(date: date(12, 26), name: "2. Juledag"),
            DanishHoliday(date: date(12, 31), name: "Nytårsaften")
        ]
        return fixed.sorted { $0.date < $1.date }
    }

    /// Gauss's Easter formula (Gregorian). Returns Easter Sunday at the
    /// calendar's start-of-day.
    private static func easterSunday(year: Int, calendar: Calendar) -> Date {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
