import MapKit
import SwiftUI

/// Mini route map for the Hjem tile. Draws a cyan polyline between the two
/// endpoints and auto-fits to its bounding rect. No user interaction — the
/// tile stays a glanceable surface.
struct CommuteMapView: NSViewRepresentable {
    let origin: CoordinateLatLon
    let destination: CoordinateLatLon
    let coordinates: [CoordinateLatLon]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.wantsLayer = true
        map.layer?.cornerRadius = 8
        map.layer?.masksToBounds = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let polyCoords = coordinates.map { $0.clLocationCoordinate }
        if polyCoords.count >= 2 {
            let polyline = MKPolyline(coordinates: polyCoords, count: polyCoords.count)
            map.addOverlay(polyline)
        }

        let pinStart = MKPointAnnotation()
        pinStart.coordinate = origin.clLocationCoordinate
        pinStart.title = "Start"

        let pinEnd = MKPointAnnotation()
        pinEnd.coordinate = destination.clLocationCoordinate
        pinEnd.title = "Mål"

        map.addAnnotations([pinStart, pinEnd])

        if let rect = boundingRect(for: polyCoords.isEmpty ? [origin.clLocationCoordinate, destination.clLocationCoordinate] : polyCoords) {
            // Extra padding so the pins + polyline aren't glued to the tile edges.
            let padded = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
            map.setVisibleMapRect(rect, edgePadding: padded, animated: false)
        }
    }

    private func boundingRect(for coords: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coords.isEmpty else { return nil }
        var rect = MKMapRect.null
        for coord in coords {
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
            rect = rect.union(pointRect)
        }
        return rect
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = NSColor(red: 0.255, green: 0.941, blue: 0.984, alpha: 1.0) // #41F0FB
                renderer.lineWidth = 4
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
