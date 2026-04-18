import CoreLocation
import Foundation
import MapKit

/// Reverse-distance commute estimate + Tesla Model 3 AWD 2025 energy usage.
struct CommuteEstimate: Equatable {
    enum TrafficCondition: String {
        case free      // < 2 min delay vs free-flow
        case light     // 2–8 min
        case heavy     // 8–20 min
        case severe    // > 20 min
        case unknown   // baseline missing

        var label: String {
            switch self {
            case .free:    return "Fri bane"
            case .light:   return "Let trafik"
            case .heavy:   return "Tæt trafik"
            case .severe:  return "Meget tæt"
            case .unknown: return ""
            }
        }
    }

    /// Driving time as Apple Maps estimates it, accounting for live traffic.
    let expectedTravelTime: TimeInterval
    /// Free-flow baseline travel time — same route, but requested for a typical
    /// off-peak slot (next Sunday ~03:00 local). `nil` when the baseline call fails.
    let baselineTravelTime: TimeInterval?
    /// Driving distance in meters.
    let distanceMeters: Double
    /// Human-readable from/to labels.
    let fromLabel: String
    let toLabel: String
    /// Tesla Model 3 AWD 2025 energy needed in kWh.
    let teslaKWh: Double

    var distanceKm: Double { distanceMeters / 1000 }

    /// Extra time over free-flow baseline. 0 when baseline is absent or route
    /// is actually faster than the off-peak baseline (negative deltas pinned).
    var trafficDelay: TimeInterval {
        guard let baseline = baselineTravelTime else { return 0 }
        return max(0, expectedTravelTime - baseline)
    }

    var trafficCondition: TrafficCondition {
        guard baselineTravelTime != nil else { return .unknown }
        let minutes = trafficDelay / 60
        if minutes < 2 { return .free }
        if minutes < 8 { return .light }
        if minutes < 20 { return .heavy }
        return .severe
    }

    var prettyTravelTime: String {
        let minutes = Int((expectedTravelTime / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)t \(minutes % 60)m"
    }

    var prettyDistance: String {
        if distanceMeters < 1000 { return "\(Int(distanceMeters)) m" }
        return String(format: "%.1f km", distanceKm)
    }

    /// "+6 min trafik" or empty string when no delay / unknown baseline.
    var prettyTrafficDelay: String {
        guard baselineTravelTime != nil else { return "" }
        let minutes = Int((trafficDelay / 60).rounded())
        if minutes <= 0 { return "fri bane" }
        return "+\(minutes) min trafik"
    }
}

enum CommuteError: LocalizedError {
    case missingHomeAddress
    case missingCurrentLocation
    case geocodeFailed(String)
    case routeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingHomeAddress:
            return "Sæt din hjemadresse i Settings → General for at beregne køretid."
        case .missingCurrentLocation:
            return "Kunne ikke bestemme din nuværende lokation."
        case .geocodeFailed(let address):
            return "Kunne ikke finde adressen '\(address)' på kortet."
        case .routeFailed(let error):
            return "Ruteberegning fejlede: \(error.localizedDescription)"
        }
    }
}

final class CommuteService {
    /// Tesla Model 3 Long Range AWD 2025 — mixed real-world consumption baseline.
    /// EPA rates it at roughly 4.0 mi/kWh (155 Wh/km); real-world mixed driving
    /// tends to be 170–200 Wh/km depending on temperature and speed. 180 Wh/km is
    /// a defensible middle estimate. Cold-weather + highway corrections are a
    /// future refinement (log them here, then add a settings toggle).
    static let teslaModel3AWD2025Efficiency: Double = 0.180  // kWh per km

    func estimate(from origin: CLLocationCoordinate2D, originLabel: String, toAddress address: String) async throws -> CommuteEstimate {
        // 1) Geocode the home address → coordinate.
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(address)
        } catch {
            throw CommuteError.geocodeFailed(address)
        }
        guard let destination = placemarks.first?.location?.coordinate else {
            throw CommuteError.geocodeFailed(address)
        }
        let toLabel = placemarks.first?.locality ?? placemarks.first?.name ?? address

        // 2) Fire two route requests in parallel: one for "now" (traffic-aware)
        //    and one for the next off-peak slot as a free-flow baseline. The
        //    difference approximates the current traffic delay.
        func makeRequest(departureDate: Date?) -> MKDirections.Request {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .automobile
            request.requestsAlternateRoutes = false
            if let departureDate { request.departureDate = departureDate }
            return request
        }

        async let liveResponse: MKDirections.Response = try {
            try await MKDirections(request: makeRequest(departureDate: Date())).calculate()
        }()
        async let baselineResponse: MKDirections.Response? = {
            // Baseline call is best-effort — we don't fail the tile if it errors.
            try? await MKDirections(request: makeRequest(departureDate: Self.nextSunday03(from: Date()))).calculate()
        }()

        let live: MKDirections.Response
        do {
            live = try await liveResponse
        } catch {
            throw CommuteError.routeFailed(underlying: error)
        }
        guard let route = live.routes.first else {
            throw CommuteError.routeFailed(underlying: NSError(domain: "MapKit", code: 1))
        }

        let baseline = await baselineResponse
        let baselineTime = baseline?.routes.first?.expectedTravelTime

        let distanceKm = route.distance / 1000
        let teslaKWh = distanceKm * Self.teslaModel3AWD2025Efficiency

        return CommuteEstimate(
            expectedTravelTime: route.expectedTravelTime,
            baselineTravelTime: baselineTime,
            distanceMeters: route.distance,
            fromLabel: originLabel,
            toLabel: toLabel,
            teslaKWh: teslaKWh
        )
    }

    /// Next Sunday at ~03:00 local time — used as a "no traffic" probe for
    /// MKDirections. If we're already past this Sunday's 03:00, we roll to the
    /// following one. All computations are in the user's local calendar.
    static func nextSunday03(from reference: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let components = DateComponents(hour: 3, minute: 0, second: 0, weekday: 1) // 1 = Sunday
        return cal.nextDate(
            after: reference,
            matching: components,
            matchingPolicy: .nextTime
        ) ?? reference.addingTimeInterval(7 * 24 * 3600)
    }
}
