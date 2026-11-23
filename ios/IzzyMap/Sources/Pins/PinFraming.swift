import CoreGraphics
import CoreLocation
import UIKit

/// What the camera does once the Pins screen has gone: frame a project's
/// pins ("Show on map"), or bring one picked pin into view.
nonisolated struct PinsFit: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// [west, south, east, north] of the pins.
        case box([Double])
        /// One pin: centred if out of sight or the map is zoomed far out.
        case pin(latitude: Double, longitude: Double)
    }

    let target: Target
    let serial: Int
}

/// The rules for framing pins (docs/PINS_PLAN.md §5 "Show on map").
nonisolated enum PinFraming {
    /// No closer than this when framing: a single pin, or a few metres
    /// apart, show their surroundings (z15 ≈ 1:18,000, the topo pack's
    /// finest level) rather than a street-level close-up.
    static let maxZoom = 15.0
    /// A picked pin seen from farther out than this is brought closer.
    static let pinMinZoom = 13.0
    /// The zoom a picked pin is brought in to.
    static let pinZoom = 15.0
    /// Room round the marks: a mark is 8 pt plus halo, its label runs
    /// below it, so at least 44 pt, and 8 % / 6 % of the uncovered map.
    static let minimumMargin: CGFloat = 44

    /// The pins' box [west, south, east, north]; nil for none.
    static func box(_ coordinates: [CLLocationCoordinate2D]) -> [Double]? {
        guard let first = coordinates.first else { return nil }
        var b = [first.longitude, first.latitude, first.longitude, first.latitude]
        for c in coordinates.dropFirst() {
            b[0] = min(b[0], c.longitude); b[1] = min(b[1], c.latitude)
            b[2] = max(b[2], c.longitude); b[3] = max(b[3], c.latitude)
        }
        return b
    }

    /// Absolute insets for the fit: the chrome (`framing`) plus a margin.
    static func margin(framing: UIEdgeInsets, in size: CGSize) -> UIEdgeInsets {
        let free = CGSize(width: max(0, size.width - framing.left - framing.right),
                          height: max(0, size.height - framing.top - framing.bottom))
        let dx = max(minimumMargin, free.width * 0.06), dy = max(minimumMargin, free.height * 0.08)
        return UIEdgeInsets(top: framing.top + dy, left: framing.left + dx,
                            bottom: framing.bottom + dy, right: framing.right + dx)
    }
}
