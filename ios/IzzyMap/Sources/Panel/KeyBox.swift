import IzzyKit
import SwiftUI

/// Colour roles of docs/DESIGN.md §2 that the chrome needs.
enum DesignColor {
    /// 0.5 pt border on key boxes: #000 @ 50 % light, #FFF @ 45 % dark.
    static let keyline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.45) : UIColor(white: 0, alpha: 0.5)
    })
    /// Opaque ground under every key box (judged against white, as on paper).
    static let keyPlate = Color.white
    /// Hobart significant trees (the one non-ink map colour).
    static let treeGreen = Color(red: 0x1F / 255, green: 0x51 / 255, blue: 0x30 / 255)
    /// Chrome ink and its secondary tone. Explicit label colours, not the
    /// hierarchical `.primary`/`.secondary` styles: on glass those turn
    /// vibrant and pick up the map's hue (teal codes and × over cyan fills).
    static let ink = Color(uiColor: .label)
    /// Secondary text (common names, row labels, captions, distances,
    /// sizes, footers): `label` at 70 % light / 80 % dark, NOT
    /// `secondaryLabel` — that measured ≈ 3.2–3.4:1 on white and on the
    /// light glass over bright map fills, too faint outdoors. 70 % black
    /// is 8.4:1 on white and 7.4–7.6:1 on the sheet's glass over the map;
    /// 80 % white ≈ 10:1 on #1C1C1E, 3.1:1 on the dark glass over the
    /// light map, where even white is 3.85:1 (DESIGN.md §2).
    static let secondaryInk = Color(uiColor: secondaryInkUI)
    /// The same, for UIKit text (attributed strings).
    static let secondaryInkUI = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.8) : UIColor(white: 0, alpha: 0.7)
    }
    /// Codes ("DOB", "Jd"): ink at 75 %, quieter than the name beside them
    /// but legible as small footnote type (≈ 9:1 light, ≈ 10:1 dark;
    /// `secondaryLabel` is ≈ 3.4:1 on white — too faint for 13 pt small caps).
    static let codeInk = Color(uiColor: .label).opacity(0.75)
}

/// A near-opaque surface: the modal sheets' and the Layers popover's
/// ground, and the panel's under DEBUG `-sheetStyle plate`. What she reads
/// and judges there (key boxes, codes, names, thumbnails) can't be washed
/// through by the map's saturated colours (geology yellow, TASVEG cyan and
/// pink). Under Reduce Transparency this is the system's own look.
struct PanelPlate: View {
    var grouped = false

    var body: some View {
        Rectangle()
            .fill(grouped ? Color(uiColor: .systemGroupedBackground) : Color(uiColor: .systemBackground))
            .opacity(0.94)
            .background(.thickMaterial)
    }
}

/// What the panel (bottom sheet, floating card) is made of.
/// - `system` (shipping; Leo, 2026-11-03): the system's own Liquid Glass,
///   no `presentationBackground` override; content sits straight on it in
///   explicit, non-vibrant label colours (`DesignColor`), with no inner
///   glass or material groups (never glass on glass). The card is one glass
///   slab, the equivalent of the sheet's glass.
/// - `plate` (DEBUG only, launch argument `-sheetStyle plate`): content on
///   the near-opaque `PanelPlate`; the card keeps a thin glass rim around it.
enum PanelSurface: String {
    case system, plate

    static let current: PanelSurface = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "sheetStyle").flatMap(PanelSurface.init(rawValue:)) ?? .system
        #else
        .system
        #endif
    }()
}

/// The compact sheet's background for a surface. Fixed per launch, so the
/// branch never changes the content's identity.
struct SheetSurface: ViewModifier {
    let surface: PanelSurface

    func body(content: Content) -> some View {
        switch surface {
        case .system:
            content
        case .plate:
            content.presentationBackground { PanelPlate() }
        }
    }
}

/// A printed map key's box: square, 0.5 pt keyline, on a white plate. The
/// fill is the official colour as the map shows it at the current strength
/// (composited over white), or — in Outlines mode — the edge band in the
/// map's band colour (`StyleBuilder.bandColor`: dark fills lightened, never
/// ink) at the band's opacity.
struct KeyBox: View {
    let hex: String?
    /// The overlay's fill opacity on this base (0 = Outlines).
    var opacity: Double
    var width: CGFloat = 28
    /// nil: spans the rows beside it (a run of codes sharing the fill).
    var height: CGFloat? = 18

    var body: some View {
        let official = hex.flatMap(Color.init(hex:)) ?? Color(.systemGray4)
        ZStack {
            Rectangle().fill(DesignColor.keyPlate)
            if opacity > 0 {
                Rectangle().fill(composited ?? official)
            } else {
                // the Outlines band: a ribbon inside the edge, as the map draws it
                Rectangle().strokeBorder(band.opacity(StyleBuilder.bandOpacity), lineWidth: 3)
            }
        }
        .frame(width: width)
        .frame(minHeight: height ?? 18, maxHeight: height ?? .infinity)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    /// The map's band colour (same darkness cap); grey for an unknown hex.
    private var band: Color {
        hex.flatMap { Color(hex: StyleBuilder.bandColor($0)) } ?? Color(.systemGray4)
    }

    private var composited: Color? {
        guard let hex, let c = MapColour.overWhite(hex, alpha: opacity) else { return nil }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

/// A habitat class's key box on the plant sheet (`HabitatKey`): the
/// official fill of its TASVEG group's community at full strength, like the
/// card's swatch — it names a unit — or, for a class no group fits
/// (Riparian), hatched ink: the printed key's sign for "no fill of its own".
/// Same build as every key box: square, 0.5 pt keyline, on the white plate;
/// 3:2 like the legend's 28 × 18, at text size.
struct HabitatBox: View {
    let entry: HabitatKey.Entry
    @ScaledMetric(relativeTo: .footnote) private var height = 12

    var body: some View {
        ZStack {
            Rectangle().fill(DesignColor.keyPlate)
            if let hex = entry.hex, let fill = Color(hex: hex) {
                Rectangle().fill(fill)
            } else {
                Canvas { ctx, size in
                    // 45° ink hatching, 3 pt apart, as on a printed key
                    var lines = Path()
                    var x = -size.height
                    while x < size.width {
                        lines.move(to: CGPoint(x: x, y: size.height))
                        lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 3
                    }
                    ctx.stroke(lines, with: .color(.black.opacity(0.55)), lineWidth: 0.6)
                }
            }
        }
        .frame(width: height * 1.5, height: height)
        .clipped()
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// A code as a reference mark: SF small caps, tracking +0.5 (DESIGN.md).
struct CodeText: View {
    let code: String
    /// Small caps only for all-capital codes (TASVEG); geology symbols keep
    /// their case ("Jd" is not "JD").
    var smallCaps = true

    var body: some View {
        Text(code)
            .font(smallCaps ? .footnote.weight(.semibold).uppercaseSmallCaps() : .footnote.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(DesignColor.codeInk)
    }
}
