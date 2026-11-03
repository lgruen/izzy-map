import IzzyKit
import SwiftUI

/// Framing a detailed area (UX_VISUAL_REVIEW §3.15): the map moves under a
/// fixed dashed frame (north up); the glass bar above says what to do
/// ("Move the map to fit the box"), what the frame would take — "0.5–0.8 MB
/// · 570 × 740 m" — and a gauge filling toward the per-download limit
/// (labelled "limit"); past it the gauge and the frame hatch, the line says
/// "Too big — zoom in" and Next stays off (red stays for delete).
nonisolated enum AreaFramingMetrics {
    /// The frame inside the uncovered map: inset 8 % of its width and 10 %
    /// of its height on each side (the web app's frame).
    static func frame(in uncovered: CGRect) -> CGRect? {
        let r = uncovered.insetBy(dx: uncovered.width * 0.08, dy: uncovered.height * 0.10)
        return r.width >= 60 && r.height >= 60 ? r : nil
    }

    /// "4.2 × 3.1 km", "570 × 740 m", "850 m × 1.2 km" (no-break spaces:
    /// the figure never splits across lines).
    static func size(_ box: AreaBox) -> String {
        let (w, h) = box.sizeMetres
        func metres(_ m: Double) -> Int { Int((m / 10).rounded()) * 10 }
        func km(_ m: Double) -> String {
            m < 1000 ? "\(metres(m))\u{00A0}m" : String(format: "%.1f\u{00A0}km", m / 1000)
        }
        if w >= 1000, h >= 1000 { return String(format: "%.1f\u{00A0}×\u{00A0}%.1f\u{00A0}km", w / 1000, h / 1000) }
        if w < 1000, h < 1000 { return "\(metres(w))\u{00A0}×\u{00A0}\(metres(h))\u{00A0}m" }
        return "\(km(w))\u{00A0}×\u{00A0}\(km(h))"
    }

    /// "0.5–0.8 MB", "12–19 MB", "0.9–1.4 GB": a size range in the larger
    /// end's unit (no-break spaces).
    static func range(_ r: ClosedRange<Int64>) -> String {
        let high = Double(r.upperBound), low = Double(r.lowerBound)
        let gb = high >= 1e9
        let unit = gb ? 1e9 : 1e6
        func digits(_ v: Double) -> String {
            let x = v / unit
            return x < 10 ? String(format: "%.1f", x) : String(Int(x.rounded()))
        }
        let lo = digits(low), hi = digits(high)
        let suffix = gb ? "\u{00A0}GB" : "\u{00A0}MB"
        return lo == hi ? "≈\u{00A0}\(hi)\(suffix)" : "\(lo)–\(hi)\(suffix)"
    }

    /// "~1 MB", "~40 MB", "~1.4 GB": the range's top, rounded up, for a button.
    static func roughly(_ r: ClosedRange<Int64>) -> String {
        let b = Double(r.upperBound)
        if b < 1e9 {
            let mb = b / 1e6
            let v = mb < 1 ? 1 : mb < 10 ? (mb).rounded(.up) : (mb / 5).rounded(.up) * 5
            return "~\(Int(v))\u{00A0}MB"
        }
        return "~" + String(format: "%.1f", (b / 1e8).rounded(.up) / 10) + "\u{00A0}GB"
    }

    /// The framing bar's line for a box that fits: its likely size (aerial
    /// photos at Fine, the range from finished areas) and its ground size.
    static func line(_ box: AreaBox, range: ClosedRange<Int64>) -> String {
        "\(Self.range(range)) · \(size(box))"
    }

    static let tooBig = "Too big — zoom in"
}

/// The frame, greyed when the box under it is too large (its own view: it
/// reads the 60 Hz box, the root doesn't).
struct AreaFrameLayer: View {
    let map: MapLiveState
    let rect: CGRect

    var body: some View {
        AreaFrameOverlay(rect: rect, fits: map.framedBox.map(AreaPlan.fitsFraming) ?? true)
    }
}

/// The dashed frame (and the dimmed map around it). Never takes touches.
struct AreaFrameOverlay: View {
    let rect: CGRect
    let fits: Bool

