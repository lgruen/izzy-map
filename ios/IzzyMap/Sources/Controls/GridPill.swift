import IzzyKit
import SwiftUI

/// Bottom leading: the scale bar over the map centre's position, in one
/// glass cluster (docs/DESIGN.md §4 "Scale bar"). The readout shows the
/// MGA55 grid reference; a tap switches to latitude/longitude (IzzyKit's
/// `GridReadout` is the one formatter). Observes only `MapLiveState`, so a
/// pan re-renders this cluster and not the root.
struct GridPill: View {
    let map: MapLiveState
    @State private var readout: GridReadout = .mga
    @Environment(\.horizontalSizeClass) private var widthClass

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.body("GridPill")
        #endif
        if let centre = map.centre {
            VStack(alignment: .leading, spacing: 3) {
                if let scale = ScaleBarModel(metresPerPoint: map.metresPerPoint(atLatitude: centre.latitude),
                                             maxWidth: widthClass == .regular ? 160 : 120) {
                    ScaleBar(scale: scale)
                }
                Button {
                    readout = readout.toggled
                } label: {
                    Text(readout.text(latitude: centre.latitude, longitude: centre.longitude))
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(DesignColor.ink)
                        .frame(minHeight: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(readout.spokenText(latitude: centre.latitude, longitude: centre.longitude))
                .accessibilityHint("Switches between grid reference and latitude and longitude")
                .accessibilityIdentifier("grid-pill")
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .mapChrome()
            .accessibilityElement(children: .contain)
        }
    }
}

extension MapLiveState {
    /// Ground metres per screen point at `latitude` for the current zoom.
    /// MapLibre's zoom 0 is one 512 pt tile for the whole Web Mercator
    /// world; each level halves the metres per point; Mercator stretches
    /// by 1 / cos(latitude).
    func metresPerPoint(atLatitude latitude: Double) -> Double {
        ScaleBarModel.metresPerPoint(zoom: zoom, latitude: latitude)
    }
}

/// The scale bar's length and label: the longest "nice" ground distance
/// (1, 2 or 5 × 10ⁿ m) that fits in `maxWidth` points.
nonisolated struct ScaleBarModel: Equatable, Sendable {
    /// Bar length on screen, points.
    let width: Double
    /// Ground distance it stands for, metres.
    let metres: Double

    /// Web Mercator equatorial circumference (2π × 6 378 137 m).
    static let circumference = 40_075_016.686

    static func metresPerPoint(zoom: Double, latitude: Double) -> Double {
        circumference * cos(latitude * .pi / 180) / (512 * pow(2, zoom))
    }

    init?(metresPerPoint mpp: Double, maxWidth: Double) {
        guard mpp.isFinite, mpp > 0, maxWidth > 0 else { return nil }
        let limit = mpp * maxWidth
        let magnitude = pow(10, floor(log10(limit)))
        let nice = [5.0, 2, 1].map { $0 * magnitude }.first { $0 <= limit } ?? magnitude
        metres = nice
        width = nice / mpp
    }

    /// "500 m", "1 km", "20 km" (no-break space before the unit).
    var label: String {
        metres >= 1000
            ? "\(Self.figure(metres / 1000))\u{00A0}km"
            : "\(Self.figure(metres))\u{00A0}m"
    }

    /// VoiceOver: "Scale, 1 kilometre".
    var spoken: String {
        let measure = Measurement(value: metres >= 1000 ? metres / 1000 : metres,
                                  unit: metres >= 1000 ? UnitLength.kilometers : UnitLength.meters)
        return "Scale, " + measure.formatted(.measurement(width: .wide, usage: .asProvided))
    }

    private static func figure(_ value: Double) -> String {
        value >= 1 ? String(Int(value.rounded())) : String(format: "%g", value)
    }
}

/// A cartographic scale bar: a thin ink line with end ticks between "0" and
/// the one labelled length — printed matter, square ends, no fill.
private struct ScaleBar: View {
    let scale: ScaleBarModel

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text(verbatim: "0")
            ScaleLine()
                .frame(width: scale.width, height: 7)
                .animation(.snappy(duration: 0.2), value: scale.width)
            Text(scale.label)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(DesignColor.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scale.spoken)
        .accessibilityIdentifier("scale-bar")
    }
}

/// The bar itself: a 1.5 pt line, 7 pt end ticks, all ink.
private nonisolated struct ScaleLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: rect.midY - 0.75, width: rect.width, height: 1.5))
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: 1.5, height: rect.height))
        path.addRect(CGRect(x: rect.maxX - 1.5, y: rect.minY, width: 1.5, height: rect.height))
        return path
    }
}
