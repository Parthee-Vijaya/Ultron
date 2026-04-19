import Foundation

/// Pure-Swift solar day-length math for the Cockpit sun tile. No network — uses
/// the standard sunrise-equation approximation. Accurate to within a few minutes
/// which is more than enough for "dagen er blevet X længere siden solhverv".
enum SolarDateMath {
    /// Approximate daylight hours at a given latitude on a given date using the
    /// standard sunrise-equation approximation.
    ///
    /// - Parameters:
    ///   - latitude: in degrees north
    ///   - date: any calendar date; only day-of-year matters
    ///   - calendar: calendar used to extract the day-of-year; defaults to `.current`
    /// - Returns: daylight in seconds (clamped to `[0, 86_400]`).
    static func daylightSeconds(latitude: Double, date: Date, calendar: Calendar = .current) -> TimeInterval {
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        // Solar declination δ ≈ 23.44° * sin(360° * (284 + N) / 365)
        let declination = 23.44 * sin(.pi * 2 * (284 + dayOfYear) / 365) * .pi / 180
        let lat = latitude * .pi / 180
        // Hour angle at sunrise/sunset: cos(H) = -tan(lat) * tan(decl)
        let cosH = -tan(lat) * tan(declination)
        if cosH >= 1 { return 0 }               // polar night
        if cosH <= -1 { return 86_400 }         // midnight sun
        let H = acos(cosH)                       // radians
        let daylightHours = 2 * H * 180 / .pi / 15   // 15°/hour
        return daylightHours * 3600
    }

    /// Return the most recent solstice before `date` plus its daylight-length at
    /// the user's latitude. Summer solstice ≈ June 21, winter solstice ≈ Dec 21.
    ///
    /// We pick the most recent solstice on or before `date` so the delta reads
    /// naturally ("dagen er … siden …"). In the months right after summer
    /// solstice the delta will be negative (days are shrinking), so the caller
    /// should flip the wording based on the sign.
    static func lastSolstice(before date: Date, latitude: Double, calendar: Calendar = .current) -> (date: Date, daylightSeconds: TimeInterval, isWinter: Bool) {
        let year = calendar.component(.year, from: date)
        let winter = calendar.date(from: DateComponents(year: year - 1, month: 12, day: 21))!
        let summer = calendar.date(from: DateComponents(year: year, month: 6, day: 21))!
        let winter2 = calendar.date(from: DateComponents(year: year, month: 12, day: 21))!

        // Most recent solstice ≤ `date`.
        let candidates = [winter, summer, winter2].filter { $0 <= date }
        let chosen = candidates.last ?? winter
        let isWinter = chosen == winter || chosen == winter2
        let daylight = daylightSeconds(latitude: latitude, date: chosen, calendar: calendar)
        return (chosen, daylight, isWinter)
    }
}
