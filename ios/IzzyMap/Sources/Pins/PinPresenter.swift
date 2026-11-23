import CoreLocation
import IzzyKit
import MapLibre
import UIKit

/// Saved pins on the map (docs/PINS_PLAN.md §4): runtime layers on one
/// `MLNShapeSource`, added after the style loads and re-added on every
/// style load (the `SpotlightPresenter` pattern) — never in the style JSON,
/// which the map compares as a string and reloads on any difference: an
/// edit to a pin must not reload the map.
///
/// Paint order: … trees → the polygon selection line → pins → the selected
/// pin → its red ring (the ring stays last). The mark is printed matter: a
/// disc in the pin's colour inside a white halo and a thin ink keyline,
/// 2.5 pt at z8 growing steeply to 8 pt at z14 (a cluster of pins stays a
/// cluster of colours at z9); no clustering (colour is the data). The
/// selected pin is drawn larger (15 pt) on top, so its colour still rings
/// the blue location dot when she pins where she stands. From z14 the
/// title, folded to Latin-1, is printed beside the mark — below it where
/// there is room, else above, right or left — in the tree names' face; the
/// marks are obstacles for every label below them (an invisible icon per
/// mark), so no label is printed over a pin.
final class PinPresenter {
    typealias L = StyleBuilder.LayerID
    /// What the source holds now: the store's revision, whether the Pins
    /// tile is on (Layers → Also show) and which pin is selected.
    private var applied: (revision: Int, visible: Bool, selected: UUID?)?
    /// What the source holds (empty while the Pins tile is off).
    private(set) var features: [MLNPointFeature] = []

    /// The disc's radius by zoom (the halo and keyline add to it): small
    /// at low zoom, so a few pins in a suburb stay separate marks.
    static let radius: [Any] = ["interpolate", ["exponential", 1.5], ["zoom"], 8, 2.5, 11, 4.5, 14, 8]
    /// The halo's outer radius: 1 pt round the disc below z11, 2 pt from z11.
    static let haloRadius: [Any] = ["interpolate", ["exponential", 1.5], ["zoom"], 8, 3.5, 11, 6.5, 14, 10]
    static let keyline = 0.75
    /// The selected pin's disc, at every zoom: larger than the location
    /// dot (~11 pt with its white rim), so a 4 pt band of the pin's colour
    /// shows round it when she pins where she stands.
    static let selectedRadius = 15.0
    static let selectedHalo = 2.0
    /// The selection ring's radius for a pin (StyleBuilder's ring layer):
    /// just outside the selected disc's keyline.
    static let ringRadius = StyleBuilder.pinRingRadius
    /// Ink of the keyline and the label.
    static let ink = UIColor(white: 0.08, alpha: 1)
    /// Half the side of the box a tap looks for a pin in (fingertip).
    static let hitRadius: CGFloat = 16
    /// The label's distance from the mark's centre, in ems of its 12 pt
    /// text: a few points clear of the halo — or, selected, of the red
    /// ring — and clear of the mark's own obstacle plus the label's 2 pt
    /// collision padding (else the label could never take its first place).
    static let labelSize = 12.0
    static let labelOffset = 1.35
    static let selectedLabelOffset = (ringRadius + StyleBuilder.selectionWidth + 4) / labelSize
    /// Longest title printed on the map (a paragraph is no label).
    static let labelLimit = 40
    /// The obstacle icon's side (transparent; scaled to the mark's size).
    static let obstacleImage = "pins-obstacle"
    private static let obstacleSide = 32.0

    /// The store changed (`PinStore.revision`), the Pins tile was switched,
    /// another pin was selected, or a first look. Switched off, the source
    /// is empty: nothing drawn, nothing a tap can hit (the layers stay, so
    /// switching back needs no style work).
    func apply(_ store: PinStore, visible: Bool, selected: UUID?, to map: MLNMapView) {
        guard applied?.revision != store.revision || applied?.visible != visible || applied?.selected != selected else { return }
        applied = (store.revision, visible, selected)
        features = visible ? Self.features(store.mapPins, selected: selected) : []
        if let source = map.style?.source(withIdentifier: StyleBuilder.SourceID.pins) as? MLNShapeSource {
            source.shape = MLNShapeCollectionFeature(shapes: features)
        } else {
            addLayers(map)
        }
    }

