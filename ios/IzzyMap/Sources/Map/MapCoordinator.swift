import CoreLocation
import IzzyKit
import MapLibre
import os
import UIKit

/// Delegate of the map view: camera, taps, user location.
final class MapCoordinator: NSObject {
    private let model: AppModel
    private weak var map: MLNMapView?
    private let cameraStore = CameraStore()
    private var appliedChrome: MapChrome?

    /// At launch, a fix arriving soon (before the user moves the map)
    /// recentres the map on it.
    private var awaitingLaunchFix = false
    private let launchFixDeadline = Date.now.addingTimeInterval(8)
    private var userMovedCamera = false
    /// Whether the selection source holds a shape (its getter doesn't say).
    private var showsSelectionShape = false
    /// The style as loaded, built without selection (the selection lives in
    /// runtime filters): a reload happens only when this text changes, never
    /// for a state change the map doesn't draw (finding 16).
    private var appliedStyleKey: String?
    /// What the selection layers show now, re-applied after a style reload.
    private var selectionStyle = SelectionStyle.none
    private var selectionShape: MLNShape?
    private var appliedHighlight: String?
    /// The tapped overlay polygon, to re-find its id when the tiles under
    /// the tap change (pre-1750's zoom bands carry their own ids; TASVEG has
    /// ids only from z11, so a polygon tapped at z10 gains its outline when
    /// zoomed in).
    private var anchor: OverlayAnchor?
    private var connectivity: Connectivity.Subscription?
    /// "Show on map": what the style shows, the camera to fly back to, and
    /// the paint values the fade replaced (restored when it ends).
    private var appliedSpotlight: Spotlight?
    private var cameraBeforeSpotlight: MLNMapCamera?
    private var fadedPaint: [(layer: String, restore: (MLNStyleLayer) -> Void)] = []
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Map")

    private struct OverlayAnchor {
        let coordinate: CLLocationCoordinate2D
        let overlay: Overlay
        /// VEGCODE / SYMB / MVS of the tapped polygon.
        let classKey: String
    }

    #if DEBUG
    /// `-debugTaps "0.5,0.4;0.3,0.6"`: normalised map points tapped one per
    /// idle after launch (screenshots, the finding-14 timing).
    private var debugTaps: [CGPoint] = (UserDefaults.standard.string(forKey: "debugTaps") ?? "")
        .split(separator: ";").compactMap { pair in
            let v = pair.split(separator: ",").compactMap { Double($0) }
            return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
        }
    private var tapStarted: ContinuousClock.Instant?
    private var openedLayers = false
    private static let timing = Logger(subsystem: "org.gruenschloss.izzymap", category: "Timing")
    #endif

    init(model: AppModel) {
        self.model = model
    }

    /// The style the map view is created with (scene-restored layers are
    /// already in the model, so there is no first wrong style).
    func initialStyleJSON() -> String {
        let json = model.styleJSON(selection: .none)
        appliedStyleKey = json
        return json
    }

