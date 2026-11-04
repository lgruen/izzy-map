import IzzyKit
import SwiftUI

/// A plant sheet section's heading: one style for all of them.
struct SheetHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(DesignColor.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The flowering chart: twelve month cells in chart order (January first
/// — `Flowering.startMonth`, her choice), in contiguous threes with a gap
/// between, as on a planting plan's bloom chart (season names under them
/// when the start is a season's). Ink cell = flowering, keylined cell =
/// not; the current month framed in ink; the runs in words below.
struct BloomChart: View {
    let months: [Int]

    var body: some View {
        let on = Set(months)
        let now = Calendar.current.component(.month, from: .now)
        let order = Flowering.order()
        VStack(alignment: .leading, spacing: 6) {
            SheetHeading("Flowering")
            HStack(alignment: .top, spacing: 8) {
                ForEach(0 ..< 4, id: \.self) { season in
                    VStack(spacing: 3) {
                        HStack(spacing: 2) {
                            ForEach(order[season * 3 ..< season * 3 + 3], id: \.self) { m in
                                VStack(spacing: 3) {
                                    Text(Flowering.initial(m))
                                        .font(.caption2.weight(m == now ? .bold : .regular))
                                        .foregroundStyle(m == now ? DesignColor.ink : DesignColor.secondaryInk)
                                    Rectangle()
                                        .fill(on.contains(m) ? DesignColor.ink : .clear)
                                        .overlay {
                                            Rectangle().strokeBorder(m == now ? DesignColor.ink : DesignColor.keyline,
                                                                     lineWidth: m == now ? 1.5 : 0.5)
                                        }
                                        .frame(height: 14)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        if let words = Self.seasonWords {
                            Text(words[season])
                                .font(.caption2)
                                .foregroundStyle(DesignColor.secondaryInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
            }
            Text(Flowering.spoken(months, now: now))
                .font(.footnote)
                .foregroundStyle(DesignColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Flowering.spoken(months, now: now))
        .accessibilityIdentifier("bloom-chart")
    }

    /// Southern season names under the four groups, when the chart starts
    /// on a season (Sep, Dec, Mar, Jun); a calendar January start's
    /// quarters (JFM, AMJ, …) straddle seasons, so they go unnamed.
    private static var seasonWords: [String]? {
        let names = [3: "autumn", 6: "winter", 9: "spring", 12: "summer"]
        guard names[Flowering.startMonth] != nil else { return nil }
        return (0 ..< 4).map { names[(Flowering.startMonth - 1 + 3 * $0) % 12 + 1]! }
    }
}

/// Height as a landscape architect's elevation: the plant's silhouette
/// drawn to a stated scale (`ElevationScale`, from a ladder of standard
/// ratios, the largest at which its maximum height fits) on a hatched
/// ground line, beside the conventional 1.7 m scale figure — or, at the
/// enlarged scales where a person would dwarf the plant, a boot cut by a
/// break line. The range is the maximum silhouette (outline over a light
/// fill) with the minimum as a dashed copy inside it, and a dimension
/// string at the side with ticks at both levels. A scale bar and the
/// ratio sit under the drawing; tall trees get faint level lines.
struct ElevationDrawing: View {
    let shape: PlantSilhouette
    let height: HeightRange
    @Environment(\.horizontalSizeClass) private var widthClass

    /// The plot's height: the ground line to the top of the drawing.
    private var plot: Double { widthClass == .regular ? 180 : 140 }
    private var scale: ElevationScale { ElevationScale.choose(maxHeight: height.max, plotHeight: plot) }

    var body: some View {
        let scale = self.scale
        VStack(alignment: .leading, spacing: 8) {
            SheetHeading("Height")
            Canvas { ctx, size in draw(&ctx, size, scale) }
                .frame(height: plot + 7)
                .clipped()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ElevationScaleBar(scale: scale)
                Spacer(minLength: 8)
                Text("\(height.text) · \(scale.showsFigure(plotHeight: plot) ? "person 1.7 m" : "boot 30 cm")")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(scale))
        .accessibilityIdentifier("height-drawing")
    }

    private func spoken(_ scale: ElevationScale) -> String {
        let range = height.upTo ? "up to \(HeightRange.label(height.max))"
            : height.min == height.max ? HeightRange.label(height.max)
            : "\(HeightRange.label(height.min)) to \(HeightRange.label(height.max))"
        let beside = scale.showsFigure(plotHeight: plot) ? "a 1.7 metre person" : "a 30 centimetre boot"
        return "Height \(range), drawn at \(scale.label.replacingOccurrences(of: ":", with: " to ")) beside \(beside)"
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ scale: ElevationScale) {
        let ink = DesignColor.ink
        let ground = plot
        let ppm = scale.pointsPerMetre
        let sil = Silhouette.of(shape)
        let showsFigure = scale.showsFigure(plotHeight: plot)

        // level lines first, under everything (labelled every other line
        // when they crowd)
        var labelColumn = 0.0
        if let step = scale.levelInterval {
            let gap = step * ppm
            let every = gap >= 14 ? 1 : Int((14 / gap).rounded(.up))
            labelColumn = 38
            // up to the first line above the plant
            let top = min(ground - 4, (ceil(height.max / step) * step) * ppm)
            var n = 1
            while Double(n) * gap <= top + 0.5 {
                let y = ground - Double(n) * gap
                var line = Path()
                line.move(to: CGPoint(x: labelColumn, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(DesignColor.keyline.opacity(0.45)), style: StrokeStyle(lineWidth: 0.35, dash: [2, 2]))
                if n % every == 0 {
                    ctx.draw(Text(HeightRange.label(Double(n) * step)).font(.caption2).monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk),
                             at: CGPoint(x: labelColumn - 4, y: y), anchor: .trailing)
                }
                n += 1
            }
        }

        // horizontal arrangement: [figure or boot] gap [plant] [dimensions]
        let hMax = height.max * ppm
        let dimWidth = 56.0
        let figureWidth = showsFigure ? max(2, Self.figureAspect * ScaleFigure.height * ppm) : 0
        let personGap = showsFigure ? max(6, 1.0 * ppm) : max(4, 0.03 * ppm)
        let available = size.width - labelColumn - dimWidth - 8
        // the plant's drawn width: its shape, capped by the room left
        let reserved = showsFigure ? figureWidth + personGap : min(available * 0.35, 0.3 * ppm + personGap)
        let plantWidth = min(sil.aspect * hMax, max(24, available - reserved))
        let group = reserved + plantWidth
        let left = labelColumn + max(0, (available - group) / 2)
        let plantCentre = left + reserved + plantWidth / 2

        // ground: 1 pt ink, a short 45° earth hatch beneath
        var groundLine = Path()
        groundLine.move(to: CGPoint(x: 0, y: ground))
        groundLine.addLine(to: CGPoint(x: size.width, y: ground))
        var hatch = Path()
        var x = 2.0
        while x < size.width {
            hatch.move(to: CGPoint(x: x, y: ground + 0.5))
            hatch.addLine(to: CGPoint(x: x - 5, y: ground + 5.5))
            x += 4
        }
        ctx.stroke(hatch, with: .color(ink.opacity(0.45)), lineWidth: 0.5)
        ctx.stroke(groundLine, with: .color(ink), lineWidth: 1)

        // scale figure or boot
        let grey = GraphicsContext.Shading.color(ink.opacity(0.4))
        if showsFigure {
            let h = ScaleFigure.height * ppm
            ctx.fill(ScaleFigure.path(base: CGPoint(x: left + figureWidth / 2, y: ground), height: h), with: grey)
        } else {
            let toe = plantCentre - plantWidth / 2 - personGap
            let (boot, details) = Boot.paths(toe: CGPoint(x: toe, y: ground), pointsPerMetre: ppm)
            let breakY = max(8, ground - plot * 0.9)
            let below = Path(CGRect(x: -1000, y: breakY, width: 4000, height: 2000))
            let clipped = boot.intersection(below)
            ctx.fill(clipped, with: grey)
            var detailCtx = ctx
            detailCtx.clip(to: below)
            detailCtx.stroke(details, with: .color(ink.opacity(0.55)), lineWidth: 0.5)
            let bounds = boot.boundingRect
            if bounds.minY < breakY {
                // a break line across the cut shaft
                let shaft = clipped.boundingRect
                let x0 = max(0, shaft.minX - 4), x1 = shaft.maxX + 4
                var zig = Path()
                zig.move(to: CGPoint(x: x0, y: breakY))
                let mid = (x0 + x1) / 2
                zig.addLine(to: CGPoint(x: mid - 3, y: breakY))
                zig.addLine(to: CGPoint(x: mid - 1, y: breakY - 4))
                zig.addLine(to: CGPoint(x: mid + 1, y: breakY + 4))
                zig.addLine(to: CGPoint(x: mid + 3, y: breakY))
                zig.addLine(to: CGPoint(x: x1, y: breakY))
                ctx.stroke(zig, with: .color(ink), lineWidth: 0.75)
            }
        }

        // the plant: maximum outline over a light fill, minimum dashed inside
        let base = CGPoint(x: plantCentre, y: ground)
        let tMax = sil.transform(base: base, height: hMax, width: plantWidth)
        let body = sil.body.applying(tMax)
        ctx.fill(body, with: .color(ink.opacity(0.12)))
        let outline = StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round)
        ctx.stroke(body, with: .color(ink), style: outline)
        ctx.stroke(sil.detail.applying(tMax), with: .color(ink), style: outline)
        let hasMin = !height.upTo && height.min < height.max
        let hMin = height.min * ppm
        if hasMin {
            let k = hMin / hMax
            let tMin = sil.transform(base: base, height: hMin, width: plantWidth * k)
            ctx.stroke(sil.body.applying(tMin), with: .color(ink),
                       style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round, dash: [2.5, 2]))
        }

        // dimension string: 0.35 pt line, 45° ticks at the ground and each
        // level, light hatch between the levels, labels beside
        let dimX = plantCentre + plantWidth / 2 + 12
        let yMax = ground - hMax, yMin = ground - hMin
        var dim = Path()
        dim.move(to: CGPoint(x: dimX, y: ground))
        dim.addLine(to: CGPoint(x: dimX, y: yMax - 3))
        let levels = hasMin ? [ground, yMin, yMax] : [ground, yMax]
        for y in levels {
            dim.move(to: CGPoint(x: dimX - 3, y: y + 3))
            dim.addLine(to: CGPoint(x: dimX + 3, y: y - 3))
        }
        // extension lines from the drawing to the string
        var ext = Path()
        ext.move(to: CGPoint(x: plantCentre + 2, y: yMax))
        ext.addLine(to: CGPoint(x: dimX + 4, y: yMax))
        if hasMin {
            ext.move(to: CGPoint(x: plantCentre + 2, y: yMin))
            ext.addLine(to: CGPoint(x: dimX + 4, y: yMin))
        }
        ctx.stroke(ext, with: .color(DesignColor.keyline), lineWidth: 0.35)
        if hasMin, yMin - yMax > 3 {
            let band = CGRect(x: dimX - 7, y: yMax, width: 6, height: yMin - yMax)
            var lines = Path()
            var y = band.minY - band.width
            while y < band.maxY {
                lines.move(to: CGPoint(x: band.minX, y: y + band.width))
                lines.addLine(to: CGPoint(x: band.maxX, y: y))
                y += 3
            }
            var clip = ctx
            clip.clip(to: Path(band))
            clip.stroke(lines, with: .color(ink.opacity(0.35)), lineWidth: 0.35)
        }
        ctx.stroke(dim, with: .color(ink), lineWidth: 0.35)

        // level labels, kept apart when the levels are close
        let maxLabelY = max(7, yMax)
        ctx.draw(label(height.upTo ? "to \(HeightRange.label(height.max))" : HeightRange.label(height.max)),
                 at: CGPoint(x: dimX + 6, y: maxLabelY), anchor: .leading)
        if hasMin {
            let y = max(yMin, maxLabelY + 13)
            if y <= ground - 5 {
                ctx.draw(label(HeightRange.label(height.min)), at: CGPoint(x: dimX + 6, y: y), anchor: .leading)
            }
        }
    }

    private func label(_ s: String) -> Text {
        Text(s).font(.caption2).monospacedDigit().foregroundStyle(DesignColor.ink)
    }

    /// The figure's width : height.
    static let figureAspect = 0.27
}

/// The conventional elevation figure: a person seen from the front, filled
/// grey, no face — head about 1/7.5 of the height. Built in metres.
enum ScaleFigure {
    static let height = ElevationScale.person

    /// The figure standing on `base` (centre of the feet), `height` points tall.
    static func path(base: CGPoint, height h: Double) -> Path {
        let u = h / 7.5   // head height
        var p = Path()
        func r(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + x * h, y: base.y - y * h) }
        // head
        p.addEllipse(in: CGRect(x: base.x - 0.42 * u, y: base.y - h, width: 0.84 * u, height: u))
        // neck to shoulders, torso to hips (one outline with the arms)
        p.move(to: r(-0.03, 1 - u / h - 0.005))
        p.addLine(to: r(-0.03, 0.835))
        p.addQuadCurve(to: r(-0.13, 0.805), control: r(-0.12, 0.83))
        p.addLine(to: r(-0.145, 0.62))      // upper arm
        p.addLine(to: r(-0.15, 0.45))       // forearm
        p.addQuadCurve(to: r(-0.12, 0.45), control: r(-0.135, 0.42))
        p.addLine(to: r(-0.115, 0.62))
        p.addLine(to: r(-0.1, 0.52))        // waist
        p.addLine(to: r(-0.105, 0.47))      // hip
        p.addLine(to: r(-0.075, 0.02))      // outer leg
        p.addLine(to: r(-0.085, 0))
        p.addLine(to: r(-0.02, 0))
        p.addLine(to: r(-0.015, 0.42))      // inner leg up to the crotch
        p.addLine(to: r(0.015, 0.42))
        p.addLine(to: r(0.02, 0))
        p.addLine(to: r(0.085, 0))
        p.addLine(to: r(0.075, 0.02))
        p.addLine(to: r(0.105, 0.47))
        p.addLine(to: r(0.1, 0.52))
        p.addLine(to: r(0.115, 0.62))
        p.addLine(to: r(0.12, 0.45))
        p.addQuadCurve(to: r(0.15, 0.45), control: r(0.135, 0.42))
        p.addLine(to: r(0.145, 0.62))
        p.addLine(to: r(0.13, 0.805))
        p.addQuadCurve(to: r(0.03, 0.835), control: r(0.12, 0.83))
        p.addLine(to: r(0.03, 1 - u / h - 0.005))
        p.closeSubpath()
        return p
    }
}

/// A walking boot in side elevation, toe forward (to the right), 30 cm to
/// the top of the shaft: the scale figure at the enlarged scales.
enum Boot {
    /// The outline (filled grey like the figure) and its drawn details
    /// (the sole's top edge, the lacing), toe tip on `toe`.
    static func paths(toe: CGPoint, pointsPerMetre k: Double) -> (body: Path, details: Path) {
        // metres, x back from the toe (negative), y up from the ground
        func q(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: toe.x + x * k, y: toe.y - y * k) }
        var p = Path()
        p.move(to: q(-0.285, 0))
        p.addLine(to: q(-0.012, 0))
        p.addQuadCurve(to: q(0, 0.03), control: q(0.004, 0.004))           // sole at the toe
        p.addQuadCurve(to: q(-0.055, 0.078), control: q(0.002, 0.075))     // toe cap
        p.addLine(to: q(-0.125, 0.11))                                      // vamp
        p.addQuadCurve(to: q(-0.165, 0.2), control: q(-0.155, 0.13))       // instep
        p.addLine(to: q(-0.17, 0.3))                                        // shaft front
        p.addQuadCurve(to: q(-0.275, 0.3), control: q(-0.22, 0.315))       // collar
        p.addLine(to: q(-0.28, 0.16))                                       // shaft back
        p.addQuadCurve(to: q(-0.3, 0.035), control: q(-0.305, 0.08))       // heel counter
        p.addLine(to: q(-0.285, 0))
        p.closeSubpath()
        var d = Path()
        d.move(to: q(-0.29, 0.03))
        d.addQuadCurve(to: q(-0.004, 0.03), control: q(-0.15, 0.024))     // top of the sole
        for (x, y) in [(-0.135, 0.13), (-0.15, 0.17), (-0.158, 0.21), (-0.162, 0.25)] {
            d.move(to: q(x, y))                                             // laces
            d.addLine(to: q(x - 0.04, y + 0.008))
        }
        return (p, d)
    }
}

/// The drawing's ratio and a checkered bar in round metres or centimetres
/// (DESIGN.md's map scale bar: ink/paper segments 4 pt tall, 0.5 pt
/// keyline, labels in small monospaced digits, unit on the last figure).
struct ElevationScaleBar: View {
    let scale: ElevationScale

    var body: some View {
        let bar = scale.scaleBar(maxPoints: 80)
        let length = bar.metres * scale.pointsPerMetre
        let cm = bar.metres < 1
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(scale.label)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DesignColor.ink)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(0 ..< bar.segments, id: \.self) { i in
                        Rectangle()
                            .fill(i % 2 == 0 ? DesignColor.ink : Color.clear)
                            .frame(width: length / Double(bar.segments), height: 4)
                    }
                }
                .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: length, height: 1)
                    ForEach(Array([0, bar.metres].enumerated()), id: \.offset) { i, v in
                        let last = i == 1
                        Text(Self.figure(cm ? v * 100 : v) + (last ? (cm ? " cm" : " m") : ""))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                            .fixedSize()
                            // "0" starts at the bar, the total ends with it
                            .alignmentGuide(.leading) { d in i == 0 ? 0 : d.width - length }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func figure(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
