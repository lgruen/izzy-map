import IzzyKit
import SwiftUI

/// The plant silhouettes: one family of front-elevation outlines, drawn as
/// a landscape architect draws planting in elevation — a closed outline
/// (stroked, lightly filled) per growth form. The height elevation draws
/// them to scale; the list pictograms are the same shapes at icon size, so
/// the list, the facts row and the elevation speak one language.
///
/// Each shape is built once from simple parts (ellipses, tapered blades,
/// stroked limbs) merged with `Path.union` into ONE outline — stroking the
/// parts separately would draw every overlap — then normalised: height 1,
/// ground at y = 1 (y down), centred on x = 0.
nonisolated struct Silhouette: Sendable {
    /// The closed outline (fill + stroke).
    let body: Path
    /// Open strokes drawn beside the outline at the same weight (a
    /// climber's support), not filled.
    let detail: Path
    /// Width : height.
    let aspect: Double

    static func of(_ shape: PlantSilhouette) -> Silhouette { table[shape] ?? table[.plant]! }

    /// Built once per process (`static let` is initialised lazily and
    /// thread-safely; paths are values).
    private static let table: [PlantSilhouette: Silhouette] = {
        var t: [PlantSilhouette: Silhouette] = [:]
        for s in PlantSilhouette.allCases { t[s] = build(s) }
        return t
    }()

    /// The outline placed with its ground centre at `base`, `height` tall
    /// and `width` wide (the shape's own width when nil).
    func transform(base: CGPoint, height: Double, width: Double? = nil) -> CGAffineTransform {
        let w = width ?? aspect * height
        let sx = aspect > 0 ? w / aspect : height
        return CGAffineTransform(translationX: base.x, y: base.y - height).scaledBy(x: sx, y: height)
    }

    // MARK: Parts

    private typealias P = CGPoint
    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, angle: Double = 0) -> Path {
        Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
            .applying(CGAffineTransform(rotationAngle: angle))
            .applying(CGAffineTransform(translationX: cx, y: cy))
    }

    private static func union(_ parts: [Path]) -> Path {
        guard var out = parts.first else { return Path() }
        for p in parts.dropFirst() { out = out.union(p) }
        return out
    }

    private static func limb(_ points: [CGPoint], width: Double) -> Path {
        var p = Path()
        p.move(to: points[0])
        if points.count == 3 {
            p.addQuadCurve(to: points[2], control: points[1])
        } else {
            for q in points.dropFirst() { p.addLine(to: q) }
        }
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return pt(u * u * a.x + 2 * u * t * c.x + t * t * b.x, u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private static func tangent(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGVector {
        let dx = 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x)
        let dy = 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y)
        let n = max(1e-9, (dx * dx + dy * dy).squareRoot())
        return CGVector(dx: dx / n, dy: dy / n)
    }

    /// A blade along a quadratic curve, `width` at the base tapering to a
    /// point (grass leaves, fronds, strap leaves).
    private static func blade(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, width: Double, steps: Int = 14) -> Path {
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0 ... steps {
            let t = Double(i) / Double(steps)
            let p = quad(a, c, b, t), d = tangent(a, c, b, t)
            let w = width / 2 * pow(1 - t, 0.8)
            left.append(pt(p.x - d.dy * w, p.y + d.dx * w))
            right.append(pt(p.x + d.dy * w, p.y - d.dx * w))
        }
        var path = Path()
        path.addLines(left + right.reversed())
        path.closeSubpath()
        return path
    }

    /// A lens-shaped leaf from `a` to `b`.
    private static func leaf(_ a: CGPoint, _ b: CGPoint, width: Double) -> Path {
        let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
        let dx = b.x - a.x, dy = b.y - a.y
        let n = max(1e-9, (dx * dx + dy * dy).squareRoot())
        let ox = -dy / n * width, oy = dx / n * width
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: pt(mx + ox, my + oy))
        p.addQuadCurve(to: a, control: pt(mx - ox, my - oy))
        p.closeSubpath()
        return p
    }

    /// A lumpy crown: a core ellipse with circles round its rim.
    private static func crown(_ cx: Double, _ cy: Double, rx: Double, ry: Double, lobes: Int, r: Double,
                              from: Double = 0, to: Double = 2 * .pi, jitter: Double = 0.18) -> Path {
        var parts = [ellipse(cx, cy, rx * 0.92, ry * 0.92)]
        for i in 0 ..< lobes {
            let u = (Double(i) + 0.5) / Double(lobes)
            let a = from + (to - from) * u
            // a fixed, irregular rhythm (no randomness: every draw identical)
            let k = 1 + jitter * sin(Double(i) * 2.399 + 0.7)
            parts.append(ellipse(cx + rx * cos(a), cy + ry * sin(a), r * k, r * k * 0.92))
        }
        return union(parts)
    }

    /// A clump of foliage: a few overlapping circles.
    private static func clump(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
        union([ellipse(cx, cy, r, r * 0.8),
               ellipse(cx - r * 0.7, cy + r * 0.25, r * 0.62, r * 0.55),
               ellipse(cx + r * 0.72, cy + r * 0.2, r * 0.6, r * 0.52),
               ellipse(cx + r * 0.15, cy - r * 0.55, r * 0.6, r * 0.5)])
    }

    /// Height 1, ground at y = 1, centred on x = 0.
    private static func normalised(_ body: Path, detail: Path = Path(), ground: Double? = nil) -> Silhouette {
        let all = body.boundingRect.union(detail.isEmpty ? body.boundingRect : detail.boundingRect)
        let bottom = ground ?? all.maxY
        let h = max(1e-6, bottom - all.minY)
        let t = CGAffineTransform(scaleX: 1 / h, y: 1 / h).translatedBy(x: -all.midX, y: -all.minY)
        return Silhouette(body: body.applying(t), detail: detail.applying(t), aspect: all.width / h)
    }

    // MARK: Shapes (built y down, ground near y = 1)

    private static func build(_ shape: PlantSilhouette) -> Silhouette {
        switch shape {
        case .eucalypt:
            // a clear bole ~40 % of the height, limbs forking into an open,
            // lumpy crown ~0.55 h wide: separate clumps with sky between
            var bole = Path()
            bole.addLines([pt(-0.075, 1), pt(-0.034, 0.955), pt(-0.026, 0.66), pt(-0.018, 0.5),
                           pt(0.02, 0.5), pt(0.029, 0.66), pt(0.038, 0.955), pt(0.08, 1)])
            bole.closeSubpath()
            let limbs = [
                limb([pt(0, 0.56), pt(-0.06, 0.42), pt(-0.18, 0.33)], width: 0.022),
                limb([pt(0, 0.56), pt(0.05, 0.4), pt(0.16, 0.27)], width: 0.022),
                limb([pt(0, 0.52), pt(0.0, 0.3), pt(-0.03, 0.12)], width: 0.018),
                limb([pt(-0.04, 0.42), pt(-0.15, 0.4), pt(-0.24, 0.45)], width: 0.012),
                limb([pt(0.05, 0.4), pt(0.17, 0.38), pt(0.25, 0.42)], width: 0.012),
            ]
            let clumps = [clump(-0.19, 0.3, 0.075), clump(-0.25, 0.43, 0.05), clump(0.17, 0.24, 0.085),
                          clump(0.26, 0.39, 0.05), clump(-0.03, 0.1, 0.085), clump(0.08, 0.16, 0.06),
                          clump(-0.12, 0.19, 0.055)]
            return normalised(union([bole] + limbs + clumps))
        case .broadleafTree:
            // a short bole under a dense, rounded crown with a scalloped rim
            var bole = Path()
            bole.addLines([pt(-0.07, 1), pt(-0.036, 0.95), pt(-0.03, 0.6), pt(0.03, 0.6), pt(0.036, 0.95), pt(0.07, 1)])
            bole.closeSubpath()
            return normalised(union([bole, crown(0, 0.37, rx: 0.29, ry: 0.27, lobes: 13, r: 0.085)]))
        case .conifer:
            // tiers of drooping branches round a straight leader
            var parts: [Path] = []
            let tiers = 6
            for i in 0 ..< tiers {
                let top = 0.02 + Double(i) * 0.13, base = top + 0.22
                let w = 0.05 + 0.2 * base / 0.9
                var tier = Path()
                tier.move(to: pt(0, top))
                tier.addQuadCurve(to: pt(-w, base), control: pt(-w * 0.35, top + 0.08))
                tier.addQuadCurve(to: pt(w, base), control: pt(0, base - 0.06))
                tier.addQuadCurve(to: pt(0, top), control: pt(w * 0.35, top + 0.08))
                tier.closeSubpath()
                parts.append(tier)
            }
            parts.append(limb([pt(0, 0.0), pt(0, 1)], width: 0.03))
            var foot = Path()
            foot.addLines([pt(-0.05, 1), pt(-0.02, 0.94), pt(0.02, 0.94), pt(0.05, 1)])
            foot.closeSubpath()
            parts.append(foot)
            return normalised(union(parts))
        case .treeFern:
            // a fibrous trunk and a rosette of arching fronds
            var trunk = Path()
            trunk.addLines([pt(-0.07, 1), pt(-0.05, 0.96), pt(-0.042, 0.3), pt(0.042, 0.3), pt(0.05, 0.96), pt(0.07, 1)])
            trunk.closeSubpath()
            let o = pt(0, 0.3)
            let fronds: [(CGPoint, CGPoint)] = [
                (pt(-0.2, 0.06), pt(-0.42, 0.42)), (pt(-0.14, 0.0), pt(-0.33, 0.12)), (pt(-0.04, -0.04), pt(-0.12, 0.0)),
                (pt(0.04, -0.04), pt(0.12, 0.0)), (pt(0.14, 0.0), pt(0.33, 0.12)), (pt(0.2, 0.06), pt(0.42, 0.42)),
                (pt(0.0, -0.02), pt(0.0, 0.02)),
            ]
            let blades = fronds.map { c, tip in blade(o, c, tip, width: 0.075) }
            return normalised(union([trunk] + blades))
        case .shrub:
            // a multi-stemmed mound, about as wide as tall
            let stems = [limb([pt(-0.13, 1), pt(-0.09, 0.8)], width: 0.028), limb([pt(0, 1), pt(0, 0.8)], width: 0.028),
                         limb([pt(0.13, 1), pt(0.09, 0.8)], width: 0.028)]
            return normalised(union([crown(0, 0.46, rx: 0.36, ry: 0.3, lobes: 12, r: 0.12)] + stems))
        case .herb:
            // a leafy mound with flowering stems above it
            let base = pt(0, 1)
            var parts: [Path] = []
            for (deg, len) in [(168.0, 0.42), (142, 0.46), (114, 0.44), (66, 0.44), (38, 0.46), (12, 0.42)] {
                let a = deg * .pi / 180
                parts.append(leaf(base, pt(len * cos(a), 1 - len * sin(a)), width: 0.08))
            }
            for (tip, ctl) in [(pt(-0.2, 0.1), pt(-0.06, 0.5)), (pt(0.02, 0.0), pt(0.0, 0.5)), (pt(0.22, 0.14), pt(0.08, 0.5))] {
                parts.append(limb([pt(0, 0.92), ctl, tip], width: 0.018))
                parts.append(ellipse(tip.x, tip.y + 0.01, 0.05, 0.045))
            }
            return normalised(union(parts))
        case .cushion:
            // a tight, smooth dome, much wider than tall
            var dome = Path()
            dome.move(to: pt(-1.3, 1))
            dome.addCurve(to: pt(0, 0), control1: pt(-1.3, 0.35), control2: pt(-0.75, 0))
            dome.addCurve(to: pt(1.3, 1), control1: pt(0.75, 0), control2: pt(1.3, 0.35))
            dome.closeSubpath()
            return normalised(dome)
        case .mat:
            // a low mat of mounds hugging the ground
            var parts: [Path] = []
            var x = -2.1
            var i = 0
            while x <= 2.11 {
                let h = [0.8, 1.0, 0.75, 0.95, 0.85][i % 5]
                parts.append(ellipse(x, 1, 0.42, h))
                x += 0.6
                i += 1
            }
            var mat = union(parts)
            mat = mat.intersection(Path(CGRect(x: -3, y: -1, width: 6, height: 2)))
            return normalised(mat, ground: 1)
        case .grass:
            // a tussock fountain: fine blades arching out from a narrow base
            let tips: [(Double, Double, Double)] = [
                (-0.7, 0.72, 0.5), (-0.58, 0.32, 0.45), (-0.38, 0.08, 0.35), (-0.14, 0.0, 0.2), (0.08, 0.0, 0.15),
                (0.3, 0.06, 0.3), (0.52, 0.26, 0.42), (0.68, 0.66, 0.5), (-0.24, 0.32, 0.3), (0.2, 0.3, 0.28),
            ]
            let blades = tips.map { tx, ty, bend in
                let a = pt(tx * 0.08, 1)
                let c = pt(tx * bend, ty * 0.25)
                return blade(a, c, pt(tx, ty), width: 0.05)
            }
            var foot = Path()
            foot.addLines([pt(-0.1, 1), pt(-0.06, 0.88), pt(0.06, 0.88), pt(0.1, 1)])
            foot.closeSubpath()
            return normalised(union(blades + [foot]))
        case .sedge:
            // stiff, nearly upright leaves round a flowering culm
            var parts: [Path] = []
            for (tx, ty) in [(-0.3, 0.3), (-0.2, 0.16), (-0.08, 0.1), (0.1, 0.12), (0.22, 0.18), (0.32, 0.32)] {
                parts.append(blade(pt(tx * 0.15, 1), pt(tx * 0.5, 0.55), pt(tx, ty), width: 0.045))
            }
            parts.append(limb([pt(0.02, 1), pt(0.03, 0.06)], width: 0.02))
            parts.append(ellipse(0.03, 0.05, 0.035, 0.07))
            parts.append(ellipse(-0.02, 0.13, 0.028, 0.055, angle: -0.5))
            parts.append(ellipse(0.08, 0.14, 0.028, 0.055, angle: 0.5))
            return normalised(union(parts))
        case .rush:
            // fine, straight, upright stems; a flower tuft on one side
            var parts: [Path] = []
            for (bx, tx, ty) in [(-0.06, -0.2, 0.16), (-0.03, -0.1, 0.04), (0.0, 0.0, 0.0), (0.03, 0.09, 0.06),
                                 (0.06, 0.19, 0.18), (-0.045, -0.15, 0.3), (0.045, 0.14, 0.28)] {
                parts.append(limb([pt(bx, 1), pt(tx, ty)], width: 0.022))
            }
            parts.append(ellipse(0.075, 0.38, 0.04, 0.03))
            parts.append(ellipse(0.1, 0.33, 0.035, 0.028))
            parts.append(ellipse(0.06, 0.32, 0.03, 0.025))
            return normalised(union(parts))
        case .fern:
            // pinnate fronds arching from the ground: the rachis with its
            // pinnae, shrinking to the tip
            var parts: [Path] = []
            let fronds: [(CGPoint, CGPoint)] = [
                (pt(-0.35, 0.3), pt(-0.62, 0.55)), (pt(-0.22, 0.05), pt(-0.36, 0.06)), (pt(0.0, 0.1), pt(0.04, 0.0)),
                (pt(0.2, 0.06), pt(0.36, 0.1)), (pt(0.35, 0.32), pt(0.62, 0.58)),
            ]
            for (c, tip) in fronds {
                let a = pt(0, 1)
                parts.append(blade(a, c, tip, width: 0.03))
                var t = 0.22
                while t < 0.95 {
                    let p = quad(a, c, tip, t), d = tangent(a, c, tip, t)
                    let len = 0.11 * (1 - t) + 0.025
                    for side in [-1.0, 1.0] {
                        let end = pt(p.x - side * d.dy * len + d.dx * len * 0.35, p.y + side * d.dx * len + d.dy * len * 0.35)
                        parts.append(leaf(p, end, width: len * 0.28))
                    }
                    t += 0.085
                }
            }
            return normalised(union(parts))
        case .orchid:
            // one slender scape from a basal leaf, flowers at the top
            var parts: [Path] = [leaf(pt(0, 1), pt(-0.26, 0.62), width: 0.07), limb([pt(0, 1), pt(0, 0.08)], width: 0.02)]
            for (cx, cy) in [(0.0, 0.08), (0.05, 0.26)] {
                parts.append(ellipse(cx, cy - 0.05, 0.025, 0.055))
                parts.append(ellipse(cx - 0.055, cy + 0.01, 0.022, 0.055, angle: 1.0))
                parts.append(ellipse(cx + 0.055, cy + 0.01, 0.022, 0.055, angle: -1.0))
                parts.append(ellipse(cx, cy + 0.04, 0.03, 0.025))
            }
            return normalised(union(parts))
        case .climber:
            // a stem twining up a support line, leaves at its swings
            var stem = Path()
            for i in 0 ... 48 {
                let u = Double(i) / 48
                let p = pt(0.07 * sin(u * 3.6 * .pi), 1 - u * 0.98)
                if i == 0 { stem.move(to: p) } else { stem.addLine(to: p) }
            }
            var parts = [stem.strokedPath(StrokeStyle(lineWidth: 0.018, lineCap: .round, lineJoin: .round))]
            for k in 0 ..< 5 {
                let u = (Double(k) + 0.6) / 5.4
                let y = 1 - u * 0.98
                let side = k % 2 == 0 ? 1.0 : -1.0
                parts.append(leaf(pt(side * 0.06, y), pt(side * 0.2, y - 0.05), width: 0.045))
            }
            var support = Path()
            support.move(to: pt(0, 1))
            support.addLine(to: pt(0, 0))
            return normalised(union(parts), detail: support)
        case .plant:
            // a leaf on a stalk
            return normalised(union([limb([pt(0, 1), pt(0, 0.55)], width: 0.03),
                                     leaf(pt(0, 0.6), pt(0, 0), width: 0.2)]))
        }
    }
}