    var body: some View {
        Canvas { ctx, size in
            // outside the frame: an ink veil, so the frame reads as a window
            // (photos too)
            var veil = Path(CGRect(origin: .zero, size: size))
            veil.addRect(rect)
            ctx.fill(veil, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
            let frame = Path(rect)
            if !fits {
                // grey hatching: too large
                ctx.fill(frame, with: .color(.gray.opacity(0.25)))
                var hatch = Path()
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    hatch.move(to: CGPoint(x: x, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    x += 14
                }
                ctx.drawLayer { layer in
                    layer.clip(to: frame)
                    layer.stroke(hatch, with: .color(.white.opacity(0.45)), lineWidth: 1)
                }
            }
            // white under black dashes: legible over photos and paper alike
            ctx.stroke(frame, with: .color(.white.opacity(0.9)), lineWidth: 3.5)
            ctx.stroke(frame, with: .color(fits ? .black : .gray),
                       style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The framed box while its setup shows as the side card: drawn where the
/// map has it (`MapLiveState.draftRect`), the same frame and veil.
struct AreaDraftLayer: View {
    let map: MapLiveState

    var body: some View {
        if let rect = map.draftRect, rect.width > 1, rect.height > 1 {
            AreaFrameOverlay(rect: rect, fits: true)
        }
    }
}

/// The glass bar: what to do, the live size and gauge, Cancel and Next.
struct AreaFramingBar: View {
    let model: AppModel
    /// Re-renders with the frame's box (60 Hz on a pan: only this view).
    let map: MapLiveState

    private var box: AreaBox? { map.framedBox }
    private var fits: Bool { box.map(AreaPlan.fitsFraming) ?? false }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.cancelFraming() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignColor.ink)
            .hoverEffect(.highlight)
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("framing-cancel")

            VStack(alignment: .leading, spacing: 4) {
                Text("Move the map to fit the box")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Next") { model.framingNext() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glassProminent)
                .disabled(!fits)
                .accessibilityIdentifier("framing-next")
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        // the system's legibility glass: map labels must not read through the words
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .mapChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("framing-bar")
    }

    @ViewBuilder private var details: some View {
        if let box {
            let fill = AreaPlan.framingFill(box)
            let nominal = AreaPlan.estimate(box, layer: .aerial, detail: AreaPlan.framingDetail).bytes
            Text(fits ? AreaFramingMetrics.line(box, range: model.shared.areas.range(.aerial, nominal: nominal))
                      : AreaFramingMetrics.tooBig)
                .font(.footnote).monospacedDigit()
                .foregroundStyle(DesignColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("framing-size")
            LimitGauge(fill: fill)
        } else {
            Text(" ").font(.footnote)
        }
    }
}

/// How much of one download's limit the frame takes: a track of at least
/// 120 pt ending in "limit"; past it the track hatches (grey, never red).
/// Tiles are counted exactly, so the fill has no uncertainty band — the
/// size's range is in the words above it.
struct LimitGauge: View {
    let fill: Double

    var body: some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                ctx.fill(track, with: .color(DesignColor.ink.opacity(0.12)))
                if fill > 1 {
                    var hatch = Path()
                    var x = -size.height
                    while x < size.width {
                        hatch.move(to: CGPoint(x: x, y: size.height))
                        hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 5
                    }
                    var clipped = ctx
                    clipped.clip(to: track)
                    clipped.fill(track, with: .color(DesignColor.inkSecondary.opacity(0.5)))
                    clipped.stroke(hatch, with: .color(DesignColor.ink.opacity(0.55)), lineWidth: 1.2)
                } else {
                    let w = max(size.height, size.width * fill)
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: size.height / 2),
                             with: .color(DesignColor.ink))
                }
            }
            .frame(minWidth: 120, maxWidth: 220, minHeight: 6, maxHeight: 6)
            Text("limit")
                .font(.caption2)
                .foregroundStyle(DesignColor.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share of one download's limit")
        .accessibilityValue(fill > 1 ? "over the limit" : "\(Int((fill * 100).rounded())) percent")
        .accessibilityIdentifier("framing-gauge")
    }
}