    /// A reloaded style starts without our layers.
    func styleLoaded(_ map: MLNMapView, store: PinStore, visible: Bool, selected: UUID?) {
        features = visible ? Self.features(store.mapPins, selected: selected) : []
        applied = (store.revision, visible, selected)
        addLayers(map)
    }

    /// A pin's map label: its own title only — never the note, never a
    /// date stand-in (a note is no name; dates would clutter) — clipped on
    /// a word boundary and folded to Latin-1; nil for none, or when even
    /// folded it isn't (no label rather than a dropped one).
    static func label(_ pin: SavedPin) -> String? {
        let title = pin.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return MapText.latin1Label(PinText.clipped(title, to: labelLimit))
    }

    /// Point features: `id` (the record's UUID), `color` (hex), `label`
    /// (Latin-1 title, empty for none) and `sel` (the selected pin: its
    /// label and obstacle make room for the larger disc and its ring).
    static func features(_ pins: [SavedPin], selected: UUID? = nil) -> [MLNPointFeature] {
        pins.map { pin in
            let f = MLNPointFeature()
            f.coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
            f.attributes = [
                "id": pin.id.uuidString,
                "color": PinColour.hex(forName: pin.effectiveColourName),
                "label": label(pin) ?? "",
                "sel": pin.id == selected,
            ]
            return f
        }
    }