/// A silhouette as a pictogram: the shape standing on a short ground
/// line, outline at about SF Symbols' regular weight for its size (one
/// step heavier under Bold Text) over a light fill.
struct GrowthFormGlyph: View {
    let shape: PlantSilhouette
    /// Stroke colour.
    var ink: Color = DesignColor.ink
    @Environment(\.legibilityWeight) private var legibility

    init(shape: PlantSilhouette, ink: Color = DesignColor.ink) {
        self.shape = shape
        self.ink = ink
    }

    /// The form's own shape (no name to refine it by).
    init(form: GrowthForm?, ink: Color = DesignColor.ink) {
        self.init(shape: PlantSilhouette(form: form, name: ""), ink: ink)
    }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let line = (s * (legibility == .bold ? 0.075 : 0.055)).clamped(to: 1 ... 3)
            let sil = Silhouette.of(shape)
            let inset = line
            let box = CGRect(x: (size.width - s) / 2 + inset, y: (size.height - s) / 2 + inset,
                             width: s - 2 * inset, height: s - 2 * inset)
            let ground = box.maxY - line / 2
            // fit the square: wide shapes (mats, cushions) keep a readable
            // height, tall ones their proportions
            var h = box.height - line
            var w = sil.aspect * h
            if w > box.width {
                w = box.width
                h = max(w / sil.aspect, box.height * 0.34)
            }
            let t = sil.transform(base: CGPoint(x: box.midX, y: ground), height: h, width: w)
            let body = sil.body.applying(t)
            ctx.fill(body, with: .color(ink.opacity(0.14)))
            let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            ctx.stroke(body, with: .color(ink), style: style)
            ctx.stroke(sil.detail.applying(t), with: .color(ink), style: style)
            var g = Path()
            g.move(to: CGPoint(x: box.minX, y: ground))
            g.addLine(to: CGPoint(x: box.maxX, y: ground))
            ctx.stroke(g, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The photo placeholder: the plant's pictogram on a quiet square.
struct FormPlaceholder: View {
    let shape: PlantSilhouette

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                GrowthFormGlyph(shape: shape, ink: DesignColor.inkSecondary)
                    .padding(6)
            }
    }
}
