import SwiftUI
import UIKit

/// The eight pin colours, stored by NAME in the pin and project records
/// (docs/PINS_PLAN.md §4): the values can be tuned later without touching
/// a record, and a name this build doesn't know (written by a newer one,
/// or a typo) draws in a neutral grey — never a crash.
///
/// Chosen to read as an 8 pt mark inside a white halo and an ink keyline
/// over LIST topo (white paper, brown contours, blue water), aerial photos
/// (dark greens, browns, sea) and the TASVEG fills at Light strength, and
/// to stay apart from the three hues already spent on the map: the
/// selection red #FF3B30, `treeGreen` #1F5130 and the location dot's
/// system blue. Spread round the wheel with steps in lightness as well
/// (gold/pink light, brown/violet dark), so two neighbours differ in tone
/// even where hue is hard to see (sun glare, small marks). No acid green
/// (52 TASVEG communities are green) and no cyan-blue (the location dot).
nonisolated enum PinColour: String, CaseIterable, Identifiable, Sendable {
    case orange, gold, olive, teal, violet, magenta, pink, brown

    var id: String { rawValue }

    /// "#rrggbb"
    var hex: String {
        switch self {
        case .orange: "#EE7A12"
        case .gold: "#F2BE00"
        case .olive: "#7F8C1C"
        case .teal: "#0E9C96"
        case .violet: "#7550CC"
        case .magenta: "#CC2E8F"
        case .pink: "#F59AC2"
        case .brown: "#8A5426"
        }
    }

    /// The name in the interface.
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// A new project's colour when nothing else is chosen, and an unfiled
    /// pin's when it has no colour of its own.
    static let standard = PinColour.orange

    /// Grey for a stored name this build doesn't know.
    static let fallbackHex = "#9A9A9A"

    /// The colour stored under `name`, nil when unknown.
    static func named(_ name: String?) -> PinColour? {
        name.flatMap { PinColour(rawValue: $0.lowercased()) }
    }

    /// The hex to draw for a stored name (unknown → the neutral fallback).
    static func hex(forName name: String?) -> String {
        named(name)?.hex ?? fallbackHex
    }

    var color: Color { Color(uiColor: uiColor) }
    var uiColor: UIColor { Self.uiColor(hex: hex) }

    static func uiColor(hex: String) -> UIColor {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// A square keylined swatch for menus (they draw only images and text).
    static func swatchImage(hex: String, side: CGFloat = 18) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            uiColor(hex: hex).setFill()
            context.fill(rect)
            UIColor(white: 0, alpha: 0.5).setStroke()
            context.cgContext.setLineWidth(1)
            context.cgContext.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
