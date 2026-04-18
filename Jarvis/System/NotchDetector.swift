import AppKit
import Foundation

/// Utilities for detecting the MacBook camera notch and deriving its geometry
/// so the HUD can anchor a pill underneath it.
enum NotchDetector {
    struct NotchMetrics {
        /// Screen we measured on.
        let screen: NSScreen
        /// Height of the notch cutout in points (≈ 32–38 pt on current hardware).
        let notchHeight: CGFloat
        /// Estimated notch width in points. macOS doesn't expose this directly, but
        /// the auxiliary-top areas straddling the notch tell us where the notch is.
        let notchWidth: CGFloat
        /// Horizontal center of the notch in the screen's coordinate space (AppKit: origin bottom-left).
        let notchCenterX: CGFloat
        /// The Y coordinate (AppKit flipped) of the BOTTOM edge of the notch —
        /// i.e. where a HUD pill can begin growing downward.
        let notchBottomY: CGFloat
    }

    /// Returns metrics for the screen with a notch (prefers `main`), or nil on
    /// machines without one.
    static func currentMetrics() -> NotchMetrics? {
        let screens: [NSScreen] = [NSScreen.main].compactMap { $0 } + NSScreen.screens
        for screen in screens {
            if let metrics = metrics(for: screen) { return metrics }
        }
        return nil
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics? {
        let topInset = screen.safeAreaInsets.top
        guard topInset > 0 else { return nil }

        let frame = screen.frame
        // Left + right auxiliary areas, if available, bracket the notch. Their gap
        // is the notch width. Fall back to a reasonable default if they're missing.
        let lefts = screen.auxiliaryTopLeftArea
        let rights = screen.auxiliaryTopRightArea

        let notchWidth: CGFloat
        let notchCenterX: CGFloat
        if let left = lefts, let right = rights {
            let leftEnd = left.maxX
            let rightStart = right.minX
            notchWidth = max(120, rightStart - leftEnd)
            notchCenterX = (leftEnd + rightStart) / 2
        } else {
            // Sensible default for MacBook Pro 14/16 and Air 13/15.
            notchWidth = 220
            notchCenterX = frame.midX
        }

        return NotchMetrics(
            screen: screen,
            notchHeight: topInset,
            notchWidth: notchWidth,
            notchCenterX: notchCenterX,
            notchBottomY: frame.maxY - topInset
        )
    }
}

/// Persisted HUD-style preference. `auto` picks notch on notched Macs, corner otherwise.
enum HUDStylePreference: String, CaseIterable, Identifiable {
    case auto, corner, notch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:   return "Auto"
        case .corner: return "Hjørne"
        case .notch:  return "Notch"
        }
    }

    /// Resolve to the concrete style based on current hardware.
    func resolved() -> Resolved {
        switch self {
        case .notch:  return .notch
        case .corner: return .corner
        case .auto:   return NotchDetector.currentMetrics() != nil ? .notch : .corner
        }
    }

    enum Resolved { case corner, notch }
}
