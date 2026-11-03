import CoreLocation
import IzzyKit
import MapLibre
import UIKit

/// "Show on map" on the map view (the model side is Spotlight.swift):
///
/// - **Fade**: every other community at 10 % (style-level `case`
///   expressions on the fill, band and code labels — data-driven paint,
///   supported for these properties). The soloed community's own tile fill
///   shows only from z11, where the tiles hold the real polygons.
/// - **Presence below z9**: the low-zoom TASVEG tiles are dominant-class
///   generalisations — below z9 small patches drop out and a community like
///   DAM nearly vanishes statewide. So there the community is drawn from
///   where.bin instead: one GeoJSON source built once per spotlight
///   (`Spotlight.presenceGeoJSON`): the cells dissolved into regions in the
///   official fill, ONE white-haloed graphite casing round each region (no
///   keyline per cell), traces as a pale tint, a rare community's patches
///   as ringed dots. From z9 its own polygons (`Spotlight.polygonsFrom`,
///   chosen by looking).
/// - **Framing**: the overview frames the core (90 % of the area) for the
///   view's own shape, never closer than z12; a patch is framed whole, never
///   closer than z15 — both fully inside the map area no chrome covers
///   (`MapFraming`), centred there (`MapCamera`).
/// - **The stepped-to patch**: the red selection line on its polygon, by
///   feature id (z ≥ 11 tiles carry stable ids) — looked up at the patch's
///   label point once the flight has ended and its tiles are drawn; below
///   z11 a red ring on that point.
///
/// Runtime layers (supported `MLNStyle` API), re-added after every style
/// reload; StyleBuilder's style JSON never holds them.
final class SpotlightPresenter {
    private let camera: MapCamera
    private var applied: Spotlight?
    private var cameraBefore: MapCamera.Saved?
    private var fadedPaint: [(layer: String, restore: (MLNStyleLayer) -> Void)] = []
    /// The stepped-to patch's label point, until its polygon's id is found.
    private var patchLookup: CLLocationCoordinate2D?
    private var patchID: UInt64?
    /// The unobscured map area, as insets from the map's bounds.
    private var framing: UIEdgeInsets = .zero

    typealias L = StyleBuilder.LayerID

    /// Room between a framed extent and the chrome around it.
    static let margin: CGFloat = 16

    init(camera: MapCamera) {
        self.camera = camera
    }

    /// Solo the spotlight's community and frame what it shows; when it
    /// goes, unfade and — on an exit (`restoreCamera`) — fly back.
    func apply(_ spotlight: Spotlight?, framing: UIEdgeInsets, model: AppModel, to map: MLNMapView) {
        self.framing = framing
        guard spotlight != applied else { return }
        let old = applied
        applied = spotlight
        guard let spotlight else {
            removeLayers(map)
            clearFade(map)
            patchLookup = nil
            patchID = nil
            if model.spotlightRestoresCamera, let saved = cameraBefore { camera.restore(map, to: saved) }
            cameraBefore = nil
            return
        }
        if old?.code != spotlight.code {
            addLayers(map, model: model)
            applyFade(map, model: model)
        }
        if old?.step != spotlight.step || old?.code != spotlight.code { stepped(map) }
        if old == nil {
            cameraBefore = camera.save(map)
            // the phone's sheet drops to its glance first: frame once the
            // chrome has settled, with the insets it then has (a gesture
            // before then cancels it)
            camera.schedule(after: 0.4) { [weak self, weak map] in
                guard let self, let map, let current = self.applied, current.code == spotlight.code else { return }
                self.frame(current, in: map)
            }
        } else {
            frame(spotlight, in: map)
        }
    }

    /// A reloaded style starts with its own paint and without our layers.
    func styleLoaded(_ map: MLNMapView, model: AppModel) {
        fadedPaint = []
        guard applied != nil else { return }
        addLayers(map, model: model)
        applyFade(map, model: model)
        applyPatchFilters(map)
    }

