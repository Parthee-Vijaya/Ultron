import Foundation

/// v1.4 Fase 4 (Widgets) — shared data schema written by the main app and
/// read by the future widget extension. Lives in the main target for now;
/// when the widget extension target lands (manual `Xcode → File → New →
/// Target → Widget Extension` step per the widgets plan), this file gets
/// target-membership checked on both so the extension reads the same Codable.
///
/// The file is persisted inside the app group container at
/// `widget-state.json` and versioned so we can evolve fields safely.
/// Flat structure: one optional sub-object per widget data need. Any field
/// can be nil — a failed data fetch never nukes the whole file.
struct WidgetSnapshot: Codable, Sendable {
    /// Bump when we make a breaking schema change. Reader logs + ignores
    /// unknown versions rather than crashing.
    static let currentVersion: Int = 1

    let version: Int
    let generatedAt: Date
    var weather: Weather?
    var nextEvent: Event?
    var claude: Claude?
    var commute: Commute?
    var briefing: Briefing?

    // MARK: - Tiles

    struct Weather: Codable, Sendable {
        let locationLabel: String
        let tempC: Double
        let conditionSymbol: String   // SF Symbol name
        let highC: Double?
        let lowC: Double?
    }

    struct Event: Codable, Sendable {
        let title: String
        let startAt: Date
        let location: String?
    }

    struct Claude: Codable, Sendable {
        let todayTokens: Int
        let weeklyTrendPct: Double
        let topProject: String?
    }

    struct Commute: Codable, Sendable {
        let destinationLabel: String
        let durationMinutes: Int
        let trafficDelta: Int          // minutes delta vs. baseline; negative = faster
        let arrivalAt: Date?
    }

    struct Briefing: Codable, Sendable {
        let headlines: [Headline]
        struct Headline: Codable, Sendable {
            let source: String         // "dr", "politiken", …
            let title: String
            let url: String
        }
    }

    // MARK: - Placeholder / preview seed

    static let placeholder = WidgetSnapshot(
        version: currentVersion,
        generatedAt: Date(),
        weather: Weather(locationLabel: "—", tempC: 0, conditionSymbol: "sun.max", highC: nil, lowC: nil),
        nextEvent: nil,
        claude: nil,
        commute: nil,
        briefing: Briefing(headlines: [])
    )
}
