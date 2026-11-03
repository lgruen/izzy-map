import CoreLocation
import MapLibre
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

    init(model: AppModel) {
        self.model = model
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
        map.showsScale = true
        map.scaleBarUsesMetricSystem = true
        map.scaleBarPosition = .bottomLeft
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
    }

    // MARK: SwiftUI → map

    func apply(chrome: MapChrome, to map: MLNMapView) {
        guard chrome != appliedChrome else { return }
        if appliedChrome?.contentInset != chrome.contentInset {
            map.setContentInset(chrome.contentInset, animated: appliedChrome != nil, completionHandler: nil)
        }
        appliedChrome = chrome
        let lift = chrome.ornamentLift
        map.scaleBarMargins = CGPoint(x: 16, y: lift + chrome.pillHeight + 16)
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

    func clearSelectionShape() {
        guard showsSelectionShape else { return }
        showsSelectionShape = false
        selectionSource?.shape = nil
    }

    private var selectionSource: MLNShapeSource? {
        map?.style?.source(withIdentifier: StyleBuilder.SourceID.selection) as? MLNShapeSource
    }

    // MARK: Taps

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let map else { return }
        let point = gesture.location(in: map)
        let hits = map.visibleFeatures(at: point, styleLayerIdentifiers: [StyleBuilder.LayerID.tasvegFill])
        guard let feature = hits.first, let code = feature.attribute(forKey: "VEGCODE") as? String else {
            model.clearSelection()
            clearSelectionShape()
            return
        }
        model.selectCommunity(code: code, sourceName: feature.attribute(forKey: "VEGCODE_D") as? String)
        // TODO(M2): this is the polygon's piece in one tile; tiles with
        // feature ids (tippecanoe --generate-ids) would let a filtered line
        // layer outline the whole polygon across tile edges.
        selectionSource?.shape = feature as? MLNShape
        showsSelectionShape = true
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

    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
        if !model.map.isIdle { model.map.isIdle = true }
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        refreshVisibleSources(mapView)
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        model.map.centre = mapView.centerCoordinate
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        let centre = mapView.centerCoordinate
        model.map.centre = centre
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
