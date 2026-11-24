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

    /// Keeping a selected pin in sight (`MapCoordinator.revealSelectedPin`):
    /// a pin this far inside the uncovered map shows whole — its ring (19 pt)
    /// at the sides and top, its label underneath.
    static let comfort = UIEdgeInsets(top: 24, left: 24, bottom: 40, right: 24)
    /// Where a hidden pin is brought to: well inside, not grazing an edge.
    static let revealInset = UIEdgeInsets(top: 56, left: 48, bottom: 72, right: 48)
    /// Less uncovered map than this (the large detent): nowhere to show it.
    static let revealMinimum = CGSize(width: 120, height: 120)

    /// How far (in points) the pin at `pin` must move to sit comfortably
    /// inside `free`, the map no chrome covers: nil when it already does,
    /// or when `free` is too small to show it in. The smallest move: the
    /// pin goes to the nearest point of the inner frame (`revealInset`),
    /// or the middle of `free` when that frame is empty.
    static func revealShift(pin: CGPoint, free: CGRect) -> CGVector? {
        guard free.width >= revealMinimum.width, free.height >= revealMinimum.height else { return nil }
        if free.inset(by: comfort).contains(pin) { return nil }
        let inner = free.inset(by: revealInset)
        let target = inner.width > 0 && inner.height > 0
            ? CGPoint(x: min(max(pin.x, inner.minX), inner.maxX), y: min(max(pin.y, inner.minY), inner.maxY))
            : CGPoint(x: free.midX, y: free.midY)
        return CGVector(dx: target.x - pin.x, dy: target.y - pin.y)
    }

    /// When keeping the selected pin in sight may move the camera (review
    /// S2-1): when a pin becomes selected, and when the panel round that
    /// selection changes shape (the phone's sheet detent, the iPad card's
    /// height) — only until her first map gesture after the selection.
    /// A pill, a notice or a banner coming or going never arms it.
    struct RevealGate: Equatable, Sendable {
        /// The selection it last looked at.
        private(set) var pin: UUID?
        /// Whether a reveal may still run for `pin`.
        private(set) var armed = false

        /// The selection changed (nil: none). True when a reveal should be
        /// scheduled for the newly selected pin.
        mutating func selected(_ id: UUID?) -> Bool {
            guard id != pin else { return false }
            pin = id
            armed = id != nil
            return armed
        }

        /// The selected pin moved, or a move was undone: armed again for
        /// it (its new spot may be under the sheet or the pill). False
        /// with no pin selected.
        mutating func moved(_ id: UUID?) -> Bool {
            guard let id else { return false }
            pin = id
            armed = true
            return true
        }

        /// The panel's geometry changed: true while armed.
        func panelChanged() -> Bool { armed }

        /// She took the map: her camera from now on, until the next selection.
        mutating func gesture() { armed = false }
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
