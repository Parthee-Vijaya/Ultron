import MapKit
import SwiftUI

/// Route map for the Hjem tile. Draws a cyan polyline between the two
/// endpoints. Full user interaction (zoom, scroll, rotate) because the tile
/// is large enough that it doubles as a real map, not just a route preview.
///
/// Charger overlays land in a follow-up commit once the `ChargerService`
/// type is merged — the map is intentionally agnostic about extra
/// annotations so that feature can layer on without a rewrite.
struct CommuteMapView: NSViewRepresentable {
    let origin: CoordinateLatLon
    let destination: CoordinateLatLon
    let coordinates: [CoordinateLatLon]
    /// Optional EV charger overlays. Annotations are brand-tinted so Tesla
    /// (red) and Clever (blue) read at a glance without a legend. Pass an
    /// empty array to hide them entirely.
    var chargers: [ChargerLocation] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Full user interaction — matches the "I want to zoom in on the
        // supercharger near Vejle" use case.
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isPitchEnabled = false
        map.isRotateEnabled = true
        map.showsCompass = true
        map.showsScale = true
        map.wantsLayer = true
        map.layer?.cornerRadius = 10
        map.layer?.masksToBounds = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        // Only reset the visible rect on the very first update — otherwise
        // every data refresh would yank the user's pan/zoom back to the
        // route bounds, making it impossible to stay zoomed in on a
        // charging stop.
        let isInitialLayout = context.coordinator.hasSetInitialRect == false

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let polyCoords = coordinates.map { $0.clLocationCoordinate }
        if polyCoords.count >= 2 {
            let polyline = MKPolyline(coordinates: polyCoords, count: polyCoords.count)
            map.addOverlay(polyline)
        }

        let pinStart = EndpointAnnotation(role: .start, coordinate: origin.clLocationCoordinate)
        let pinEnd = EndpointAnnotation(role: .end, coordinate: destination.clLocationCoordinate)
        map.addAnnotation(pinStart)
        map.addAnnotation(pinEnd)

        for charger in chargers {
            map.addAnnotation(ChargerAnnotation(charger: charger))
        }

        if isInitialLayout {
            let fallback = [origin.clLocationCoordinate, destination.clLocationCoordinate]
            if let rect = Self.boundingRect(for: polyCoords.isEmpty ? fallback : polyCoords) {
                let padded = NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
                map.setVisibleMapRect(rect, edgePadding: padded, animated: false)
                context.coordinator.hasSetInitialRect = true
            }
        }
    }

    private static func boundingRect(for coords: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coords.isEmpty else { return nil }
        var rect = MKMapRect.null
        for coord in coords {
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
            rect = rect.union(pointRect)
        }
        return rect
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// Flipped once the first `setVisibleMapRect` fires so we don't keep
        /// re-fitting and undoing the user's pan/zoom on every data update.
        var hasSetInitialRect: Bool = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = NSColor(red: 0.255, green: 0.941, blue: 0.984, alpha: 1.0)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let endpoint = annotation as? EndpointAnnotation {
                let reuseId = "endpoint.\(endpoint.role.rawValue)"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: endpoint, reuseIdentifier: reuseId)
                view.annotation = endpoint
                view.markerTintColor = endpoint.role == .start
                    ? NSColor(red: 0.45, green: 0.86, blue: 0.56, alpha: 1.0)  // green-ish for home
                    : NSColor(red: 0.97, green: 0.65, blue: 0.24, alpha: 1.0)  // amber for destination
                view.glyphImage = NSImage(systemSymbolName: endpoint.role == .start ? "house.fill" : "flag.fill",
                                          accessibilityDescription: nil)
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            if let charger = annotation as? ChargerAnnotation {
                let reuseId = "charger.\(charger.charger.network.rawValue)"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: charger, reuseIdentifier: reuseId)
                view.annotation = charger
                view.markerTintColor = Self.color(for: charger.charger.network)
                view.glyphImage = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
                view.displayPriority = .defaultLow  // let endpoints win when they overlap
                view.canShowCallout = true
                let kw = charger.charger.maxPowerKW.map { String(format: "%.0f kW", $0) } ?? "—"
                let label = NSTextField(labelWithString: "\(kw) · \(charger.charger.connectionCount) stik")
                label.font = .systemFont(ofSize: 10)
                label.textColor = .secondaryLabelColor
                view.detailCalloutAccessoryView = label
                return view
            }
            return nil
        }

        private static func color(for network: ChargerNetwork) -> NSColor {
            switch network {
            case .clever:            return NSColor(red: 0.059, green: 0.435, blue: 1.0, alpha: 1.0)
            case .teslaSupercharger: return NSColor(red: 0.910, green: 0.129, blue: 0.153, alpha: 1.0)
            }
        }
    }
}

// MARK: - Annotations

/// Start/end pins. Using a typed annotation so the delegate can pick the
/// right glyph without string-matching titles.
final class EndpointAnnotation: NSObject, MKAnnotation {
    enum Role: String { case start, end }
    let role: Role
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { role == .start ? "Start" : "Mål" }

    init(role: Role, coordinate: CLLocationCoordinate2D) {
        self.role = role
        self.coordinate = coordinate
    }
}

/// Wraps a `ChargerLocation` as an MKAnnotation so the map can pick brand
/// color + callout detail from the underlying data in one place.
final class ChargerAnnotation: NSObject, MKAnnotation {
    let charger: ChargerLocation
    dynamic var coordinate: CLLocationCoordinate2D { charger.coordinate.clLocationCoordinate }
    var title: String? { charger.title }
    var subtitle: String? {
        if charger.town.isEmpty { return charger.network.displayName }
        return "\(charger.network.displayName) · \(charger.town)"
    }

    init(charger: ChargerLocation) {
        self.charger = charger
    }
}
