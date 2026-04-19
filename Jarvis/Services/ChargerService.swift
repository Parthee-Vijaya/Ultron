import CoreLocation
import Foundation

/// Which charging network a given station belongs to. Drives both the data
/// source (each network uses a different public endpoint) and the map-marker
/// styling.
enum ChargerNetwork: String, Sendable, Equatable, CaseIterable {
    case clever
    case teslaSupercharger

    var displayName: String {
        switch self {
        case .clever:            return "Clever"
        case .teslaSupercharger: return "Tesla Supercharger"
        }
    }

    /// Hex color for map markers. Consumed by whatever renders the overlay.
    var mapMarkerColor: String {
        switch self {
        case .clever:            return "#0F6FFF"  // Clever blue
        case .teslaSupercharger: return "#E82127"  // Tesla red
        }
    }
}

/// A single charging location, normalised across data sources so the map
/// overlay doesn't need to know which network it came from.
struct ChargerLocation: Identifiable, Equatable, Hashable, Sendable {
    let id: String                 // "network.rawId" — stable + collision-free across networks
    let title: String
    let town: String
    let network: ChargerNetwork
    let coordinate: CoordinateLatLon
    let maxPowerKW: Double?
    let connectionCount: Int
}

enum ChargerServiceError: Error {
    case invalidResponse
    case httpError(Int)
}