    /// The camera settled and its tiles are drawn: find the stepped-to
    /// patch's polygon id if still missing.
    func idle(_ map: MLNMapView, model: AppModel) {
        #if DEBUG
        debugLaunch(model: model)
        #endif
        guard let spotlight = applied, let point = patchLookup,
              map.zoomLevel >= Double(StyleBuilder.idMinZoom) else { return }
        let screen = map.convert(point, toPointTo: map)
        guard map.bounds.contains(screen) else { return }
        let same = NSPredicate(mglJSONObject: ["==", ["get", "VEGCODE"], spotlight.code] as [Any])
        var hits = map.visibleFeatures(at: screen, styleLayerIdentifiers: [L.tasvegFill], predicate: same)
        if hits.isEmpty {
            // a label point on a sliver tippecanoe dropped at this zoom: the
            // nearest polygon of the community within a fingertip
            let box = CGRect(x: screen.x - 6, y: screen.y - 6, width: 12, height: 12)
            hits = map.visibleFeatures(in: box, styleLayerIdentifiers: [L.tasvegFill], predicate: same)
        }
        guard let id = hits.lazy.compactMap({ ($0.identifier as? NSNumber)?.uint64Value }).first else { return }
        patchID = id
        patchLookup = nil
        applyPatchFilters(map)
    }

    #if DEBUG
    private static var debugLaunched = false
    /// Screenshots: `-debugShowOnMap DAM` runs "Show on map" for that code
    /// at the first idle, `-debugSpotlightStep n` then steps n patches.
    private func debugLaunch(model: AppModel) {
        let defaults = UserDefaults.standard
        guard !Self.debugLaunched, let code = defaults.string(forKey: "debugShowOnMap") else { return }
        Self.debugLaunched = true
        model.showOnMap(code)
        let steps = defaults.integer(forKey: "debugSpotlightStep")
        let every = defaults.double(forKey: "debugStepEvery")
        guard steps > 0 else { return }
        Task {
            for _ in 0 ..< steps {
                try? await Task.sleep(for: .seconds(every > 0 ? every : 2.5))
                model.stepSpotlight(1)
            }
        }
    }
    #endif

    // MARK: Stepping

    private func stepped(_ map: MLNMapView) {
        patchID = nil
        if let p = applied?.patchPoint {
            patchLookup = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        } else {
            patchLookup = nil
        }
        applyPatchFilters(map)
    }

    private func applyPatchFilters(_ map: MLNMapView) {
        guard let style = map.style else { return }
        (style.layer(withIdentifier: L.spotlightPatch) as? MLNVectorStyleLayer)?.predicate =
            NSPredicate(mglJSONObject: StyleBuilder.featureFilter(patchID))
        (style.layer(withIdentifier: L.spotlightPatchRing) as? MLNVectorStyleLayer)?.predicate =
            NSPredicate(format: "k == 'patch' AND n == %d", applied?.step ?? -1)
    }

    // MARK: Layers