    func attach(to map: MLNMapView) {
        self.map = map
        map.delegate = self
        map.automaticallyAdjustsContentInset = false
        map.showsLogoView = false
        // The app owns attribution (Attribution.swift + its own (i) control):
        // MapLibre's button would list PMTiles metadata, not our credits.
        map.showsAttributionButton = false
        map.minimumZoomLevel = CameraPolicy.minZoom
        map.maximumZoomLevel = CameraPolicy.maxZoom
        map.maximumScreenBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: CameraPolicy.minLatitude, longitude: CameraPolicy.minLongitude),
            ne: CLLocationCoordinate2D(latitude: CameraPolicy.maxLatitude, longitude: CameraPolicy.maxLongitude)
        )
        // the app draws its own scale bar (SwiftUI, from MapLiveState.zoom)
        map.showsScale = false
        map.compassViewPosition = .topRight
        map.isPitchEnabled = false

        let camera = CameraPolicy.initial(saved: cameraStore.load())
        map.setCenter(
            CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
            zoomLevel: camera.zoom, direction: camera.heading, animated: false
        )
        model.map.centre = map.centerCoordinate

        // Open at the GPS position when location is already allowed (never
        // ask at launch: the Location button asks when it is first used).
        let status = map.locationManager.authorizationStatus
        model.authorizationChanged(to: status)
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            awaitingLaunchFix = true
            map.showsUserLocation = true
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // taps on the map's own ornaments (compass) are theirs, not a feature tap
        tap.delegate = self
        // a double tap zooms; don't also treat it as two selections
        for recognizer in map.gestureRecognizers ?? [] {
            if let other = recognizer as? UITapGestureRecognizer, other.numberOfTapsRequired == 2 {
                tap.require(toFail: other)
            }
        }
        map.addGestureRecognizer(tap)

        // the live LIST sources follow the network path
        connectivity = Connectivity.shared.observe { [weak self] _ in self?.reloadStyleIfNeeded() }
    }

    // MARK: SwiftUI → map

    func apply(chrome: MapChrome, to map: MLNMapView) {
        guard chrome != appliedChrome else { return }
        if appliedChrome?.contentInset != chrome.contentInset {
            map.setContentInset(chrome.contentInset, animated: appliedChrome != nil, completionHandler: nil)
        }
        appliedChrome = chrome
        let compassWidth = map.compassView.bounds.width > 0 ? map.compassView.bounds.width : 40
        map.compassViewMargins = CGPoint(
            x: max(0, chrome.controlsCentreFromTrailing - compassWidth / 2),
            y: chrome.compassTop
        )
    }

    func apply(tracking: TrackingMode, to map: MLNMapView) {
        let wanted = Self.mapMode(tracking)
        guard map.userTrackingMode != wanted else { return }
        map.setUserTrackingMode(wanted, animated: true, completionHandler: nil)
    }

    /// A layer change re-sets the whole style: hidden layers and their
    /// sources are left out of it (StyleBuilder), and MapLibre keeps the
    /// tiles of every source whose definition didn't change. Only when the
    /// style the map would draw actually differs.
    func apply(layers: LayerState, to map: MLNMapView) {
        reloadStyleIfNeeded()
    }

    private func reloadStyleIfNeeded() {
        guard let map else { return }
        let key = model.styleJSON(selection: .none)
        guard key != appliedStyleKey else { return }
        appliedStyleKey = key
        map.styleJSON = selectionStyle == .none ? key : model.styleJSON(selection: selectionStyle)
    }

    /// A key row tapped in the legend: dash that community's polygons.
    func apply(keyHighlight: String?) {
        guard keyHighlight != appliedHighlight else { return }
        appliedHighlight = keyHighlight
        selectionStyle.community = model.selection?.communityCode ?? keyHighlight
        applySelectionFilters()
    }

    func clearSelectionShape() {
        anchor = nil
        guard showsSelectionShape || selectionStyle != SelectionStyle(community: model.keyHighlight) else { return }
        showsSelectionShape = false
        selectionShape = nil
        selectionSource?.shape = nil
        selectionStyle = SelectionStyle(community: model.keyHighlight)
        applySelectionFilters()
    }

    /// `shape`: a tree, or the tap ring — never an overlay polygon's tile
    /// geometry (that is the id filter's job, across every tile).
    private func showSelection(featureID: UInt64?, shape: MLNShape?) {
        selectionStyle = model.selectionStyle(featureID: featureID)
        selectionShape = shape
        selectionSource?.shape = selectionShape
        showsSelectionShape = selectionShape != nil
        applySelectionFilters()
    }

    /// The selection layers' filters, set on the loaded style (the JSON of a
    /// later reload carries the same values).
    private func applySelectionFilters() {
        guard let style = map?.style else { return }
        let id = NSPredicate(mglJSONObject: StyleBuilder.featureFilter(selectionStyle.featureID))
        (style.layer(withIdentifier: StyleBuilder.LayerID.selectedFeature) as? MLNVectorStyleLayer)?.predicate = id
        (style.layer(withIdentifier: StyleBuilder.LayerID.sameCommunity) as? MLNVectorStyleLayer)?.predicate =
            NSPredicate(mglJSONObject: StyleBuilder.sameCommunityFilter(selectionStyle.community))
    }

    private var selectionSource: MLNShapeSource? {
        map?.style?.source(withIdentifier: StyleBuilder.SourceID.selection) as? MLNShapeSource
    }

    // MARK: Show on map

    /// Solo the spotlight's community (others faded) and frame what it
    /// shows; when it goes, unfade and — on an exit — fly back.
    func apply(spotlight: Spotlight?, to map: MLNMapView) {
        guard spotlight != appliedSpotlight else { return }
        let old = appliedSpotlight
        appliedSpotlight = spotlight
        if let spotlight {
            if old?.code != spotlight.code { applyFade() }
            if old == nil {
                cameraBeforeSpotlight = map.camera
                // the phone's sheet drops to its glance first: frame once
                // the chrome has settled
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak map] in
                    guard let self, let map, let current = self.appliedSpotlight, current.code == spotlight.code else { return }
                    self.frame(current.bounds, in: map)
                }
            } else {
                frame(spotlight.bounds, in: map)
            }
        } else {
            clearFade()
            if model.spotlightRestoresCamera, let camera = cameraBeforeSpotlight {
                move(map, to: camera)
            }
            cameraBeforeSpotlight = nil
        }
    }

    /// Fade every other community (style-level `case` expressions on the
    /// fill, band and code labels — data-driven paint, supported by
    /// MapLibre for these properties); the soloed one near opaque in every
    /// strength, Outlines included, so it reads.
    private func applyFade() {
        clearFade()
        guard let style = map?.style, let code = appliedSpotlight?.code, MapText.isLatin1(code) else { return }
        typealias L = StyleBuilder.LayerID
        let state = model.layers
        // the soloed community well above Full strength: at a statewide
        // zoom its patches are specks and must still read
        let solo = max(0.85, state.fillOpacity)
        let others = min(0.1, state.fillOpacity)
        func pick(_ on: Double, _ off: Double) -> NSExpression {
            NSExpression(mglJSONObject: ["case", ["==", ["get", "VEGCODE"], code], on, off] as [Any])
        }
        if let fill = style.layer(withIdentifier: L.tasvegFill) as? MLNFillStyleLayer {
            let original = fill.fillOpacity
            fill.fillOpacity = pick(solo, others)
            fadedPaint.append((L.tasvegFill, { ($0 as? MLNFillStyleLayer)?.fillOpacity = original }))
        }
        if let band = style.layer(withIdentifier: L.tasvegBand) as? MLNLineStyleLayer {
            let original = band.lineOpacity
            band.lineOpacity = pick(1, 0.15)
            fadedPaint.append((L.tasvegBand, { ($0 as? MLNLineStyleLayer)?.lineOpacity = original }))
        }
        for layer in style.layers where layer.identifier.hasPrefix(L.tasvegLabel) {
            guard let label = layer as? MLNSymbolStyleLayer else { continue }
            let original = label.textOpacity
            label.textOpacity = pick(1, 0.3)
            fadedPaint.append((label.identifier, { ($0 as? MLNSymbolStyleLayer)?.textOpacity = original }))
        }
    }

    private func clearFade() {
        guard let style = map?.style else { fadedPaint = []; return }
        for (id, restore) in fadedPaint {
            if let layer = style.layer(withIdentifier: id) { restore(layer) }
        }
        fadedPaint = []
    }

    /// Frame [west, south, east, north] clear of the chrome (a tiny patch
    /// is padded so the camera stops short of street level).
    private func frame(_ box: [Double], in map: MLNMapView) {
        let b = Spotlight.padded(box)
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: b[1], longitude: b[0]),
                                         ne: CLLocationCoordinate2D(latitude: b[3], longitude: b[2]))
        let extra = appliedChrome?.framingInsets ?? .zero
        let padding = UIEdgeInsets(top: 20 + extra.top, left: 20 + extra.left,
                                   bottom: 20 + extra.bottom, right: 20 + extra.right)
        let camera = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: padding)
        camera.heading = 0
        move(map, to: camera)
    }

    /// A flight (Reduce Motion: a cut).
    private func move(_ map: MLNMapView, to camera: MLNMapCamera) {
        if UIAccessibility.isReduceMotionEnabled {
            map.setCamera(camera, animated: false)
        } else {
            map.fly(to: camera, withDuration: 1.2, completionHandler: nil)
        }
    }

    // MARK: Taps

    /// Half the side of the box a tree dot is looked up in: the dots are
    /// 7 pt, a fingertip is not.
    static let treeHitRadius: CGFloat = 12

    /// Hit priority: trees first (nearest dot in a 24 pt box, then a tree
    /// area under the finger), then the visible overlay. Hidden layers are
    /// not in the style, so this answers for whatever is on screen.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let map else { return }
        tap(at: gesture.location(in: map))
    }

    private func tap(at point: CGPoint) {
        guard let map, let style = map.style else { return }
        typealias L = StyleBuilder.LayerID
        #if DEBUG
        tapStarted = .now
        #endif

        if style.layer(withIdentifier: L.treesPoint) != nil {
            let r = Self.treeHitRadius
            let box = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
            let dots = map.visibleFeatures(in: box, styleLayerIdentifiers: Set(L.treePoints))
            if let nearest = Self.nearest(dots, to: point, in: map) {
                if let cluster = nearest as? MLNPointFeatureCluster {
                    zoomInto(cluster, map: map)
                    return
                }
                if selectTree(nearest, isArea: false) { return }
            }
            for area in map.visibleFeatures(at: point, styleLayerIdentifiers: [L.treesAreaFill]) {
                if selectTree(area, isArea: true) { return }
            }
        }

        let hits = map.visibleFeatures(at: point, styleLayerIdentifiers: Set(L.overlayFills))
        guard let feature = hits.first, let (overlay, key) = Self.overlayClass(feature) else {
            // an empty spot: everything highlighted goes (a soloed
            // community too, the camera staying where she is)
            model.endSpotlight()
            model.clearSelection()
            model.keyHighlight = nil
            clearSelectionShape()
            return
        }
        switch overlay {
        case .vegetation:
            var facts: [String: String] = [:]
            for k in ["VEG_GROUP", "FOREST_STR", "NOTABLE_TD", "WEED_TYP_D"] { facts[k] = Self.text(feature, k) }
            model.selectCommunity(code: key, sourceName: Self.text(feature, "VEGCODE_D"), attributes: facts,
                                  at: map.convert(point, toCoordinateFrom: map))
        case .geology: model.select(.geology(key))
        case .pre1750: model.select(.pre1750(key))
        case .none: return
        }
        let coordinate = map.convert(point, toCoordinateFrom: map)
        anchor = OverlayAnchor(coordinate: coordinate, overlay: overlay, classKey: key)
        // Below z11 TASVEG tiles hold generalised dominant-class bands
        // without ids: the card answers without an outline (it appears when
        // zoomed in, `refreshAnchoredSelection`). Elsewhere the id outlines
        // the whole polygon across tiles.
        let featureID = (feature.identifier as? NSNumber)?.uint64Value
        guard let featureID, map.zoomLevel >= Double(StyleBuilder.idMinZoom(overlay)) else {
            showSelection(featureID: nil, shape: nil)
            return
        }
        showSelection(featureID: featureID, shape: tapRing(for: featureID, overlay: overlay, at: coordinate, in: map))
    }

    /// The overlay and class key (VEGCODE / SYMB / MVS) of a fill feature.
    static func overlayClass(_ feature: any MLNFeature) -> (Overlay, String)? {
        if let code = text(feature, "VEGCODE") { return (.vegetation, code) }
        if let symb = text(feature, "SYMB") { return (.geology, symb) }
        if let mvs = text(feature, "MVS") { return (.pre1750, mvs) }
        return nil
    }

    static func text(_ feature: any MLNFeature, _ key: String) -> String? {
        if let s = feature.attribute(forKey: key) as? String { return s }
        return (feature.attribute(forKey: key) as? NSNumber)?.stringValue
    }

    /// A small ink ring where she tapped, when the polygon's outline can't
    /// say "this one" by itself: it spans most of the view (or runs off it),
    /// so the line is far from the finger. Measured over every on-screen
    /// piece of the polygon (by id), not just the tapped tile's.
    private func tapRing(for id: UInt64, overlay: Overlay, at coordinate: CLLocationCoordinate2D,
                         in map: MLNMapView) -> MLNShape? {
        guard let fill = Self.fillLayer(overlay) else { return nil }
        let pieces = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: [fill],
                                         predicate: NSPredicate(mglJSONObject: StyleBuilder.featureFilter(id)))
        var extent = CGRect.null
        for piece in pieces {
            guard let overlayShape = piece as? MLNOverlay else { continue }
            extent = extent.union(map.convert(overlayShape.overlayBounds, toRectTo: map))
        }
        let view = map.bounds.inset(by: map.contentInset)
        guard !extent.isNull, extent.width > 0.6 * view.width || extent.height > 0.6 * view.height else { return nil }
        let ring = MLNPointFeature()
        ring.coordinate = coordinate
        ring.attributes = ["tap": true]
        return ring
    }

    static func fillLayer(_ overlay: Overlay) -> String? {
        switch overlay {
        case .vegetation: StyleBuilder.LayerID.tasvegFill
        case .geology: StyleBuilder.LayerID.geologyFill
        case .pre1750: StyleBuilder.LayerID.pre1750Fill
        case .none: nil
        }
    }

    /// The tiles under the tapped point changed (zoom band, TASVEG's z11):
    /// the same class at the same spot carries a new id — follow it, so the
    /// outline stays on "her" polygon at every zoom.
    private func refreshAnchoredSelection(_ map: MLNMapView) {
        guard let anchor, model.selection != nil, model.selection?.isTree == false,
              anchor.overlay == model.layers.overlay, let fill = Self.fillLayer(anchor.overlay) else { return }
        let point = map.convert(anchor.coordinate, toPointTo: map)
        guard map.bounds.contains(point),
              map.zoomLevel >= Double(StyleBuilder.idMinZoom(anchor.overlay)),
              let feature = map.visibleFeatures(at: point, styleLayerIdentifiers: [fill]).first,
              Self.overlayClass(feature)?.1 == anchor.classKey,
              let id = (feature.identifier as? NSNumber)?.uint64Value,
              id != selectionStyle.featureID
        else { return }
        selectionStyle.featureID = id
        applySelectionFilters()
    }

    /// The feature whose point is closest to `point` (tree dots, clusters).
    static func nearest(_ features: [any MLNFeature], to point: CGPoint, in map: MLNMapView) -> (any MLNFeature)? {
        features.min { a, b in
            let pa = map.convert(a.coordinate, toPointTo: map), pb = map.convert(b.coordinate, toPointTo: map)
            return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
        }
    }

    /// A cluster tap zooms to where it splits, capped at z17 so the CBD
    /// never jumps to street level.
    private func zoomInto(_ cluster: MLNPointFeatureCluster, map: MLNMapView) {
        guard let source = map.style?.source(withIdentifier: StyleBuilder.SourceID.treePoints) as? MLNShapeSource else { return }
        let expansion = source.zoomLevel(forExpanding: cluster)
        let zoom = expansion.isFinite && expansion > map.zoomLevel ? min(expansion, 17) : min(map.zoomLevel + 2, 17)
        map.setCenter(cluster.coordinate, zoomLevel: zoom, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// A tree point or area by its index into the bundled data (the tile's
    /// geometry may be clipped; the data has the whole shape).
    private func selectTree(_ feature: any MLNFeature, isArea: Bool) -> Bool {
        guard let trees = model.tables.trees,
              let index = (feature.attribute(forKey: "i") as? NSNumber)?.intValue,
              let ref = feature.attribute(forKey: "ref") as? String
        else { return false }
        let shape: MLNShape
        if isArea {
            guard trees.areas.indices.contains(index) else { return false }
            shape = Self.shape(of: trees.areas[index])
        } else {
            guard trees.points.indices.contains(index) else { return false }
            let p = trees.points[index].position
            let dot = MLNPointFeature()
            dot.coordinate = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
            shape = dot
        }
        model.select(.tree(TreeSelection(ref: ref, accuracy: feature.attribute(forKey: "acc") as? String ?? "",
                                         isArea: isArea, index: index)))
        showSelection(featureID: nil, shape: shape)
        return true
    }

    static func shape(of area: TreesData.Area) -> MLNShape {
        func polygon(_ ring: [GeoPoint], holes: [MLNPolygon]? = nil) -> MLNPolygon {
            var coords = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return MLNPolygon(coordinates: &coords, count: UInt(coords.count), interiorPolygons: holes)
        }
        let polygons = area.polygons.compactMap { rings -> MLNPolygon? in
            guard let outer = rings.first else { return nil }
            return polygon(outer, holes: rings.dropFirst().map { polygon($0) })
        }
        return MLNMultiPolygonFeature(polygons: polygons)
    }

    /// Sources with a visible layer at the current zoom, for the credits
    /// sheet. Written only when the set changes (style load, camera settles).
    private func refreshVisibleSources(_ map: MLNMapView) {
        guard let style = map.style else { return }
        let zoom = map.zoomLevel
        var ids = Set<String>()
        for layer in style.layers {
            guard layer.isVisible, let layer = layer as? MLNForegroundStyleLayer,
                  let source = layer.sourceIdentifier,
                  zoom >= Double(layer.minimumZoomLevel), zoom < Double(layer.maximumZoomLevel)
            else { continue }
            ids.insert(source)
        }
        if ids != model.map.visibleSources { model.map.visibleSources = ids }
    }

    static func mapMode(_ mode: TrackingMode) -> MLNUserTrackingMode {
        switch mode {
        case .off: .none
        case .follow: .follow
        case .followWithHeading: .followWithHeading
        }
    }

    static func trackingMode(_ mode: MLNUserTrackingMode) -> TrackingMode {
        switch mode {
        case .follow, .followWithCourse: .follow
        case .followWithHeading: .followWithHeading
        default: .off
        }
    }
}

// MARK: - MLNMapViewDelegate

extension MapCoordinator: MLNMapViewDelegate {
    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        let gestures: MLNCameraChangeReason = [
            .gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom,
        ]
        if !reason.intersection(gestures).isEmpty { userMovedCamera = true }
        if model.map.isIdle { model.map.isIdle = false }
    }

    #if DEBUG
    /// Finding-14 timing: from the tap's filter change to the first frame
    /// MapLibre reports fully rendered (every tile re-laid out).
    func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
        guard fullyRendered, let started = tapStarted else { return }
        tapStarted = nil
        Self.timing.notice("tap → fully rendered \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))), privacy: .public) (highlight on overlay source: \(StyleBuilder.highlightOnOverlaySource, privacy: .public))")
    }
    #endif

    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
        if !model.map.isIdle { model.map.isIdle = true }
        refreshAnchoredSelection(mapView)
        #if DEBUG
        // `-openLayers YES`: the Layers sheet once the map settles (thumbnail screenshots)
        if UserDefaults.standard.bool(forKey: "openLayers"), !openedLayers {
            openedLayers = true
            model.present(.layers)
        }
        if !debugTaps.isEmpty {
            let p = debugTaps.removeFirst()
            tap(at: CGPoint(x: p.x * mapView.bounds.width, y: p.y * mapView.bounds.height))
        }
        #endif
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        // a reloaded style starts with an empty selection source
        selectionSource?.shape = selectionShape
        applySelectionFilters()
        // … and with its own paint: fade again for a soloed community
        fadedPaint = []
        if appliedSpotlight != nil { applyFade() }
        refreshVisibleSources(mapView)
        model.map.zoom = mapView.zoomLevel
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        model.map.centre = mapView.centerCoordinate
        // the scale bar follows a pinch (MapLiveState only: RootView doesn't re-render)
        if model.map.zoom != mapView.zoomLevel { model.map.zoom = mapView.zoomLevel }
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        let centre = mapView.centerCoordinate
        model.map.centre = centre
        model.map.zoom = mapView.zoomLevel
        refreshVisibleSources(mapView)
        guard CameraPolicy.contains(latitude: centre.latitude, longitude: centre.longitude) else { return }
        cameraStore.save(SavedCamera(
            latitude: centre.latitude, longitude: centre.longitude,
            zoom: mapView.zoomLevel, heading: mapView.direction
        ))
    }

    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
        guard let location = userLocation?.location else { return }
        model.locationUpdated()
        guard awaitingLaunchFix else { return }
        awaitingLaunchFix = false
        let coordinate = location.coordinate
        guard !userMovedCamera, Date.now < launchFixDeadline, mapView.userTrackingMode == .none,
              CameraPolicy.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
        else { return }
        mapView.setCenter(coordinate, zoomLevel: max(mapView.zoomLevel, CameraPolicy.fixZoom), animated: true)
    }

    /// MapLibre Native 7.0.0 calls this only for `kCLErrorDenied` (other
    /// Core Location errors are dropped inside MLNMapView), after turning
    /// tracking and the puck off itself. Core Location also reports a denial
    /// while the permission prompt is still up: only the actual status says
    /// whether access is off. "No fix yet" is AppModel's watch.
    func mapView(_ mapView: MLNMapView, didFailToLocateUserWithError error: any Error) {
        switch mapView.locationManager.authorizationStatus {
        case .denied, .restricted: model.locationDenied()
        default: break
        }
    }

    func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
        model.mapChangedTracking(to: Self.trackingMode(mode))
    }

    func mapView(_ mapView: MLNMapView, didChangeLocationManagerAuthorization manager: any MLNLocationManager) {
        let status = manager.authorizationStatus
        model.authorizationChanged(to: status)
        if status == .authorizedWhenInUse || status == .authorizedAlways { mapView.showsUserLocation = true }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MapCoordinator: UIGestureRecognizerDelegate {
    /// The feature-tap recognizer ignores touches on MapLibre's ornaments
    /// (the compass is a view inside MLNMapView, so the map's recognizers see
    /// its touches too) and on any control.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let map, let view = touch.view else { return true }
        return !Self.isOrnament(view, in: map)
    }

    static func isOrnament(_ view: UIView, in map: MLNMapView) -> Bool {
        view.isDescendant(of: map.compassView) || view.isDescendant(of: map.attributionButton)
            || view is UIControl
    }
}
