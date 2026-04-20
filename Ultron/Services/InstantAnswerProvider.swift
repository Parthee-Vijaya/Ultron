import Foundation

/// Pattern-matches trivial Q&A queries that Ultron already has the answer to
/// locally — time, date, IP address, battery, hostname, WiFi, weather — and
/// returns a ready Danish/English response without calling Gemini or Claude.
///
/// Intended as a preflight in `ChatCommandRouter.runText`: if `match(query:)`
/// returns a non-nil string, deliver it as the assistant reply immediately.
/// Fall through to the normal AI call otherwise.
///
/// Why an actor: `InfoModeService` is `@MainActor @Observable` and exposes
/// its snapshots as properties. Reading those from a non-main actor needs
/// `await MainActor.run`, so `match(query:)` is marked `async` and routes
/// through the main actor when it needs a snapshot.
actor InstantAnswerProvider {
    private let infoModeService: InfoModeService

    init(infoModeService: InfoModeService) {
        self.infoModeService = infoModeService
    }

    /// Try to answer `query` locally. Returns nil when no pattern matches —
    /// caller should proceed to the AI path. Pattern matching is
    /// case-insensitive, diacritics-folded, and whitespace-trimmed.
    func match(query rawQuery: String) async -> String? {
        let query = Self.normalise(rawQuery)
        guard !query.isEmpty else { return nil }

        if Self.matchesTime(query) {
            return Self.formattedTime()
        }
        if Self.matchesDate(query) {
            return Self.formattedDate()
        }
        if Self.matchesIP(query) {
            return await matchIP()
        }
        if Self.matchesBattery(query) {
            return await matchBattery()
        }
        if Self.matchesHostname(query) {
            return await matchHostname()
        }
        if Self.matchesWiFi(query) {
            return await matchWiFi()
        }
        if Self.matchesWeather(query) {
            return await matchWeather()
        }
        return nil
    }

    // MARK: - Normaliser

    private static func normalise(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "da_DK"))
            .lowercased()
    }

    // MARK: - Time / Date

    private static func matchesTime(_ q: String) -> Bool {
        ["hvad er klokken", "hvad tid er det", "klokken nu", "tiden lige nu",
         "what time is it", "current time"].contains { q.contains($0) }
    }

    private static func matchesDate(_ q: String) -> Bool {
        ["hvilken dag er det i dag", "hvad er datoen", "hvilken dato er det",
         "todays date", "what is the date", "what day is it"].contains { q.contains($0) }
    }

    private static func formattedTime() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "da_DK")
        df.dateStyle = .none
        df.timeStyle = .short
        return "Klokken er \(df.string(from: Date()))."
    }

    private static func formattedDate() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "da_DK")
        df.dateStyle = .full
        df.timeStyle = .none
        return "I dag er \(df.string(from: Date()))."
    }

    // MARK: - IP

    private static func matchesIP(_ q: String) -> Bool {
        ["min ip", "hvad er min ip", "ip-adresse", "my ip", "what is my ip"]
            .contains { q.contains($0) }
    }

    private func matchIP() async -> String? {
        let ip = await MainActor.run { infoModeService.systemInfo.localIP }
        guard let ip else { return "Jeg kan ikke finde din IP-adresse lige nu." }
        return "Din lokale IP-adresse er \(ip)."
    }

    // MARK: - Battery

    private static func matchesBattery(_ q: String) -> Bool {
        ["batteri", "batteristatus", "hvor meget strom", "battery level", "battery percent"]
            .contains { q.contains($0) }
    }

    private func matchBattery() async -> String? {
        let info = await MainActor.run { infoModeService.systemInfo }
        guard let pct = info.batteryPercent else {
            return "Jeg kan ikke læse batteristatus på denne Mac (måske en desktop?)."
        }
        var parts = ["Batteriet er på \(pct) %"]
        if let state = info.batteryState { parts.append(state) }
        if let remaining = info.batteryTimeRemaining { parts.append(remaining) }
        return parts.joined(separator: " — ") + "."
    }

    // MARK: - Hostname

    private static func matchesHostname(_ q: String) -> Bool {
        ["hostname", "mit hostname", "computer navn", "computers navn"]
            .contains { q.contains($0) }
    }

    private func matchHostname() async -> String? {
        let host = await MainActor.run { infoModeService.systemInfo.hostname }
        guard let host else { return "Jeg kan ikke læse hostname lige nu." }
        return "Din Mac hedder \(host)."
    }

    // MARK: - WiFi

    private static func matchesWiFi(_ q: String) -> Bool {
        ["wifi", "hvilken wifi", "wifi-netvaerk", "hvad hedder wifi", "ssid"]
            .contains { q.contains($0) }
    }

    private func matchWiFi() async -> String? {
        let wifi = await MainActor.run { infoModeService.systemInfo.wifi }
        guard let wifi, let ssid = wifi.ssid, !ssid.isEmpty else {
            return "Jeg kan ikke se dit nuværende WiFi-netværk."
        }
        var parts = [ssid]
        if let rssi = wifi.rssi {
            parts.append("\(rssi) dBm · \(wifi.qualityLabel)")
        }
        return "Du er forbundet til " + parts.joined(separator: " · ") + "."
    }

    // MARK: - Weather (uses cached Info-mode snapshot)

    private static func matchesWeather(_ q: String) -> Bool {
        ["hvordan er vejret", "hvad er vejret", "vejret lige nu", "vejret nu",
         "current weather", "whats the weather"].contains { q.contains($0) }
    }

    private func matchWeather() async -> String? {
        let weather = await MainActor.run { infoModeService.weather }
        guard let weather else { return nil }  // fall through to Gemini with live search
        let temp = Int(weather.current.temperature.rounded())
        let code = WeatherCode.label(for: weather.current.weatherCode).lowercased()
        return "Lokalt vejr i \(weather.locationLabel): \(temp)°C, \(code)."
    }
}