    private func addLayers(_ map: MLNMapView, model: AppModel) {
        removeLayers(map)
        guard let style = map.style, let spotlight = applied else { return }
        let collection = Spotlight.presenceGeoJSON(cells: spotlight.cells, grid: spotlight.grid, patches: spotlight.patches,
                                                   patchCount: spotlight.patchCount)
        guard let json = try? JSONSerialization.data(withJSONObject: collection),
              let shape = try? MLNShape(data: json, encoding: String.Encoding.utf8.rawValue) else { return }
        let source = MLNShapeSource(identifier: StyleBuilder.SourceID.spotlight, shape: shape, options: nil)
        style.addSource(source)

        let fill = Self.color(model.communities[spotlight.code]?.color ?? StyleBuilder.fallbackFill)
        let graphite = UIColor(white: 0.12, alpha: 0.9)
        let below = Float(Spotlight.polygonsFrom)
        let ids = Float(StyleBuilder.idMinZoom)
        let regions = NSPredicate(format: "k == 'cell'")

        // one casing per dissolved region: a white halo under a fine
        // graphite line, so a pale fill reads on any base
        let halo = MLNLineStyleLayer(identifier: L.spotlightHalo, source: source)
        halo.predicate = regions
        halo.maximumZoomLevel = below
        halo.lineColor = NSExpression(forConstantValue: UIColor(white: 1, alpha: 0.85))
        halo.lineWidth = NSExpression(forConstantValue: 2.5)
        halo.lineJoin = NSExpression(forConstantValue: "miter")

        // fill only: the cells' own edges are never drawn
        let cells = MLNFillStyleLayer(identifier: L.spotlightCells, source: source)
        cells.predicate = NSPredicate(format: "k IN %@", ["cell", "trace"])
        cells.maximumZoomLevel = below
        cells.fillColor = NSExpression(forConstantValue: fill)
        cells.fillOpacity = NSExpression(forConditional: NSPredicate(format: "k == 'trace'"),
                                         trueExpression: NSExpression(forConstantValue: 0.4),
                                         falseExpression: NSExpression(forConstantValue: 1))

        let line = MLNLineStyleLayer(identifier: L.spotlightInk, source: source)
        line.predicate = regions
        line.maximumZoomLevel = below
        line.lineColor = NSExpression(forConstantValue: graphite)
        line.lineWidth = NSExpression(forConstantValue: 0.6)
        line.lineJoin = NSExpression(forConstantValue: "miter")

        // a rare community's patches: a dot in its fill below z11 (the
        // generalised tiles drop a 3 ha patch; it is a speck anyway) …
        let dots = MLNCircleStyleLayer(identifier: L.spotlightDots, source: source)
        dots.predicate = NSPredicate(format: "k == 'spot'")
        dots.maximumZoomLevel = ids
        dots.circleRadius = NSExpression(forConstantValue: 4.5)
        dots.circleColor = NSExpression(forConstantValue: fill)
        dots.circleStrokeColor = NSExpression(forConstantValue: graphite)
        dots.circleStrokeWidth = NSExpression(forConstantValue: 1)

        // … inside a ring at every zoom up to z14, around the real polygon
        // from z11 (a 1 ha patch is a few points there)
        let spots = MLNCircleStyleLayer(identifier: L.spotlightSpots, source: source)
        spots.predicate = NSPredicate(format: "k == 'spot'")
        spots.maximumZoomLevel = 14
        spots.circleRadius = NSExpression(forConstantValue: 11)
        spots.circleColor = NSExpression(forConstantValue: UIColor.clear)
        spots.circleStrokeColor = NSExpression(forConstantValue: graphite)
        spots.circleStrokeWidth = NSExpression(forConstantValue: 1.5)

        // the stepped-to patch below z11: a red ring on its label point
        let ring = MLNCircleStyleLayer(identifier: L.spotlightPatchRing, source: source)
        ring.maximumZoomLevel = ids
        ring.circleRadius = NSExpression(forConstantValue: 9)
        ring.circleColor = NSExpression(forConstantValue: UIColor.clear)
        ring.circleStrokeColor = NSExpression(forConstantValue: Self.color(StyleBuilder.selectionRed))
        ring.circleStrokeWidth = NSExpression(forConstantValue: StyleBuilder.selectionWidth)

        // above the faded fills, relief and boundaries; below the dashes,
        // codes, trees and the selection
        let anchor = [L.sameCommunity, L.tasvegLabel, L.selectedFeature, L.selectionOutline]
            .lazy.compactMap { style.layer(withIdentifier: $0) }.first
        for layer in [cells, halo, line, dots, spots, ring] {
            if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
        }

        // the stepped-to patch from z11: the selection's red line by id, on
        // the highlight source (filter changes re-lay out only its lines)
        if let highlight = style.source(withIdentifier: StyleBuilder.highlightSource(StyleBuilder.SourceID.tasveg)) {
            let patch = MLNLineStyleLayer(identifier: L.spotlightPatch, source: highlight)
            patch.sourceLayerIdentifier = "tasveg"
            patch.minimumZoomLevel = ids
            patch.lineColor = NSExpression(forConstantValue: Self.color(StyleBuilder.selectionRed))
            patch.lineWidth = NSExpression(forConstantValue: StyleBuilder.selectionWidth)
            patch.lineJoin = NSExpression(forConstantValue: "round")
            if let selected = style.layer(withIdentifier: L.selectedFeature) {
                style.insertLayer(patch, below: selected)
            } else {
                style.addLayer(patch)
            }
        }
        applyPatchFilters(map)
    }

