import CoreLocation
import Foundation
import Observation

/// Wraps CLLocationManager for Uptodate mode. Asks for "when in use" permission,
/// exposes an observable `currentCoordinate` + `cityName` (reverse-geocoded), and
/// falls back gracefully to a user-entered city from UserDefaults if the user denies.
@MainActor
@Observable
final class LocationService: NSObject {
    /// Last-known coordinate, or nil if unavailable.
    private(set) var coordinate: CLLocationCoordinate2D?
    /// Reverse-geocoded locality (e.g. "København").
    private(set) var cityName: String?
    /// Current authorization state — the view surfaces "grant access" UI when denied.
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// User-entered fallback city from Settings (e.g. "Aarhus").
    var manualCity: String? {
        get { UserDefaults.standard.string(forKey: Self.manualCityKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.manualCityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.manualCityKey)
            }
        }
    }

    /// User's home address — used by Info mode's commute estimate. Free-form string,
    /// gets geocoded on each Info refresh. Seeded to the owner's address on first run;
    /// free-form override via Settings.
    var homeAddress: String? {
        get { UserDefaults.standard.string(forKey: Self.homeAddressKey) ?? Self.defaultHomeAddress }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.homeAddressKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.homeAddressKey)
            }
        }
    }

    private static let manualCityKey = "jarvisManualCity"
    private static let homeAddressKey = "jarvisHomeAddress"
    private static let defaultHomeAddress = "Jernbanegade 4E, 4700 Næstved"

    private let manager = CLLocationManager()
    private var lastRefresh: Date?
    private var pendingContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorization = manager.authorizationStatus
    }

    /// Ask for authorization. Safe to call repeatedly — macOS suppresses duplicate prompts.
    func requestAuthorization() {
        guard authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// True when the user has granted location access. On macOS the granted
    /// state is `.authorizedAlways` — `.authorizedWhenInUse` is iOS-only.
    static func isAuthorizedStatus(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways
    }

    /// Refresh the current location. Waits up to 5 s for a fix. Returns nil if the user
    /// denied access or no fix is available — in either case the caller should use
    /// `manualCity` instead (or prompt the user to set one).
    func refresh() async -> CLLocationCoordinate2D? {
        // Cache: avoid repeated requests within 60 s.
        if let coordinate, let last = lastRefresh, Date().timeIntervalSince(last) < 60 {
            return coordinate
        }
        // Stale-but-present coordinate: return it immediately and let the fresh
        // request race in the background, so Info-mode paints without waiting
        // 5 s on CLLocationManager's safety net every time. The delegate updates
        // `coordinate`/`lastRefresh` when the fresh fix arrives.
        if let cached = coordinate, Self.isAuthorizedStatus(authorization) {
            manager.requestLocation()
            return cached
        }

        switch authorization {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            requestAuthorization()
            return nil
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            self.pendingContinuation = continuation
            self.manager.requestLocation()
            // Safety net — CLLocation can hang on first-run.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if let pending = self.pendingContinuation {
                    self.pendingContinuation = nil
                    pending.resume(returning: self.coordinate)
                }
            }
        }
    }

    /// Like `refresh()` but also awaits reverse-geocoding so the returned label is
    /// the actual city name (not "Din lokation"). Falls back to the previous name
    /// if geocoding fails.
    func refreshWithCity() async -> (CLLocationCoordinate2D, String)? {
        guard let coord = await refresh() else { return nil }
        if let city = cityName, !city.isEmpty {
            return (coord, city)
        }
        let resolved = await reverseGeocodeAwait(coord)
        return (coord, resolved ?? "Din lokation")
    }

    private func reverseGeocodeAwait(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        let name = placemarks?.first?.locality
            ?? placemarks?.first?.subLocality
            ?? placemarks?.first?.name
        if let name, !name.isEmpty {
            self.cityName = name
            return name
        }
        return nil
    }

    /// Resolve a manual city string to a coordinate via CLGeocoder.
    func geocodeManual(_ city: String) async -> (CLLocationCoordinate2D, String)? {
        do {
            let placemarks = try await CLGeocoder().geocodeAddressString(city)
            guard let placemark = placemarks.first,
                  let location = placemark.location else { return nil }
            let name = placemark.locality ?? placemark.name ?? city
            return (location.coordinate, name)
        } catch {
            LoggingService.shared.log("Manual geocode failed for '\(city)': \(error)", level: .warning)
            return nil
        }
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            Task { @MainActor [weak self] in
                self?.cityName = placemarks?.first?.locality ?? placemarks?.first?.name
            }
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.coordinate = coord
            self.lastRefresh = Date()
            self.reverseGeocode(coord)
            if let pending = self.pendingContinuation {
                self.pendingContinuation = nil
                pending.resume(returning: coord)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            LoggingService.shared.log("Location update failed: \(error.localizedDescription)", level: .warning)
            if let pending = self.pendingContinuation {
                self.pendingContinuation = nil
                pending.resume(returning: self.coordinate)
            }
        }
    }
}
