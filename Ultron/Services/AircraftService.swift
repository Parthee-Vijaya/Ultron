import CoreLocation
import Foundation

/// Origin or destination airport for a resolved route.
struct AirportInfo: Equatable, Hashable, Sendable {
    let iataCode: String       // 3-letter code, e.g. "CPH"
    let municipality: String   // human-readable city, e.g. "Copenhagen"
}

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
    /// Resolved via `adsbdb.com` (secondary call). `nil` while the lookup
    /// is in flight or when the callsign isn't in the route database (e.g.
    /// private jets, military, test flights).
    var origin: AirportInfo?
    var destination: AirportInfo?

    var altitudeFL: String? {
        guard let ft = altitudeFeet, ft > 0 else { return nil }
        // Flight Level = altitude in hundreds of feet.
        return String(format: "FL%03d", ft / 100)
    }

    var distanceKm: Double { distanceNM * 1.852 }

    /// "CPH → ARN" when the route is resolved. Falls back to the callsign
    /// (or registration) so the row still reads as *something* while the
    /// route lookup is pending or unknown.
    var routeLabel: String {
        if let origin, let destination {
            return "\(origin.iataCode) → \(destination.iataCode)"
        }
        return callsign ?? registration ?? "?"
    }
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
///
/// Routes (origin → destination) come from adsbdb.com (free, no auth).
/// Route info is keyed by callsign and cached for 24 h since a given
/// flight number rarely changes origin/destination within a day.
actor AircraftService {
    private let endpointBase = "https://api.adsb.lol/v2/point"
    private let routeEndpointBase = "https://api.adsbdb.com/v0/callsign"
    private let cacheTTL: TimeInterval = 20
    private let routeCacheTTL: TimeInterval = 24 * 60 * 60
    private var cache: (aircraft: [Aircraft], center: CoordinateLatLon, fetchedAt: Date)?
    private var routeCache: [String: (route: RouteInfo?, fetchedAt: Date)] = [:]

    struct RouteInfo: Equatable, Sendable {
        let origin: AirportInfo
        let destination: AirportInfo
    }

    /// Fetch the aircraft list in a given radius (nautical miles) around a
    /// coordinate. Also resolves origin → destination for the top 6
    /// closest aircraft via adsbdb.com; routes land asynchronously into
    /// the cache so subsequent calls include them.
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
            var aircraft = try await fetchFromUpstream(lat: center.latitude,
                                                       lon: center.longitude,
                                                       radiusNM: radiusNM)
            // Resolve routes for the 6 closest aircraft in parallel. Any
            // that fail stay with nil origin/destination; the UI falls
            // back to the callsign in that case.
            aircraft = await enrichWithRoutes(aircraft, topN: 6)
            cache = (aircraft, key, Date())
            return aircraft
        } catch {
            return cache?.aircraft ?? []
        }
    }

    private func enrichWithRoutes(_ list: [Aircraft], topN: Int) async -> [Aircraft] {
        let targets = list.prefix(topN).compactMap { ac -> (Int, String)? in
            guard let sign = ac.callsign, !sign.isEmpty,
                  let idx = list.firstIndex(of: ac) else { return nil }
            return (idx, sign)
        }
        guard !targets.isEmpty else { return list }

        let routes = await withTaskGroup(of: (Int, RouteInfo?).self) { group in
            for (idx, sign) in targets {
                group.addTask { (idx, await self.routeFor(callsign: sign)) }
            }
            var out: [Int: RouteInfo?] = [:]
            for await (idx, route) in group { out[idx] = route }
            return out
        }

        var enriched = list
        for (idx, route) in routes {
            guard let route else { continue }
            enriched[idx].origin = route.origin
            enriched[idx].destination = route.destination
        }
        return enriched
    }

    private func routeFor(callsign: String) async -> RouteInfo? {
        if let cached = routeCache[callsign],
           Date().timeIntervalSince(cached.fetchedAt) < routeCacheTTL {
            return cached.route
        }
        let route = await fetchRouteFromUpstream(callsign: callsign)
        // Cache both hits and misses so we don't keep hammering adsbdb for
        // unresolvable callsigns (e.g., private jets).
        routeCache[callsign] = (route, Date())
        return route
    }

    private func fetchRouteFromUpstream(callsign: String) async -> RouteInfo? {
        let urlString = "\(routeEndpointBase)/\(callsign)"
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("Ultron/1.4 (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let wrapper = try JSONDecoder().decode(RouteResponse.self, from: data)
            guard let route = wrapper.flightrouteDecoded else { return nil }
            return RouteInfo(
                origin: AirportInfo(iataCode: route.origin.iata_code,
                                    municipality: route.origin.municipality),
                destination: AirportInfo(iataCode: route.destination.iata_code,
                                         municipality: route.destination.municipality)
            )
        } catch {
            return nil
        }
    }

    /// adsbdb returns `{ "response": "unknown callsign" }` as a STRING
    /// when no route is known, or `{ "response": { "flightroute": {...} } }`
    /// on success. So `response` is either a string or a dict — we peek.
    private struct RouteResponse: Decodable {
        let flightrouteDecoded: Flightroute?

        struct Flightroute: Decodable {
            let origin: Airport
            let destination: Airport
        }
        struct Airport: Decodable {
            let iata_code: String
            let municipality: String
        }

        init(from decoder: Decoder) throws {
            struct Wrapper: Decodable {
                let response: ResponseValue
                enum ResponseValue: Decodable {
                    case unknown
                    case route(FlightrouteWrapper)
                    init(from decoder: Decoder) throws {
                        let c = try decoder.singleValueContainer()
                        if let s = try? c.decode(String.self) { _ = s; self = .unknown; return }
                        let w = try c.decode(FlightrouteWrapper.self)
                        self = .route(w)
                    }
                }
                struct FlightrouteWrapper: Decodable {
                    let flightroute: Flightroute
                }
            }
            let w = try Wrapper(from: decoder)
            switch w.response {
            case .unknown:         self.flightrouteDecoded = nil
            case .route(let fw):   self.flightrouteDecoded = fw.flightroute
            }
        }
    }

    private func fetchFromUpstream(lat: Double, lon: Double, radiusNM: Int) async throws -> [Aircraft] {
        let urlString = "\(endpointBase)/\(lat)/\(lon)/\(radiusNM)"
        guard let url = URL(string: urlString) else { throw AircraftServiceError.invalidResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Ultron/1.4 (macOS)", forHTTPHeaderField: "User-Agent")
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