/// Fetches EV charger locations for Tesla Superchargers + (optionally) Clever.
///
/// **Why two sources?** We tried Open Charge Map as a unified source, but
/// anonymous access was blocked with HTTP 403 on 2026-04-19 — OCM now
/// requires an API key for `/v3/poi` and `/v3/referencedata`. Tesla is
/// served from community-maintained `supercharge.info` (no auth, very
/// stable — the same source the Supercharger map on many third-party
/// dashboards uses). Clever is behind Cloudflare Turnstile on their own
/// site and a paid OCM key, so we fall back to an empty list unless the
/// user provides an OCM API key via `ChargerService.ocmApiKey`.
actor ChargerService {
    /// Optional OCM API key. If set, Clever fetch uses the OCM `/v3/poi`
    /// endpoint with `operatorid=3498`. Leave `nil` to ship without Clever.
    static var ocmApiKey: String? {
        get { UserDefaults.standard.string(forKey: "chargers.ocmApiKey") }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: "chargers.ocmApiKey")
            } else {
                UserDefaults.standard.removeObject(forKey: "chargers.ocmApiKey")
            }
        }
    }

    private var cache: [ChargerNetwork: (locations: [ChargerLocation], fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 24 * 60 * 60  // 24 h

    func fetch(_ network: ChargerNetwork, force: Bool = false) async -> [ChargerLocation] {
        if !force, let c = cache[network], Date().timeIntervalSince(c.fetchedAt) < cacheTTL {
            return c.locations
        }
        do {
            let locations: [ChargerLocation]
            switch network {
            case .teslaSupercharger: locations = try await fetchTeslaFromSuperchargeInfo()
            case .clever:            locations = try await fetchCleverFromOCM()
            }
            cache[network] = (locations, Date())
            return locations
        } catch {
            return cache[network]?.locations ?? []
        }
    }

    /// All networks in parallel. Errors per-network degrade silently to
    /// empty, so partial failures never hide a working one.
    func fetchAll(force: Bool = false) async -> [ChargerLocation] {
        await withTaskGroup(of: [ChargerLocation].self) { group in
            for network in ChargerNetwork.allCases {
                group.addTask { await self.fetch(network, force: force) }
            }
            var all: [ChargerLocation] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
    }

    // MARK: - supercharge.info (Tesla)

    private func fetchTeslaFromSuperchargeInfo() async throws -> [ChargerLocation] {
        // Community-maintained global list. Denmark bucket is ~50 sites in
        // April 2026 (~15 live, rest planned/permit). We keep only sites with
        // coordinates — planned sites without precise gps are filtered out.
        let url = URL(string: "https://supercharge.info/service/supercharge/allSites")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Jarvis/1.4 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ChargerServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ChargerServiceError.httpError(http.statusCode) }

        let sites = try JSONDecoder().decode([SuperchargeSite].self, from: data)
        return sites.compactMap { site -> ChargerLocation? in
            guard site.address?.country == "Denmark" else { return nil }
            guard let gps = site.gps, let lat = gps.latitude, let lon = gps.longitude else { return nil }
            // Skip status=PLAN with placeholder coords (0,0) — the feed has a
            // few of those for pre-permit sites.
            guard lat != 0, lon != 0 else { return nil }
            return ChargerLocation(
                id: "tesla.\(site.id ?? site.locationId ?? UUID().uuidString)",
                title: site.name ?? "Supercharger",
                town: site.address?.city ?? "",
                network: .teslaSupercharger,
                coordinate: CoordinateLatLon(latitude: lat, longitude: lon),
                maxPowerKW: site.powerKilowatt,
                connectionCount: site.stallCount ?? 0
            )
        }
    }

    private struct SuperchargeSite: Decodable {
        let id: Int?
        let locationId: String?
        let name: String?
        let address: Address?
        let gps: GPS?
        let powerKilowatt: Double?
        let stallCount: Int?
        struct Address: Decodable {
            let city: String?
            let country: String?
        }
        struct GPS: Decodable {
            let latitude: Double?
            let longitude: Double?
        }
    }

    // MARK: - Open Charge Map (Clever, optional)

    private func fetchCleverFromOCM() async throws -> [ChargerLocation] {
        guard let key = Self.ocmApiKey, !key.isEmpty else {
            // No key configured — skip quietly so the Hjem tile just doesn't
            // show Clever pins. Settings UI can prompt later.
            return []
        }
        var comps = URLComponents(string: "https://api.openchargemap.io/v3/poi")!
        comps.queryItems = [
            URLQueryItem(name: "countrycode", value: "DK"),
            URLQueryItem(name: "operatorid", value: "3498"),  // Clever A/S
            URLQueryItem(name: "maxresults", value: "500"),
            URLQueryItem(name: "verbose", value: "false"),
            URLQueryItem(name: "compact", value: "true"),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = comps.url else { throw ChargerServiceError.invalidResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ChargerServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ChargerServiceError.httpError(http.statusCode) }

        let pois = try JSONDecoder().decode([OCMPOI].self, from: data)
        return pois.compactMap { poi -> ChargerLocation? in
            guard let ai = poi.addressInfo,
                  let lat = ai.latitude, let lon = ai.longitude else { return nil }
            let maxKW = (poi.connections ?? []).compactMap { $0.powerKW }.max()
            let pid = poi.id.map(String.init) ?? UUID().uuidString
            return ChargerLocation(
                id: "clever.\(pid)",
                title: ai.title ?? "Clever",
                town: ai.town ?? "",
                network: .clever,
                coordinate: CoordinateLatLon(latitude: lat, longitude: lon),
                maxPowerKW: maxKW,
                connectionCount: poi.connections?.count ?? 0
            )
        }
    }

    private struct OCMPOI: Decodable {
        let id: Int?
        let addressInfo: OCMAddress?
        let connections: [OCMConnection]?
        enum CodingKeys: String, CodingKey {
            case id = "ID", addressInfo = "AddressInfo", connections = "Connections"
        }
    }
    private struct OCMAddress: Decodable {
        let title: String?
        let town: String?
        let latitude: Double?
        let longitude: Double?
        enum CodingKeys: String, CodingKey {
            case title = "Title", town = "Town", latitude = "Latitude", longitude = "Longitude"
        }
    }
    private struct OCMConnection: Decodable {
        let powerKW: Double?
        enum CodingKeys: String, CodingKey { case powerKW = "PowerKW" }
    }
}
