import CoreLocation
import Foundation

/// A single traffic disruption from Vejdirektoratet's public "big screen"
/// feed — DATEX II v3.2 events flattened into a simpler struct the Cockpit
/// commute tile can render directly.
struct TrafficEvent: Identifiable, Equatable, Hashable, Sendable {
    enum Category: String, Sendable, Equatable, CaseIterable {
        case accident
        case animal
        case obstruction
        case roadCondition
        case publicEvent
        case other

        var label: String {
            switch self {
            case .accident:      return "Uheld"
            case .animal:        return "Dyr på vej"
            case .obstruction:   return "Hindring"
            case .roadCondition: return "Vejforhold"
            case .publicEvent:   return "Begivenhed"
            case .other:         return "Trafikinfo"
            }
        }

        var icon: String {
            switch self {
            case .accident:      return "exclamationmark.triangle.fill"
            case .animal:        return "hare.fill"
            case .obstruction:   return "xmark.octagon.fill"
            case .roadCondition: return "drop.triangle.fill"
            case .publicEvent:   return "flag.fill"
            case .other:         return "exclamationmark.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let header: String
    let plainDescription: String
    let category: Category
    let coordinate: CoordinateLatLon
    let kommune: String
    let beginPeriod: String

    /// Great-circle distance from a reference coordinate in km.
    func distanceKm(from origin: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let b = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return a.distance(from: b) / 1000
    }

    /// Parsed `beginPeriod` as an actual `Date`. The upstream feed carries
    /// strings like `"18-04-2026 kl. 21:45"` (Danish local time); we parse
    /// once per access and cache nothing because the UI only asks on render.
    var beginDate: Date? {
        Self.beginDateFormatter.date(from: beginPeriod)
    }

    /// "for 2t 4m" / "for 12m" / "netop nu" — relative to `now`. Returns
    /// nil when we can't parse `beginPeriod`.
    func timeAgoLabel(now: Date = Date()) -> String? {
        guard let date = beginDate else { return nil }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "netop nu" }
        if seconds < 3_600 { return "for \(seconds / 60)m" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours < 24 { return minutes == 0 ? "for \(hours)t" : "for \(hours)t \(minutes)m" }
        let days = hours / 24
        return "for \(days)d"
    }

    private static let beginDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd-MM-yyyy 'kl.' HH:mm"
        df.locale = Locale(identifier: "da_DK")
        df.timeZone = TimeZone(identifier: "Europe/Copenhagen")
        return df
    }()
}

enum TrafficEventsError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Vejdirektoratet API returnerede ugyldigt svar"
        case .httpError(let code): return "Vejdirektoratet API HTTP \(code)"
        }
    }
}

