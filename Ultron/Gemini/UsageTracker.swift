import Foundation
import Observation

@Observable
class UsageTracker {
    struct MonthlyUsage: Codable {
        var month: String
        var flashInputTokens: Int = 0
        var flashOutputTokens: Int = 0
        var proInputTokens: Int = 0
        var proOutputTokens: Int = 0
        var totalCostUSD: Double = 0.0
    }

    private static let flashInputPrice = 0.075
    private static let flashOutputPrice = 0.30
    private static let proInputPrice = 1.25
    private static let proOutputPrice = 5.00

    var currentUsage: MonthlyUsage
    var onCostWarning: ((Double) -> Void)?

    var formattedUsage: String {
        "Usage: $\(String(format: "%.2f", currentUsage.totalCostUSD)) this month"
    }

    private let storageURL: URL
    private var lastWarnedThresholdUSD: Double = 0
    private static let warningThresholdsUSD: [Double] = [1.0, 5.0, 10.0, 25.0, 50.0, 100.0]

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ultron")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storageURL = appSupport.appendingPathComponent("usage.json")
        currentUsage = MonthlyUsage(month: Self.currentMonth())
        loadUsage()
    }

    func trackUsage(model: GeminiModel, inputTokens: Int, outputTokens: Int) {
        checkMonthReset()
        switch model {
        case .flash:
            currentUsage.flashInputTokens += inputTokens
            currentUsage.flashOutputTokens += outputTokens
        case .pro:
            currentUsage.proInputTokens += inputTokens
            currentUsage.proOutputTokens += outputTokens
        }
        recalculateCost()
        saveUsage()
        checkCostWarning()
    }

    private func recalculateCost() {
        let flashInput = Double(currentUsage.flashInputTokens) / 1_000_000.0 * Self.flashInputPrice
        let flashOutput = Double(currentUsage.flashOutputTokens) / 1_000_000.0 * Self.flashOutputPrice
        let proInput = Double(currentUsage.proInputTokens) / 1_000_000.0 * Self.proInputPrice
        let proOutput = Double(currentUsage.proOutputTokens) / 1_000_000.0 * Self.proOutputPrice
        currentUsage.totalCostUSD = flashInput + flashOutput + proInput + proOutput
    }

    private func checkCostWarning() {
        // Fire the warning once per tier crossed — $1, $5, $10, $25, $50, $100.
        // Lower threshold (Constants.costWarningThresholdUSD) is the floor; ignore tiers below it.
        let cost = currentUsage.totalCostUSD
        guard let nextTier = Self.warningThresholdsUSD.first(where: {
            $0 >= Constants.costWarningThresholdUSD && cost >= $0 && lastWarnedThresholdUSD < $0
        }) else { return }
        lastWarnedThresholdUSD = nextTier
        LoggingService.shared.log("Cost warning: monthly usage reached $\(String(format: "%.2f", cost)) (tier $\(nextTier))", level: .warning)
        onCostWarning?(cost)
    }

    private func checkMonthReset() {
        let now = Self.currentMonth()
        if currentUsage.month != now {
            currentUsage = MonthlyUsage(month: now)
            lastWarnedThresholdUSD = 0
            saveUsage()
            LoggingService.shared.log("Usage tracker reset for new month: \(now)")
        }
    }

    private func loadUsage() {
        guard let data = try? Data(contentsOf: storageURL),
              let usage = try? JSONDecoder().decode(MonthlyUsage.self, from: data) else { return }
        if usage.month == Self.currentMonth() {
            currentUsage = usage
        }
    }

    private func saveUsage() {
        guard let data = try? JSONEncoder().encode(currentUsage) else { return }
        try? data.write(to: storageURL)
    }

    private static func currentMonth() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return df.string(from: Date())
    }
}
