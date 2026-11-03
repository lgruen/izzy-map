import IzzyKit
import SwiftUI

/// The small statewide maps (a plant's records, a community's "where
/// else"): printed matter, so a light plate in both appearances — land in
/// paper with a fine grey coast on a white sea, the data in ink (never a
/// community's own fill: pale fills vanished on grey land), square-cornered
/// and keylined like a key box, a ringed "you are here" and a 100 km tick.
/// Framed tight on the state incl. King Island and the Furneaux Group.
struct TasmaniaMiniMap: View {
    /// What to draw on the land.
    enum Marks {
        /// Squares of `size` degrees (centre, ink step 1…3) — a plant's
        /// records in the atlas convention.
        case squares([GridSquare], size: (lon: Double, lat: Double))
        /// A community's presence cells (centre, level 1…4), graded in ink.
        case presence([(latitude: Double, longitude: Double, level: Int)], cellSize: (lon: Double, lat: Double))
    }

    let outline: TasmaniaOutline
    let marks: Marks
    var ring: (latitude: Double, longitude: Double)?

    /// The frame in degrees: the silhouette's box plus a hair of sea.
    private var box: (w: Double, s: Double, e: Double, n: Double) {
        let b = outline.bbox
        return (b[0] - 0.04, b[1] - 0.04, b[2] + 0.04, b[3] + 0.04)
    }
    /// x shrink at the state's mid-latitude (an equirectangular sheet).
    nonisolated static let xScale = cos(41.6 * .pi / 180)

    /// Width : height of the drawing.
    var aspect: Double { (box.e - box.w) * Self.xScale / (box.n - box.s) }

    /// Ink steps for presence levels 1…4 (a trace lightest).
    nonisolated static let presenceInk = [0, 0.3, 0.55, 0.8, 1.0]
    /// Ink steps for record squares 1…3.
    nonisolated static let squareInk = [0, 0.3, 0.6, 1.0]

    var body: some View {
        Canvas { ctx, size in
            let b = box
            let k = min(size.width / ((b.e - b.w) * Self.xScale), size.height / (b.n - b.s))
            let ox = (size.width - (b.e - b.w) * Self.xScale * k) / 2
            let oy = (size.height - (b.n - b.s) * k) / 2
            func pt(_ lat: Double, _ lon: Double) -> CGPoint {
                CGPoint(x: ox + (lon - b.w) * Self.xScale * k, y: oy + (b.n - lat) * k)
            }
            var land = Path()
            for ring in outline.rings {
                guard let first = ring.first else { continue }
                land.move(to: pt(first[1], first[0]))
                for p in ring.dropFirst() { land.addLine(to: pt(p[1], p[0])) }
                land.closeSubpath()
            }
            ctx.fill(land, with: .color(Self.paper))
            switch marks {
            case let .squares(squares, cell):
                let w = cell.lon * Self.xScale * k, h = cell.lat * k
                for step in 1 ... 3 {
                    var path = Path()
                    for sq in squares where sq.step == step {
                        let p = pt(sq.latitude, sq.longitude)
                        path.addRect(CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h))
                    }
                    ctx.fill(path, with: .color(Self.ink.opacity(Self.squareInk[step])))
                }
            case let .presence(cells, size):
                // a cell is ~0.6 pt on a 140 pt map: a rare community's
                // handful of cells gets a mark big enough to find
                let floor = cells.count < 40 ? 3.5 : cells.count < 400 ? 2.0 : 1.0
                let w = max(floor, size.lon * Self.xScale * k), h = max(floor, size.lat * k)
                for level in 1 ... 4 {
                    var path = Path()
                    for c in cells where c.level == level {
                        let p = pt(c.latitude, c.longitude)
                        path.addRect(CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h))
                    }
                    ctx.fill(path, with: .color(Self.ink.opacity(Self.presenceInk[level])))
                }
            }
            ctx.stroke(land, with: .color(Self.coast), lineWidth: 0.5)
            // 100 km tick in the south-west sea
            let km100 = 100 / (111.32 * Self.xScale)
            let a = pt(b.s + 0.2, b.w + 0.12), e = pt(b.s + 0.2, b.w + 0.12 + km100)
            var bar = Path()
            bar.move(to: a); bar.addLine(to: e)
            for p in [a, e] {
                bar.move(to: CGPoint(x: p.x, y: p.y - 2.5))
                bar.addLine(to: CGPoint(x: p.x, y: p.y))
            }
            ctx.stroke(bar, with: .color(Self.ink.opacity(0.7)), lineWidth: 0.75)
            ctx.draw(Text("100 km").font(.system(size: 9)).monospacedDigit().foregroundStyle(Self.ink.opacity(0.7)),
                     at: CGPoint(x: (a.x + e.x) / 2, y: a.y - 4), anchor: .bottom)
            if let ring {
                let p = pt(ring.latitude, ring.longitude)
                let r = 5.0
                let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                ctx.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 4)
                ctx.stroke(circle, with: .color(Self.ink), lineWidth: 1.5)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .padding(4)
        .background(DesignColor.keyPlate)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        // the plate is printed matter: its marks stay dark in dark mode
        .environment(\.colorScheme, .light)
    }

    nonisolated static let paper = Color(red: 0xF6 / 255, green: 0xF5 / 255, blue: 0xF0 / 255)
    nonisolated static let coast = Color.black.opacity(0.45)
    nonisolated static let ink = Color.black
}

/// One square of a plant's record map: its centre and ink step (1: one
/// site, 2: 2–4, 3: 5 or more).
nonisolated struct GridSquare: Sendable, Hashable {
    var latitude: Double
    var longitude: Double
    var step: Int
    var sites: Int

    /// 5 km squares at the state's latitude, in degrees.
    static let size = (lon: 5 / (111.32 * cos(41.6 * .pi / 180)), lat: 5 / 111.32)

    /// The ~1 km record cells summed into 5 km squares (aligned on the
    /// grid's origin, so a square never moves between plants).
    static func squares(_ cells: [RecordCell]) -> [GridSquare] {
        var sums: [Int: (row: Int, col: Int, sites: Int)] = [:]
        for c in cells {
            let row = Int(floor((c.latitude + 44) / size.lat)), col = Int(floor((c.longitude - 143) / size.lon))
            let key = row * 10000 + col
            sums[key, default: (row, col, 0)].sites += c.sites
        }
        return sums.values.map { v in
            GridSquare(latitude: -44 + (Double(v.row) + 0.5) * size.lat,
                       longitude: 143 + (Double(v.col) + 0.5) * size.lon,
                       step: v.sites >= 5 ? 3 : v.sites >= 2 ? 2 : 1, sites: v.sites)
        }
    }
}

/// A map key row: small ink squares with their meaning.
struct InkKey: View {
    let items: [(opacity: Double, label: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    // a swatch of the printed plate: ink on paper, in dark mode too
                    Rectangle()
                        .fill(Color.black.opacity(item.opacity))
                        .frame(width: 8, height: 8)
                        .padding(1.5)
                        .background(TasmaniaMiniMap.paper)
                        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                    Text(item.label)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(DesignColor.ink)
                        .fixedSize()
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The credit under the mini-maps.
enum MiniMapCredits {
    static let presence = "TASVEG 5.0 and locality boundaries © State of Tasmania, CC BY 3.0 AU"
    static let records = "Records: Atlas of Living Australia · coastline: locality boundaries © State of Tasmania, CC BY 3.0 AU"
}