/// Fetches the public "big-screen-events" feed that powers
/// trafikkort.vejdirektoratet.dk. The feed is updated upstream ~every 10
/// minutes — we cache for 5 min locally to avoid hammering the CDN when the
/// Cockpit refreshes more often.
actor TrafficEventsService {
    private let endpoint = URL(string: "https://storage.googleapis.com/trafikkort-data/geojson/big-screen-events.json")!
    private let cacheTTL: TimeInterval = 5 * 60
    private var cache: (events: [TrafficEvent], fetchedAt: Date)?

    func fetch(force: Bool = false) async throws -> [TrafficEvent] {
        if !force, let c = cache, Date().timeIntervalSince(c.fetchedAt) < cacheTTL {
            return c.events
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrafficEventsError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TrafficEventsError.httpError(http.statusCode)
        }

        // The feed is an array of FeatureCollection-ish objects, one per
        // layer. We flatten + normalise to [TrafficEvent] so callers don't
        // need to know about the layer structure.
        let raw = try JSONDecoder().decode([RawLayer].self, from: data)
        let events = raw.flatMap { $0.features.compactMap(Self.makeEvent) }
        self.cache = (events, Date())
        return events
    }

    // MARK: - Raw decoding

    private struct RawLayer: Decodable {
        let features: [RawFeature]
        let layerName: String?
    }

    private struct RawFeature: Decodable {
        struct Geometry: Decodable {
            let coordinates: [Double]
        }
        struct Properties: Decodable {
            let featureId: String?
            let title: String?
            let header: String?
            let description: String?
            let kommune: String?
            let beginPeriod: String?
            let trafficManType: String?

            enum CodingKeys: String, CodingKey {
                case featureId, title, header, description, kommune, beginPeriod
                case trafficManType = "TrafficMan2_Type"
            }
        }
        let geometry: Geometry
        let properties: Properties
    }

    private static func makeEvent(_ raw: RawFeature) -> TrafficEvent? {
        guard raw.geometry.coordinates.count >= 2 else { return nil }
        let lon = raw.geometry.coordinates[0]
        let lat = raw.geometry.coordinates[1]
        // Sanity-clamp coords: Denmark's bbox is roughly 7.5–15.5°E, 54.5–58°N.
        // The feed occasionally ships events slightly outside (Kattegat markers,
        // border roads) but anything wildly off is bad data and gets dropped.
        guard (-180...180).contains(lon), (-90...90).contains(lat) else { return nil }

        let id = raw.properties.featureId ?? "\(lat),\(lon)-\(raw.properties.title ?? "")"
        let title = raw.properties.title ?? raw.properties.header ?? "Trafikinfo"
        let header = stripHTML(raw.properties.header ?? "")
        let desc = stripHTML(raw.properties.description ?? "")

        return TrafficEvent(
            id: id,
            title: title,
            header: header,
            plainDescription: desc,
            category: category(from: raw.properties.trafficManType),
            coordinate: CoordinateLatLon(latitude: lat, longitude: lon),
            kommune: raw.properties.kommune ?? "",
            beginPeriod: raw.properties.beginPeriod ?? ""
        )
    }

    private static func category(from trafficManType: String?) -> TrafficEvent.Category {
        guard let t = trafficManType else { return .other }
        if t.contains("Accident") { return .accident }
        if t.contains("Animal") { return .animal }
        if t.contains("Obstruction") { return .obstruction }
        if t.contains("RoadConditions") { return .roadCondition }
        if t.contains("PublicEvent") { return .publicEvent }
        return .other
    }

    private static func stripHTML(_ html: String) -> String {
        // The feed embeds titles/descriptions as HTML fragments with <p>
        // paragraphs and HTML-entity-escaped road-sign markers. Collapse to
        // plain text so the tile can render a single line per event cleanly.
        var s = html
            .replacingOccurrences(of: "</p>", with: " · ", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: " · ", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: " · ", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: " · ", options: .caseInsensitive)
        // Strip remaining tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        // Decode common entities.
        let entities: [String: String] = [
            "&lt;": "<", "&gt;": ">", "&amp;": "&", "&quot;": "\"", "&#39;": "'"
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // Strip Vejdirektoratet's `<Nnn>` inline road-sign markers that were
        // escaped as `&lt;65b&gt;` etc. and now survived as "<65b>".
        if let regex = try? NSRegularExpression(pattern: "<[0-9]+[a-z]?>", options: .caseInsensitive) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        // Collapse runs of whitespace + trim leading/trailing separators.
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        if let regex = try? NSRegularExpression(pattern: "\\s+") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim leading/trailing " · " that earlier replacement may have left
        // dangling when the fragment started or ended with a <p>.
        while s.hasPrefix("· ") { s.removeFirst(2) }
        while s.hasSuffix(" ·") { s.removeLast(2) }
        return s
    }
}

// MARK: - Filtering helpers

extension Array where Element == TrafficEvent {
    /// Events within `maxKm` of `origin`, sorted nearest-first.
    func nearby(_ origin: CLLocationCoordinate2D, withinKm maxKm: Double) -> [TrafficEvent] {
        let ranked = self.map { event -> (TrafficEvent, Double) in
            (event, event.distanceKm(from: origin))
        }
        return ranked
            .filter { $0.1 <= maxKm }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    /// Events within `bufferKm` of any point on the given route polyline,
    /// sorted nearest-to-route-first. Route coordinates come from
    /// `CommuteEstimate.routeCoordinates` (already downsampled to ≤200 points).
    func alongRoute(_ route: [CoordinateLatLon], bufferKm: Double) -> [TrafficEvent] {
        guard !route.isEmpty else { return [] }
        let routeLocs = route.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        let ranked = self.compactMap { event -> (TrafficEvent, Double)? in
            let loc = CLLocation(latitude: event.coordinate.latitude,
                                 longitude: event.coordinate.longitude)
            var minDist = Double.infinity
            for r in routeLocs {
                let d = r.distance(from: loc)
                if d < minDist { minDist = d }
            }
            let minKm = minDist / 1000
            guard minKm <= bufferKm else { return nil }
            return (event, minKm)
        }
        return ranked.sorted { $0.1 < $1.1 }.map { $0.0 }
    }
}
