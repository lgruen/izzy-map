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
/// Paint order: … trees → pins → selection (the red ring stays last and
/// marks the selected pin). The mark is printed matter: a disc in the pin's
/// colour inside a white halo and a thin ink keyline, 4 pt at z6 growing to
/// 8 pt from z14; no clustering (colour is the data). From z14 the title,
/// folded to Latin-1 (`MapText.latin1Label`), sits under the mark.
final class PinPresenter {
    typealias L = StyleBuilder.LayerID
    private var applied: Int?
    private var features: [MLNPointFeature] = []

    /// The disc's radius by zoom (the halo and keyline add `outerExtra`).
    static let radius: [Any] = ["interpolate", ["linear"], ["zoom"], 6, 4, 14, 8]
    static let halo = 2.0
    static let keyline = 0.75
    /// Ink of the keyline and the label.
    static let ink = UIColor(white: 0.08, alpha: 1)
    /// Half the side of the box a tap looks for a pin in (fingertip).
    static let hitRadius: CGFloat = 16

    /// The store changed (`PinStore.revision`), or a first look.
    func apply(_ store: PinStore, to map: MLNMapView) {
        guard store.revision != applied else { return }
        applied = store.revision
        features = Self.features(store.mapPins)
        if let source = map.style?.source(withIdentifier: StyleBuilder.SourceID.pins) as? MLNShapeSource {
            source.shape = MLNShapeCollectionFeature(shapes: features)
        } else {
            addLayers(map)
        }
    }

    /// A reloaded style starts without our layers.
    func styleLoaded(_ map: MLNMapView, store: PinStore) {
        features = Self.features(store.mapPins)
        applied = store.revision
        addLayers(map)
    }

    /// Point features: `id` (the record's UUID), `color` (hex) and `label`
    /// (Latin-1 title, empty for none).
    static func features(_ pins: [SavedPin]) -> [MLNPointFeature] {
        pins.map { pin in
            let f = MLNPointFeature()
            f.coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
            f.attributes = [
                "id": pin.id.uuidString,
                "color": PinColour.hex(forName: pin.effectiveColourName),
                "label": MapText.latin1Label(pin.title) ?? "",
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

        let radius = NSExpression(mglJSONObject: Self.radius)
        // white halo with the ink keyline round it (strokes sit outside the
        // radius): reads on white topo, dark photos and every fill
        let halo = MLNCircleStyleLayer(identifier: L.pinsHalo, source: source)
        halo.circleRadius = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 6, 4 + Self.halo, 14, 8 + Self.halo] as [Any])
        halo.circleColor = NSExpression(forConstantValue: UIColor.white)
        halo.circleStrokeColor = NSExpression(forConstantValue: Self.ink)
        halo.circleStrokeWidth = NSExpression(forConstantValue: Self.keyline)

        let mark = MLNCircleStyleLayer(identifier: L.pinsMark, source: source)
        mark.circleRadius = radius
        mark.circleColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]] as [Any])
        // a hairline of the colour's own shade: a light gold or pink disc
        // keeps its edge against the white halo
        mark.circleStrokeColor = NSExpression(forConstantValue: UIColor(white: 0, alpha: 0.22))
        mark.circleStrokeWidth = NSExpression(forConstantValue: 0.5)

        let label = MLNSymbolStyleLayer(identifier: L.pinsLabel, source: source)
        label.minimumZoomLevel = 14
        label.predicate = NSPredicate(format: "label != ''")
        label.text = NSExpression(forKeyPath: "label")
        label.textFontNames = NSExpression(forConstantValue: StyleBuilder.boldFont)
        label.textFontSize = NSExpression(forConstantValue: 11)
        label.textColor = NSExpression(forConstantValue: Self.ink)
        label.textHaloColor = NSExpression(forConstantValue: UIColor(white: 1, alpha: 0.9))
        label.textHaloWidth = NSExpression(forConstantValue: 1.5)
        label.textAnchor = NSExpression(forConstantValue: "top")
        // below the mark, clear of the selection ring (12 pt + its 3 pt stroke)
        label.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.3)))
        label.maximumTextWidth = NSExpression(forConstantValue: 10)
        label.textOptional = NSExpression(forConstantValue: true)

        // above the trees, below the selection (its ring marks a pin)
        let anchor = L.selection.lazy.compactMap { style.layer(withIdentifier: $0) }.first
        for layer in [halo, mark, label] {
            if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
        }
    }

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

    /// The selection ring's shape for a pin (the `pin` property sizes it).
    static func selectionShape(_ pin: SavedPin) -> MLNShape {
        let ring = MLNPointFeature()
        ring.coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
        ring.attributes = ["pin": true]
        return ring
    }
}
