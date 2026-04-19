import CoreLocation
import Foundation

/// A single aircraft currently tracked by adsb.lol within the query radius.
///
/// The upstream feed already computes distance + bearing from the query
/// point, so we just pass those through instead of re-deriving from lat/lon.
/// Fields that are optional upstream (callsign, registration, type) fall
/// back to sensible placeholders in the UI rather than dropping the row.
struct Aircraft: Identifiable, Sendable, Equatable, Hashable {
    let id: String                 // ICAO24 hex — stable across snapshots
    let callsign: String?          // e.g. "SAS1752" (upstream pads with spaces → trimmed)
    let registration: String?
    let aircraftType: String?      // ICAO type code, e.g. "A359"
    let altitudeFeet: Int?         // nil if "ground" or missing
    let onGround: Bool
    let headingDeg: Double?        // 0–360, nil when unknown
    let groundSpeedKt: Double?
    let coordinate: CoordinateLatLon
    let distanceNM: Double         // from the query point
    let bearingDeg: Double         // where the aircraft is relative to user

    var altitudeFL: String? {
        guard let ft = altitudeFeet, ft > 0 else { return nil }
        // Flight Level = altitude in hundreds of feet.
        return String(format: "FL%03d", ft / 100)
    }

    var distanceKm: Double { distanceNM * 1.852 }
}

enum AircraftServiceError: Error {
    case invalidResponse
    case httpError(Int)
}

/// Fetches aircraft near a user-supplied coordinate from the community
/// adsb.lol mirror of the ADS-B Exchange data. No auth required;
/// community-run but generous limits (~1 req/sec anonymous). Cached for
/// 20 s so the view can poll at 30 s without double-fetching on SwiftUI
/// state churn.
actor AircraftService {
    private let endpointBase = "https://api.adsb.lol/v2/point"
    private let cacheTTL: TimeInterval = 20
    private var cache: (aircraft: [Aircraft], center: CoordinateLatLon, fetchedAt: Date)?

    /// Fetch the aircraft list in a given radius (nautical miles) around a
    /// coordinate. If we've cached a recent result for roughly the same
    /// center point we return it directly. Failures return an empty array
    /// — the Fly tile hides rather than showing an error state.
    func fetch(near center: CLLocationCoordinate2D, radiusNM: Int = 50, force: Bool = false) async -> [Aircraft] {
        let key = CoordinateLatLon(center)
        if !force,
           let c = cache,
           Date().timeIntervalSince(c.fetchedAt) < cacheTTL,
           abs(c.center.latitude - key.latitude) < 0.05,
           abs(c.center.longitude - key.longitude) < 0.05 {
            return c.aircraft
        }
        do {
            let aircraft = try await fetchFromUpstream(lat: center.latitude,
                                                       lon: center.longitude,
                                                       radiusNM: radiusNM)
            cache = (aircraft, key, Date())
            return aircraft
        } catch {
            return cache?.aircraft ?? []
        }
    }

    private func fetchFromUpstream(lat: Double, lon: Double, radiusNM: Int) async throws -> [Aircraft] {
        let urlString = "\(endpointBase)/\(lat)/\(lon)/\(radiusNM)"
        guard let url = URL(string: urlString) else { throw AircraftServiceError.invalidResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Jarvis/1.4 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AircraftServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AircraftServiceError.httpError(http.statusCode) }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.ac.compactMap { Self.makeAircraft(from: $0) }
            .sorted { $0.distanceNM < $1.distanceNM }
    }

    // MARK: - Raw decoding

    /// adsb.lol returns `{ "ac": [ ...state vectors... ], "ctime": ..., "msg": ... }`.
    private struct Envelope: Decodable {
        let ac: [RawAircraft]
    }

    private struct RawAircraft: Decodable {
        let hex: String?
        let flight: String?
        let r: String?
        let t: String?
        let alt_baro: AltitudeValue?
        let track: Double?
        let gs: Double?
        let lat: Double?
        let lon: Double?
        let dst: Double?
        let dir: Double?
    }

    /// `alt_baro` can be either an integer (feet) or the literal string
    /// "ground" when the aircraft is on the runway. Decode both.
    private enum AltitudeValue: Decodable {
        case feet(Int)
        case ground

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .feet(n); return }
            if let s = try? c.decode(String.self), s.lowercased() == "ground" {
                self = .ground; return
            }
            if let d = try? c.decode(Double.self) { self = .feet(Int(d)); return }
            throw DecodingError.typeMismatch(AltitudeValue.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "unexpected alt_baro shape"))
        }
    }

    private static func makeAircraft(from raw: RawAircraft) -> Aircraft? {
        guard let hex = raw.hex,
              let lat = raw.lat, let lon = raw.lon,
              let dst = raw.dst, let dir = raw.dir
        else { return nil }

        let (altFeet, onGround): (Int?, Bool)
        switch raw.alt_baro {
        case .feet(let n): (altFeet, onGround) = (n, false)
        case .ground:      (altFeet, onGround) = (nil, true)
        case .none:        (altFeet, onGround) = (nil, false)
        }

        let callsign = raw.flight?.trimmingCharacters(in: .whitespacesAndNewlines)

        return Aircraft(
            id: hex,
            callsign: (callsign?.isEmpty == false) ? callsign : nil,
            registration: raw.r,
            aircraftType: raw.t,
            altitudeFeet: altFeet,
            onGround: onGround,
            headingDeg: raw.track,
            groundSpeedKt: raw.gs,
            coordinate: CoordinateLatLon(latitude: lat, longitude: lon),
            distanceNM: dst,
            bearingDeg: dir
        )
    }
}

// MARK: - Compass utility (shared between Fly + Himmel tiles)

/// Map a bearing in degrees (0–360) to an 8-point compass label.
enum Compass {
    static func label(for degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let bucket = Int((normalized / 45.0).rounded()) % 8
        return ["N", "NØ", "Ø", "SØ", "S", "SV", "V", "NV"][bucket]
    }
}