    private func addLayers(_ map: MLNMapView) {
        guard let style = map.style else { return }
        for id in L.pins {
            if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
        }
        if let old = style.source(withIdentifier: StyleBuilder.SourceID.pins) { style.removeSource(old) }
        let source = MLNShapeSource(identifier: StyleBuilder.SourceID.pins,
                                    shape: MLNShapeCollectionFeature(shapes: features), options: nil)
        style.addSource(source)
        style.setImage(Self.obstacle, forName: Self.obstacleImage)

        // white halo with the ink keyline round it (strokes sit outside the
        // radius): reads on white topo, dark photos and every fill
        let halo = MLNCircleStyleLayer(identifier: L.pinsHalo, source: source)
        halo.circleRadius = NSExpression(mglJSONObject: Self.haloRadius)
        halo.circleColor = NSExpression(forConstantValue: UIColor.white)
        halo.circleStrokeColor = NSExpression(forConstantValue: Self.ink)
        halo.circleStrokeWidth = NSExpression(forConstantValue: Self.keyline)

        let mark = MLNCircleStyleLayer(identifier: L.pinsMark, source: source)
        mark.circleRadius = NSExpression(mglJSONObject: Self.radius)
        mark.circleColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]] as [Any])
        // a hairline of the colour's own shade: a light gold or pink disc
        // keeps its edge against the white halo
        mark.circleStrokeColor = NSExpression(forConstantValue: UIColor(white: 0, alpha: 0.22))
        mark.circleStrokeWidth = NSExpression(forConstantValue: 0.5)

        // the title in the tree names' face (Regular, ink on the white
        // halo): annotation, quieter than the Bold community codes
        let label = MLNSymbolStyleLayer(identifier: L.pinsLabel, source: source)
        label.minimumZoomLevel = 14
        label.predicate = NSPredicate(format: "label != ''")
        label.text = NSExpression(forKeyPath: "label")
        label.textFontNames = NSExpression(forConstantValue: StyleBuilder.regularFont)
        label.textFontSize = NSExpression(forConstantValue: Self.labelSize)
        label.textColor = NSExpression(forConstantValue: Self.ink)
        label.textHaloColor = NSExpression(forConstantValue: UIColor(white: 1, alpha: 0.85))
        label.textHaloWidth = NSExpression(forConstantValue: 1.5)
        // below the mark where it fits, else above, right or left of it
        label.textVariableAnchor = NSExpression(forConstantValue: ["top", "bottom", "right", "left"])
        label.textRadialOffset = NSExpression(mglJSONObject:
            ["case", ["==", ["get", "sel"], true], Self.selectedLabelOffset, Self.labelOffset] as [Any])
        label.textJustification = NSExpression(forConstantValue: "auto")
        label.maximumTextWidth = NSExpression(forConstantValue: 9)
        label.textOptional = NSExpression(forConstantValue: true)

        // the marks as obstacles: one invisible icon the size of each mark
        // (with its ring, selected), always placed, entered in the
        // collision index. Above the labels, so placed first: every label
        // of the map below it — pins' own, community codes, tree names —
        // keeps off the marks.
        let obstacle = MLNSymbolStyleLayer(identifier: L.pinsObstacle, source: source)
        obstacle.iconImageName = NSExpression(forConstantValue: Self.obstacleImage)
        obstacle.iconScale = NSExpression(mglJSONObject: Self.obstacleScale)
        obstacle.iconAllowsOverlap = NSExpression(forConstantValue: true)
        obstacle.iconIgnoresPlacement = NSExpression(forConstantValue: false)
        obstacle.iconPadding = NSExpression(forConstantValue: NSValue(uiEdgeInsets: .zero))

        // the selected pin, larger, from the selection's source (the ring
        // above it is StyleBuilder's selection layer)
        var selectedHalo: MLNCircleStyleLayer?
        var selectedMark: MLNCircleStyleLayer?
        if let selection = style.source(withIdentifier: StyleBuilder.SourceID.selection) {
            let isPin = NSPredicate(mglJSONObject: ["has", "pin"] as [Any])
            let h = MLNCircleStyleLayer(identifier: L.pinsSelectedHalo, source: selection)
            h.predicate = isPin
            h.circleRadius = NSExpression(forConstantValue: Self.selectedRadius + Self.selectedHalo)
            h.circleColor = NSExpression(forConstantValue: UIColor.white)
            h.circleStrokeColor = NSExpression(forConstantValue: Self.ink)
            h.circleStrokeWidth = NSExpression(forConstantValue: Self.keyline)
            let m = MLNCircleStyleLayer(identifier: L.pinsSelectedMark, source: selection)
            m.predicate = isPin
            m.circleRadius = NSExpression(forConstantValue: Self.selectedRadius)
            m.circleColor = NSExpression(mglJSONObject: ["to-color", ["coalesce", ["get", "color"], PinColour.fallbackHex]] as [Any])
            m.circleStrokeColor = NSExpression(forConstantValue: UIColor(white: 0, alpha: 0.22))
            m.circleStrokeWidth = NSExpression(forConstantValue: 0.5)
            selectedHalo = h
            selectedMark = m
        }

        // above the trees and a selected polygon's red line, below the
        // selection ring (its ring marks a pin, a tree, a tap)
        let anchor = style.layer(withIdentifier: L.selectionPoint)
        for layer in [halo, mark, label, obstacle, selectedHalo, selectedMark].compactMap({ $0 }) {
            if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
        }
    }

    /// The obstacle's scale by zoom: the halo's diameter plus its keyline;
    /// the selected pin's, its ring's outer diameter.
    static var obstacleScale: [Any] {
        let side = obstacleSide
        func mark(_ halo: Double) -> Double { 2 * (halo + keyline) / side }
        let selected = 2 * (ringRadius + StyleBuilder.selectionWidth) / side
        let sel: [Any] = ["==", ["get", "sel"], true]
        return ["interpolate", ["exponential", 1.5], ["zoom"],
                8, ["case", sel, selected, mark(3.5)] as [Any],
                11, ["case", sel, selected, mark(6.5)] as [Any],
                14, ["case", sel, selected, mark(10)] as [Any]]
    }

    /// A fully transparent square: only its box counts (collisions).
    private static let obstacle: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: obstacleSide, height: obstacleSide), format: format)
            .image { _ in }
    }()

    /// The pin under a tap: the nearest mark in a fingertip box.
    static func hit(at point: CGPoint, in map: MLNMapView) -> UUID? {
        guard map.style?.layer(withIdentifier: L.pinsMark) != nil else { return nil }
        let r = hitRadius
        let box = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
        let marks = map.visibleFeatures(in: box, styleLayerIdentifiers: [L.pinsMark, L.pinsHalo])
        guard let nearest = MapCoordinator.nearest(marks, to: point, in: map),
              let raw = nearest.attribute(forKey: "id") as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// The selection's shape for a pin: the `pin` property sizes the ring
    /// and draws the larger disc, in the pin's `color`.
    static func selectionShape(_ pin: SavedPin) -> MLNShape {
        let ring = MLNPointFeature()
        ring.coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
        ring.attributes = ["pin": true, "color": PinColour.hex(forName: pin.effectiveColourName)]
        return ring
    }
}