    private func removeLayers(_ map: MLNMapView) {
        guard let style = map.style else { return }
        for id in L.spotlight {
            if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
        }
        if let source = style.source(withIdentifier: StyleBuilder.SourceID.spotlight) { style.removeSource(source) }
    }

    // MARK: Fade

    /// Others at 10 % at every zoom; the soloed community's tile fill near
    /// opaque in every strength, Outlines included — but only from z11:
    /// below, its dominant-class tiles would smear past the presence cells.
    private func applyFade(_ map: MLNMapView, model: AppModel) {
        clearFade(map)
        guard let style = map.style, let code = applied?.code, MapText.isLatin1(code) else { return }
        let fade = StyleBuilder.spotlightFade(code: code, fillOpacity: model.layers.fillOpacity)
        if let fill = style.layer(withIdentifier: L.tasvegFill) as? MLNFillStyleLayer {
            let original = fill.fillOpacity
            fill.fillOpacity = NSExpression(mglJSONObject: fade.fill)
            fadedPaint.append((L.tasvegFill, { ($0 as? MLNFillStyleLayer)?.fillOpacity = original }))
        }
        if let band = style.layer(withIdentifier: L.tasvegBand) as? MLNLineStyleLayer {
            let original = band.lineOpacity
            band.lineOpacity = NSExpression(mglJSONObject: fade.band)
            fadedPaint.append((L.tasvegBand, { ($0 as? MLNLineStyleLayer)?.lineOpacity = original }))
        }
        for layer in style.layers where layer.identifier.hasPrefix(L.tasvegLabel) {
            guard let label = layer as? MLNSymbolStyleLayer else { continue }
            let original = label.textOpacity
            label.textOpacity = NSExpression(mglJSONObject: fade.label)
            fadedPaint.append((label.identifier, { ($0 as? MLNSymbolStyleLayer)?.textOpacity = original }))
        }
    }

    private func clearFade(_ map: MLNMapView) {
        guard let style = map.style else { fadedPaint = []; return }
        for (id, restore) in fadedPaint {
            if let layer = style.layer(withIdentifier: id) { restore(layer) }
        }
        fadedPaint = []
    }

    // MARK: Camera

    /// Frame the spotlight's box whole inside the unobscured map area,
    /// centred there, no closer than its zoom cap.
    private func frame(_ spotlight: Spotlight, in map: MLNMapView) {
        #if DEBUG
        // `-debugSpotlightFrame NO`: the camera stays (drawing comparisons)
        if UserDefaults.standard.object(forKey: "debugSpotlightFrame") != nil,
           !UserDefaults.standard.bool(forKey: "debugSpotlightFrame") { return }
        #endif
        let insets = Self.insets(framing: framing)
        let view = map.bounds.inset(by: insets)
        let aspect = view.width > 1 && view.height > 1 ? Double(view.width / view.height) : 1
        let target = MapCamera.fit(spotlight.bounds(aspect: aspect), maxZoom: spotlight.maxZoom, insets: insets, in: map)
        camera.move(map, to: target, insets: insets, duration: 1.2)
    }

    /// The framing insets plus the margin.
    static func insets(framing: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: framing.top + margin, left: framing.left + margin,
                     bottom: framing.bottom + margin, right: framing.right + margin)
    }

    static func color(_ hex: String) -> UIColor {
        guard let c = MapColour.components(hex) else { return .gray }
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}
