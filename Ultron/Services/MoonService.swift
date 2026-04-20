import Foundation

/// Pure-Swift moon-phase calculator — no network. Uses a known new-moon
/// reference (2000-01-06 18:14 UTC) and the synodic month (29.53059 days)
/// to compute current phase + illumination + next full moon.
///
/// Accuracy is within a few hours for a glanceable tile, which is plenty.
/// For scientific work swap to Astronomia or similar.
struct MoonSnapshot: Equatable {
    enum Phase: String {
        case newMoon, waxingCrescent, firstQuarter, waxingGibbous
        case fullMoon, waningGibbous, lastQuarter, waningCrescent

        var label: String {
            switch self {
            case .newMoon:         return "Nymåne"
            case .waxingCrescent:  return "Tiltagende månesegl"
            case .firstQuarter:    return "Første kvarter"
            case .waxingGibbous:   return "Tiltagende gibbous"
            case .fullMoon:        return "Fuldmåne"
            case .waningGibbous:   return "Aftagende gibbous"
            case .lastQuarter:     return "Sidste kvarter"
            case .waningCrescent:  return "Aftagende månesegl"
            }
        }

        /// SF Symbol that visually matches the phase.
        var symbol: String {
            switch self {
            case .newMoon:         return "moonphase.new.moon"
            case .waxingCrescent:  return "moonphase.waxing.crescent"
            case .firstQuarter:    return "moonphase.first.quarter"
            case .waxingGibbous:   return "moonphase.waxing.gibbous"
            case .fullMoon:        return "moonphase.full.moon"
            case .waningGibbous:   return "moonphase.waning.gibbous"
            case .lastQuarter:     return "moonphase.last.quarter"
            case .waningCrescent:  return "moonphase.waning.crescent"
            }
        }
    }

    /// Current phase.
    let phase: Phase
    /// Age of the moon in days since the last new moon (0 – ~29.53).
    let ageDays: Double
    /// Illuminated fraction of the lunar disk (0 – 1).
    let illumination: Double
    /// Date of the next full moon.
    let nextFullMoon: Date
    /// Date of the next new moon.
    let nextNewMoon: Date

    var illuminationPercent: Int {
        Int((illumination * 100).rounded())
    }
}

enum MoonService {
    private static let synodicMonthDays: Double = 29.530588853
    private static let knownNewMoon: Date = {
        // 2000-01-06 18:14:00 UTC — conventional reference epoch used across
        // astronomy libraries.
        var components = DateComponents()
        components.year = 2000; components.month = 1; components.day = 6
        components.hour = 18; components.minute = 14
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 947182440)
    }()

    static func current(for date: Date = Date()) -> MoonSnapshot {
        let elapsedDays = date.timeIntervalSince(knownNewMoon) / 86_400
        let age = elapsedDays.truncatingRemainder(dividingBy: synodicMonthDays)
        let normalisedAge = age < 0 ? age + synodicMonthDays : age

        // Illumination via the cosine approximation: illum = (1 − cos(2π·age/T)) / 2
        let phaseAngle = 2 * .pi * normalisedAge / synodicMonthDays
        let illumination = (1 - cos(phaseAngle)) / 2

        let phase = classify(ageDays: normalisedAge)

        let daysToFull: Double
        let halfMonth = synodicMonthDays / 2
        if normalisedAge < halfMonth {
            daysToFull = halfMonth - normalisedAge
        } else {
            daysToFull = synodicMonthDays - normalisedAge + halfMonth
        }
        let daysToNew = synodicMonthDays - normalisedAge

        let nextFullMoon = date.addingTimeInterval(daysToFull * 86_400)
        let nextNewMoon = date.addingTimeInterval(daysToNew * 86_400)

        return MoonSnapshot(
            phase: phase,
            ageDays: normalisedAge,
            illumination: illumination,
            nextFullMoon: nextFullMoon,
            nextNewMoon: nextNewMoon
        )
    }

    /// Partition the 29.53-day cycle into the 8 classic phases.
    private static func classify(ageDays: Double) -> MoonSnapshot.Phase {
        // Each quarter spans synodicMonthDays/4 ≈ 7.38 days; within that
        // each phase is ~3.69 days. Use proportional thresholds.
        let t = ageDays / synodicMonthDays  // 0–1

        switch t {
        case ..<0.03:  return .newMoon
        case ..<0.22:  return .waxingCrescent
        case ..<0.28:  return .firstQuarter
        case ..<0.47:  return .waxingGibbous
        case ..<0.53:  return .fullMoon
        case ..<0.72:  return .waningGibbous
        case ..<0.78:  return .lastQuarter
        case ..<0.97:  return .waningCrescent
        default:       return .newMoon
        }
    }
}
