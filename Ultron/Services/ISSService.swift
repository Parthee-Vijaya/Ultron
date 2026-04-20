import CoreLocation
import Foundation

/// Current-position snapshot of the ISS from the free `wheretheiss.at` API.
///
/// We deliberately stay with "where is it right now" rather than pass
/// predictions — pass prediction needs SGP4 propagation + TLE parsing,
/// which is a bigger rock. A live position already reads as a small
/// delight ("Over Stillehavet, 416 km oppe").
struct ISSPosition: Equatable, Sendable {
    let latitude: Double           // subpoint latitude
    let longitude: Double          // subpoint longitude
    let altitudeKm: Double
    let velocityKmh: Double
    let visibility: String         // "daylight" / "eclipsed"

    /// Great-circle distance in km from a reference coordinate to the ISS
    /// ground-track sub-point. Good enough for "is it near me" — the
    /// actual slant range to the spacecraft at ~420 km orbit adds another
    /// √(d² + 420²) but callers typically want "is it overhead-ish".
    func distanceKmFrom(_ coord: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let b = CLLocation(latitude: latitude, longitude: longitude)
        return a.distance(from: b) / 1000
    }
}

enum ISSServiceError: Error {
    case invalidResponse
    case httpError(Int)
}

/// Fetches the ISS current subpoint. Cached 30 s because the satellite
/// moves ~8 km/s — keeping a 30 s old value is fine for a Cockpit glance.
actor ISSService {
    private let endpoint = URL(string: "https://api.wheretheiss.at/v1/satellites/25544")!
    private let cacheTTL: TimeInterval = 30
    private var cache: (position: ISSPosition, fetchedAt: Date)?

    func fetch(force: Bool = false) async -> ISSPosition? {
        if !force, let c = cache, Date().timeIntervalSince(c.fetchedAt) < cacheTTL {
            return c.position
        }
        do {
            var req = URLRequest(url: endpoint)
            req.timeoutInterval = 8
            req.setValue("Ultron/1.4 (macOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw ISSServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw ISSServiceError.httpError(http.statusCode) }
            let raw = try JSONDecoder().decode(RawPosition.self, from: data)
            let pos = ISSPosition(
                latitude: raw.latitude,
                longitude: raw.longitude,
                altitudeKm: raw.altitude,
                velocityKmh: raw.velocity,
                visibility: raw.visibility ?? "unknown"
            )
            cache = (pos, Date())
            return pos
        } catch {
            return cache?.position
        }
    }

    private struct RawPosition: Decodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double           // km
        let velocity: Double           // km/h (wheretheiss docs say km/h — verify: it says "units":"kilometers")
        let visibility: String?
    }
}
