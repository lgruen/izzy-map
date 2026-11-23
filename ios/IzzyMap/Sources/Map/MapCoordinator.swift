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
    /// When the last location MapLibre reported was taken (`didUpdate
    /// userLocation`): a heading comes with the same one.
    private var lastFixTimestamp: Date?
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
    /// Every programmatic camera move, its padding and delayed flights.
    let camera = MapCamera()
    /// "Show on map": fade, presence cells, framing, the stepped-to patch.
    private let spotlights: SpotlightPresenter
    /// The search pin and its flights (Search/SearchPinPresenter.swift).
    let searchPins: SearchPinPresenter
    /// Saved pins' runtime layers (Pins/PinPresenter.swift).
    let pinMarks = PinPresenter()
    /// The pin the selection ring is drawn on, and where.
    private var ringedPin: (id: UUID, latitude: Double, longitude: Double)?
    private var appliedLocationRequest = 0
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
    /// `-debugLongPress "0.5,0.4"`: a long-press there once the taps are done.
    private var debugLongPress: CGPoint? = {
        let v = (UserDefaults.standard.string(forKey: "debugLongPress") ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
    }()
    /// `-debugPinsDemo YES`: one pin of each palette colour in a row across
    /// the map at the first idle (palette screenshots; use `-pinsInMemory`).
    private var seededDemoPins = false
    private var debugTapsNotBefore = Date.distantPast
    private var openedLayers = false
    private let perfTour = PerfTour()
    private static let timing = Logger(subsystem: "org.gruenschloss.izzymap", category: "Timing")
    #endif

    init(model: AppModel) {
        self.model = model
        spotlights = SpotlightPresenter(camera: camera)
        searchPins = SearchPinPresenter(camera: camera)
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
        Self.hideOrnaments(map)
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
            Self.showUserLocation(on: map)
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

        // Long-press drops a pin. MapLibre's own gestures, checked against
        // MLNMapView 7.0.0: pan, pinch, rotate (two fingers), two-finger tap,
        // double tap (zoom in) and quick zoom — a UILongPressGestureRecognizer
        // with numberOfTapsRequired 1 and minimumPressDuration 0, i.e.
        // double-tap-then-drag; pitch is off. None recognises simultaneously
        // with ours (MLNMapView allows that only among its own pinch/rotate/
        // pan set), so whichever begins first wins: a drag or a pinch moves
        // more than `allowableMovement` or adds a finger before 0.5 s and
        // this fails; the second tap of a quick zoom begins the quick zoom
        // at once and this fails; a held, still finger begins this, which
        // fails the pan and the feature tap in turn.
        // (pins switched off: no recogniser at all)
        if model.pins != nil {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            press.minimumPressDuration = 0.5
            press.delegate = self
            map.addGestureRecognizer(press)
        }

        // the live LIST sources follow the network path
        connectivity = Connectivity.shared.observe { [weak self] _ in self?.reloadStyleIfNeeded() }
    }

    // MARK: SwiftUI → map

    func apply(chrome: MapChrome, to map: MLNMapView) {
        guard chrome != appliedChrome else { return }
        let wasFraming = appliedChrome.map { $0.areaFrame != nil || $0.areaDraft != nil } ?? false
        let framing = chrome.areaFrame != nil || chrome.areaDraft != nil
        let draftShown = appliedChrome?.areaDraft
        let oldInsets = appliedChrome?.framingInsets
        defer {
            updateFramedBox(map)
            if framing != wasFraming { framingChanged(framing, map: map) }
            // the card is measured a moment after it appears: check again when it is
            if let box = chrome.areaDraft, box != draftShown || chrome.framingInsets != oldInsets {
                showDraft(box, insets: chrome.framingInsets, map: map)
            }
            updateDraftRect(map)
        }
        if appliedChrome?.contentInset != chrome.contentInset {
            // the inset change re-centres the map, cancelling a flight in
            // progress: fly it again from where it stopped
            let interrupted = camera.flightUnderWay
            map.setContentInset(chrome.contentInset, animated: appliedChrome != nil && !UIAccessibility.isReduceMotionEnabled,
                                completionHandler: nil)
            camera.contentInsetChanged()
            camera.resume(interrupted, on: map)
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
        if wanted != .none { camera.trackingStarted() }
        // Reduce Motion: the camera cuts to the position (DESIGN.md "Motion")
        map.setUserTrackingMode(wanted, animated: !UIAccessibility.isReduceMotionEnabled, completionHandler: nil)
    }

    /// The user dot with its heading arrow, only once location is authorised:
    /// either switch makes MapLibre ask for permission (the heading one turns
    /// `showsUserLocation` on itself). MapLibre 7.0.0 draws the arrow in the
    /// dot's own colour with a white edge once a valid heading has arrived —
    /// none on the simulator or without a compass reading: no arrow, nothing
    /// else — and swaps it for its beam in heading-up mode. Neither switch
    /// touches the tracking mode.
    private static func showUserLocation(on map: MLNMapView) {
        allowHeadingCalibration(on: map)
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
    }

    /// iOS's compass-calibration prompt only in heading-up mode, as before
    /// the arrow: the arrow keeps headings coming whenever the dot shows,
    /// and browsing the map must not raise a prompt. MapLibre reads the
    /// switch each time Core Location asks; every mode change (ours, a pan
    /// ending following, a denial) passes `didChange mode`.
    private static func allowHeadingCalibration(on map: MLNMapView) {
        map.displayHeadingCalibration = map.userTrackingMode == .followWithHeading
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
        ringedPin = nil
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
        if !(model.selection?.isPin ?? false) { ringedPin = nil }
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

    // MARK: Pins

    /// The store changed or the selection did: the pins' source, and the
    /// ring on a selected pin (placed by the model — a long-press, the pin
    /// button, Undo — or moved). A selected pin that is gone (deleted on
    /// the other device) closes its card.
    func apply(pins store: PinStore?, selectedPin: UUID?, to map: MLNMapView) {
        guard let store else { return }
        pinMarks.apply(store, visible: model.layers.pins, to: map)
        guard let id = selectedPin else { return }
        guard let pin = store.pin(id), pin.isOnMap else {
            // (not during SwiftUI's view update)
            Task { [model] in if model.selection?.pinID == id { model.clearSelection() } }
            return
        }
        if ringedPin?.id != id || ringedPin?.latitude != pin.lat || ringedPin?.longitude != pin.lon { ringPin(id) }
    }

    private func ringPin(_ id: UUID) {
        guard let pin = model.pins?.pin(id) else { return }
        // a polygon tapped before must not get its outline back at the next idle
        anchor = nil
        ringedPin = (id, pin.lat, pin.lon)
        showSelection(featureID: nil, shape: PinPresenter.selectionShape(pin))
    }

    private var appliedPinFocus: Int?

    /// A pin placed out of sight (the pin button): the camera eases to it,
    /// at the same zoom; one already in the uncovered map stays put.
    func apply(pinFocus: AppModel.PinFocus?, framing: UIEdgeInsets, to map: MLNMapView,
               animated: Bool = !UIAccessibility.isReduceMotionEnabled) {
        guard let pinFocus, pinFocus.serial != appliedPinFocus else { return }
        appliedPinFocus = pinFocus.serial
        let coordinate = CLLocationCoordinate2D(latitude: pinFocus.latitude, longitude: pinFocus.longitude)
        let visible = map.bounds.inset(by: framing).insetBy(dx: PinPresenter.hitRadius, dy: PinPresenter.hitRadius)
        guard !visible.contains(map.convert(coordinate, toPointTo: map)) else { return }
        camera.setCenter(map, coordinate, zoom: map.zoomLevel, animated: animated)
    }

    private var appliedPinsFit: Int?

    /// The Pins screen's "Show on map" (frame the pins) and a picked pin
    /// (bring it into view). The screen goes and, on a phone, the card's
    /// sheet rises first: the camera moves once the chrome has settled,
    /// with the insets it then has (`delay` 0: at once, for tests).
    func apply(pinsFit: PinsFit?, to map: MLNMapView, delay: TimeInterval = 0.4,
               animated: Bool = !UIAccessibility.isReduceMotionEnabled) {
        guard let pinsFit, pinsFit.serial != appliedPinsFit else { return }
        appliedPinsFit = pinsFit.serial
        let move: @MainActor () -> Void = { [weak self, weak map] in
            guard let self, let map, self.appliedPinsFit == pinsFit.serial else { return }
            self.frame(pinsFit.target, on: map, animated: animated)
        }
        if delay > 0 { camera.schedule(after: delay, move) } else { move() }
    }

    private func frame(_ target: PinsFit.Target, on map: MLNMapView, animated: Bool) {
        // (no animation: a cut, as under Reduce Motion)
        let duration: TimeInterval? = animated ? nil : 0
        let framing = appliedChrome?.framingInsets ?? .zero
        let margin = PinFraming.margin(framing: framing, in: map.bounds.size)
        switch target {
        case let .box(box):
            camera.move(map, to: MapCamera.fit(box, maxZoom: PinFraming.maxZoom, insets: margin, in: map), insets: margin, duration: duration)
        case let .pin(latitude, longitude):
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let visible = map.bounds.inset(by: margin)
            let zoom = map.zoomLevel
            guard zoom < PinFraming.pinMinZoom || !visible.contains(map.convert(coordinate, toPointTo: map)) else { return }
            let target = zoom < PinFraming.pinMinZoom ? PinFraming.pinZoom : zoom
            camera.move(map, to: MapCamera.looking(at: coordinate, zoom: target, in: map), insets: margin, duration: duration)
        }
    }

    /// The pin button before location was ever allowed: the dot on, which
    /// makes iOS ask (the dot stays once allowed, as from the Location button).
    func apply(locationRequest: Int, to map: MLNMapView) {
        guard locationRequest != appliedLocationRequest else { return }
        appliedLocationRequest = locationRequest
        if !map.showsUserLocation { map.showsUserLocation = true }
    }

    #if DEBUG
    private func seedDemoPins(_ map: MLNMapView) {
        guard let pins = model.pins else { return }
        for (i, colour) in PinColour.allCases.enumerated() {
            let point = CGPoint(x: map.bounds.width * (0.12 + 0.76 * Double(i) / 7), y: map.bounds.height * (i.isMultiple(of: 2) ? 0.3 : 0.38))
            let c = map.convert(point, toCoordinateFrom: map)
            let pin = pins.addPin(latitude: c.latitude, longitude: c.longitude, placedBy: .map)
            pins.setTitle(pin, colour.title)
            pins.setColour(pin, colour.rawValue)
        }
        // on the map now, so the next idle (a `-debugTaps` tap) finds them drawn
        pinMarks.apply(pins, visible: model.layers.pins, to: map)
    }
    #endif

    // MARK: Show on map

    /// Solo the spotlight's community and frame it (SpotlightPresenter).
    func apply(spotlight: Spotlight?, to map: MLNMapView) {
        spotlights.apply(spotlight, framing: appliedChrome?.framingInsets ?? .zero, model: model, to: map)
    }

    // MARK: Framing an area

    /// The dashed frame's box on the ground, while framing (live, 60 Hz on a
    /// pan: only the framing bar reads it).
    private func updateFramedBox(_ map: MLNMapView) {
        guard let rect = appliedChrome?.areaFrame, rect.width > 0, rect.height > 0 else {
            if model.map.framedBox != nil { model.map.framedBox = nil }
            return
        }
        let b = map.convert(rect, toCoordinateBoundsFrom: map)
        let box = AreaBox(west: b.sw.longitude, south: b.sw.latitude, east: b.ne.longitude, north: b.ne.latitude)
        if model.map.framedBox != box { model.map.framedBox = box }
    }

    /// Framing: the frame is the box that downloads, so the map is north
    /// up (a rotated frame's box would be larger than what she framed) and
    /// stays so while framing.
    private func framingChanged(_ framing: Bool, map: MLNMapView) {
        map.allowsRotating = !framing
        if framing, map.direction != 0 { map.setDirection(0, animated: !UIAccessibility.isReduceMotionEnabled) }
    }

    /// The setup card opened beside the map: keep the framed box in view
    /// clear of it (inset like the frame, 8 % × 10 %).
    private func showDraft(_ box: AreaBox, insets: UIEdgeInsets, map: MLNMapView) {
        let free = map.bounds.inset(by: insets)
        guard free.width > 60, free.height > 60 else { return }
        let margin = UIEdgeInsets(top: insets.top + free.height * 0.10, left: insets.left + free.width * 0.08,
                                  bottom: insets.bottom + free.height * 0.10, right: insets.right + free.width * 0.08)
        let target = map.convert(MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
                                                     ne: CLLocationCoordinate2D(latitude: box.north, longitude: box.east)),
                                 toRectTo: map)
        // already clear of the card: leave the map where she put it
        if map.bounds.inset(by: margin).insetBy(dx: -2, dy: -2).contains(target) { return }
        let fit = MapCamera.fit([box.west, box.south, box.east, box.north], maxZoom: CameraPolicy.maxZoom, insets: margin, in: map)
        camera.move(map, to: fit, insets: margin, duration: 0.35)
    }

    private var appliedAreaFocus: Int?

    /// "Show on map" for a detailed area: framed in the uncovered map, no
    /// closer than z17.
    func apply(areaFocus: AppModel.AreaFocus?, framing: UIEdgeInsets, to map: MLNMapView) {
        guard let areaFocus, areaFocus.serial != appliedAreaFocus else { return }
        appliedAreaFocus = areaFocus.serial
        let b = areaFocus.box
        let free = map.bounds.inset(by: framing)
        let margin = UIEdgeInsets(top: framing.top + free.height * 0.08, left: framing.left + free.width * 0.06,
                                  bottom: framing.bottom + free.height * 0.08, right: framing.right + free.width * 0.06)
        camera.move(map, to: MapCamera.fit([b.west, b.south, b.east, b.north], maxZoom: 17, insets: margin, in: map), insets: margin)
    }

    /// Where the setup card's box is on screen (the frame follows it).
    private func updateDraftRect(_ map: MLNMapView) {
        guard let box = appliedChrome?.areaDraft else {
            if model.map.draftRect != nil { model.map.draftRect = nil }
            return
        }
        let rect = map.convert(MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
                                                   ne: CLLocationCoordinate2D(latitude: box.north, longitude: box.east)),
                               toRectTo: map)
        if model.map.draftRect != rect { model.map.draftRect = rect }
    }

    // MARK: Taps

    /// Half the side of the box a tree dot is looked up in: the dots are
    /// 7 pt, a fingertip is not.
    static let treeHitRadius: CGFloat = 12

    /// Hit priority: trees first (nearest dot in a 24 pt box, then a tree
    /// area under the finger), then the visible overlay. Hidden layers are
    /// not in the style, so this answers for whatever is on screen.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // framing an area: the map only moves
        guard gesture.state == .ended, let map, !model.isFraming else { return }
        tap(at: gesture.location(in: map))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let map else { return }
        longPress(at: gesture.location(in: map))
    }

    /// A pin where the finger rests — not while framing an area or moving
    /// a pin (the map's one job then is the frame / the next tap). On an
    /// existing pin it selects that one instead of stacking a second.
    private func longPress(at point: CGPoint) {
        guard let map, model.pins != nil, !model.isFraming, model.movingPin == nil else { return }
        if let id = PinPresenter.hit(at: point, in: map) {
            if model.selection?.pinID != id {
                model.selectPin(id)
                ringPin(id)
            }
            return
        }
        model.dropPin(at: map.convert(point, toCoordinateFrom: map))
    }

    private func tap(at point: CGPoint) {
        guard let map, let style = map.style else { return }
        typealias L = StyleBuilder.LayerID
        #if DEBUG
        tapStarted = .now
        #endif

        // moving a pin: this tap is its new spot
        if model.movingPin != nil {
            model.movePin(to: map.convert(point, toCoordinateFrom: map))
            return
        }
        // a saved pin wins over trees and overlay fills
        if let id = PinPresenter.hit(at: point, in: map) {
            // the pin already open: leave its card (and keyboard) alone
            guard model.selection?.pinID != id else { return }
            model.selectPin(id)
            ringPin(id)
            return
        }

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
            // Soils covers 11 map sheets: off them a silent nothing would
            // read as "the app is broken" — the card says why instead
            // (`soilsNoteOnEmptyTap`: only off every sheet, never mid-search,
            // and a second empty tap dismisses it like any card)
            let at = map.convert(point, toCoordinateFrom: map)
            if model.layers.overlay == .soils, style.layer(withIdentifier: L.soilsFill) != nil,
               let soils = model.tables.soils,
               Self.soilsNoteOnEmptyTap(soils, longitude: at.longitude, latitude: at.latitude,
                                        searchActive: model.search.isActive,
                                        noteShowing: model.selection?.feature == .soilsUnmapped) {
                anchor = nil
                model.select(.soilsUnmapped)
                showSelection(featureID: nil, shape: nil)
                return
            }
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
        case .soils: model.select(.soils(SoilSelection(code: key, sheet: Self.text(feature, "sheet"))))
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

    /// A tap that hit no soil polygon shows the "No soil mapping here" note
    /// only when it is OFF every sheet's frame: inside one, a miss is water,
    /// a polygon too small for the zoom or a tile not drawn yet — an
    /// ordinary empty tap. Never while a search is up (an empty tap there
    /// clears, as on every overlay), and not over the note itself: a second
    /// empty tap dismisses it, so the map still closes a card by a tap.
    nonisolated static func soilsNoteOnEmptyTap(_ soils: SoilsFile, longitude: Double, latitude: Double,
                                                searchActive: Bool, noteShowing: Bool) -> Bool {
        !searchActive && !noteShowing && !soils.anySheetContains(longitude: longitude, latitude: latitude)
    }

    /// The overlay and class key (VEGCODE / SYMB / MVS / soil CODE) of a fill feature.
    static func overlayClass(_ feature: any MLNFeature) -> (Overlay, String)? {
        if let code = text(feature, "VEGCODE") { return (.vegetation, code) }
        if let symb = text(feature, "SYMB") { return (.geology, symb) }
        if let mvs = text(feature, "MVS") { return (.pre1750, mvs) }
        if let code = text(feature, "CODE") { return (.soils, code) }
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
        case .soils: StyleBuilder.LayerID.soilsFill
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
        camera.setCenter(map, cluster.coordinate, zoom: zoom, animated: !UIAccessibility.isReduceMotionEnabled)
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
        // a detailed area counts only while it is in view
        let visible = map.visibleCoordinateBounds
        let view = AreaBox(west: visible.sw.longitude, south: visible.sw.latitude,
                           east: visible.ne.longitude, north: visible.ne.latitude)
        ids = ids.filter { id in
            guard AreaStyleSource.layer(ofSource: id) != nil else { return true }
            return model.shared.areas.box(ofSource: id)?.intersects(view) ?? false
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
        if !reason.intersection(gestures).isEmpty {
            userMovedCamera = true
            // a flight still waiting for the chrome to settle is hers no more
            camera.gestureBegan()
        }
        if model.map.isIdle { model.map.isIdle = false }
    }

    #if DEBUG
    /// Finding-14 timing: from the tap's filter change to the first frame
    /// MapLibre reports fully rendered (every tile re-laid out).
    /// (The stats variant: MapLibre calls only one of the frame callbacks;
    /// `-perfTour YES` records the stats, PerfTour.)
    func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool, renderingStats: MLNRenderingStats) {
        perfTour.frame(renderingStats)
        guard fullyRendered, let started = tapStarted else { return }
        tapStarted = nil
        Self.timing.notice("tap → fully rendered \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))), privacy: .public) (highlight on overlay source: \(StyleBuilder.highlightOnOverlaySource, privacy: .public))")
    }
    #endif

    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
        if !model.map.isIdle { model.map.isIdle = true }
        refreshAnchoredSelection(mapView)
        spotlights.idle(mapView, model: model)
        #if DEBUG
        // `-openLayers YES`: the Layers sheet once the map settles (thumbnail screenshots)
        if UserDefaults.standard.bool(forKey: "openLayers"), !openedLayers {
            openedLayers = true
            model.present(.layers)
        }
        // `-openPins YES`: the Pins screen once the map settles (screenshots)
        if UserDefaults.standard.bool(forKey: "openPins"), !openedLayers {
            openedLayers = true
            model.present(.pins)
        }
        // `-startFraming YES`: framing an area once the map settles (screenshots)
        if UserDefaults.standard.bool(forKey: "startFraming"), !openedLayers {
            openedLayers = true
            model.startFraming()
        }
        perfTour.idle(mapView)
        if UserDefaults.standard.bool(forKey: "debugPinsDemo"), !seededDemoPins {
            seededDemoPins = true
            seedDemoPins(mapView)
            // MapLibre may call idle again before drawing them: the scripted
            // taps go a second later
            debugTapsNotBefore = Date.now.addingTimeInterval(0.9)
            Task { [weak self, weak mapView] in
                try? await Task.sleep(for: .seconds(1))
                if let self, let mapView { self.mapViewDidBecomeIdle(mapView) }
            }
            return
        }
        if Date.now < debugTapsNotBefore {
            // (seeded pins not drawn yet)
        } else if !debugTaps.isEmpty {
            let p = debugTaps.removeFirst()
            tap(at: CGPoint(x: p.x * mapView.bounds.width, y: p.y * mapView.bounds.height))
        } else if let p = debugLongPress {
            debugLongPress = nil
            longPress(at: CGPoint(x: p.x * mapView.bounds.width, y: p.y * mapView.bounds.height))
        }
        #endif
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        // a reloaded style starts with an empty selection source
        selectionSource?.shape = selectionShape
        applySelectionFilters()
        // … and with its own paint and none of the runtime layers: a soloed
        // community's fade and presence cells again
        spotlights.styleLoaded(mapView, model: model)
        if let pins = model.pins { pinMarks.styleLoaded(mapView, store: pins, visible: model.layers.pins) }
        refreshVisibleSources(mapView)
        model.map.zoom = mapView.zoomLevel
        Self.hideOrnaments(mapView)
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        model.map.centre = mapView.centerCoordinate
        if appliedChrome?.areaFrame != nil { updateFramedBox(mapView) }
        if appliedChrome?.areaDraft != nil { updateDraftRect(mapView) }
        // the scale bar follows a pinch (MapLiveState only: RootView doesn't re-render)
        if model.map.zoom != mapView.zoomLevel { model.map.zoom = mapView.zoomLevel }
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        let centre = mapView.centerCoordinate
        model.map.centre = centre
        model.map.zoom = mapView.zoomLevel
        refreshVisibleSources(mapView)
        updateFramedBox(mapView)
        updateDraftRect(mapView)
        guard CameraPolicy.contains(latitude: centre.latitude, longitude: centre.longitude) else { return }
        cameraStore.save(SavedCamera(
            latitude: centre.latitude, longitude: centre.longitude,
            zoom: mapView.zoomLevel, heading: mapView.direction
        ))
    }

    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
        // MapLibre also calls this for every compass heading, with the
        // location it already had — and the heading arrow keeps headings
        // coming whenever the dot shows. Only a new sample is a fix: a
        // turning phone must not hide a lost fix from the "no fix" watch.
        guard let location = userLocation?.location, location.timestamp != lastFixTimestamp else { return }
        lastFixTimestamp = location.timestamp
        model.locationUpdated(location)
        guard awaitingLaunchFix else { return }
        awaitingLaunchFix = false
        let coordinate = location.coordinate
        guard !userMovedCamera, Date.now < launchFixDeadline, mapView.userTrackingMode == .none,
              CameraPolicy.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
        else { return }
        camera.setCenter(mapView, coordinate, zoom: max(mapView.zoomLevel, CameraPolicy.fixZoom),
                         animated: !UIAccessibility.isReduceMotionEnabled)
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
        Self.allowHeadingCalibration(on: mapView)
        model.mapChangedTracking(to: Self.trackingMode(mode))
    }

    func mapView(_ mapView: MLNMapView, didChangeLocationManagerAuthorization manager: any MLNLocationManager) {
        let status = manager.authorizationStatus
        model.authorizationChanged(to: status)
        if status == .authorizedWhenInUse || status == .authorizedAlways { Self.showUserLocation(on: mapView) }
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

    /// MapLibre's own logo and (i) stay out for good: `showsLogoView` /
    /// `showsAttributionButton = false` hide them on screen, and these
    /// plain UIView properties keep touches away too. Their accessibility
    /// is `OrnamentFreeMapView`'s job (MLNMapView vends them itself).
    /// Re-applied after every style load, in case MapLibre re-shows them.
    static func hideOrnaments(_ map: MLNMapView) {
        for view in [map.attributionButton, map.logoView] as [UIView] {
            view.isHidden = true
            view.isUserInteractionEnabled = false
        }
    }

    static func isOrnament(_ view: UIView, in map: MLNMapView) -> Bool {
        view.isDescendant(of: map.compassView) || view.isDescendant(of: map.attributionButton)
            || view is UIControl
    }
}
