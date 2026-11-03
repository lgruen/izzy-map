import CoreGraphics
import MapLibre
import UIKit

/// The map area no chrome covers, as insets from the map view's bounds.
///
/// Every floating piece of chrome (the spotlight pill, a notice, the iPad
/// card, the controls, the bottom ornaments, the phone's sheet) is a
/// rectangle over the map. Each one is cleared by pushing ONE edge of the
/// free area past it — whichever edge loses the least area: a short card in
/// the top-leading corner pushes the top edge down, a tall one the leading
/// edge across. Measured frames, never assumed heights (finding 10).
nonisolated enum MapFraming {
    /// `bounds`: the map view's bounds (window coordinates: the map is
    /// full-window). `safe`: the safe-area insets. `obstructions`: chrome
    /// frames in the same coordinates.
    static func insets(bounds: CGRect, safe: UIEdgeInsets, obstructions: [CGRect]) -> UIEdgeInsets {
        var free = bounds.inset(by: safe)
        // biggest first: a sheet decides before a pill beside it
        let sorted = obstructions.filter { !$0.isNull && !$0.isEmpty }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        for _ in 0 ..< 3 {  // a later push can't uncover an earlier one; twice is plenty
            var changed = false
            for o in sorted {
                let hit = free.intersection(o)
                guard !hit.isNull, hit.width > 0.5, hit.height > 0.5 else { continue }
                let options: [CGRect] = [
                    CGRect(x: free.minX, y: o.maxY, width: free.width, height: free.maxY - o.maxY),  // top down
                    CGRect(x: free.minX, y: free.minY, width: free.width, height: o.minY - free.minY),  // bottom up
                    CGRect(x: o.maxX, y: free.minY, width: free.maxX - o.maxX, height: free.height),  // leading across
                    CGRect(x: free.minX, y: free.minY, width: o.minX - free.minX, height: free.height),  // trailing in
                ].filter { $0.width > 0 && $0.height > 0 }
                guard let best = options.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
                free = best
                changed = true
            }
            if !changed { break }
        }
        return UIEdgeInsets(top: free.minY - bounds.minY, left: free.minX - bounds.minX,
                            bottom: bounds.maxY - free.maxY, right: bounds.maxX - free.maxX)
    }
}

/// Every programmatic camera move goes through here — search flights,
/// "Show on map" framing and its fly-back, the launch fix, cluster zooms —
/// so that:
///
/// - a framed extent is centred in the UNOBSCURED area: the fit and the
///   flight use the same edge padding. (`cameraThatFitsCoordinateBounds`
///   returns the box's own centre and folds the padding only into the zoom;
///   flown without that padding, an asymmetric inset pushed the box off
///   centre and cut it — finding 3.)
/// - the padding the map's transform holds after a move is remembered: a
///   camera read later (`map.camera`) is relative to it, so restoring that
///   camera must use the same padding (finding 9).
/// - a delayed flight (waiting for the phone's sheet to settle) is dropped
///   when she touches the map first (finding 12).
@MainActor
final class MapCamera {
    /// A camera as read from the map, with the padding it is relative to
    /// (nil: the content inset alone).
    struct Saved {
        let camera: MLNMapCamera
        let insets: UIEdgeInsets?
    }

    /// The absolute padding (content inset included) of the last move, nil
    /// for the content inset alone.
    private(set) var insets: UIEdgeInsets?
    private var pending: DispatchWorkItem?
    /// The flight under way: a content-inset change re-centres the map and
    /// so cancels it (the phone's sheet settling at its new resting height
    /// ~0.35 s after a search pick stopped the flight halfway — the pin
    /// never came into view); `resume` flies it again.
    private var flight: Flight?
    private var flightCounter = 0

    struct Flight {
        fileprivate let id: Int
        let camera: MLNMapCamera
        /// Absolute (content inset included), nil = the content inset alone.
        let insets: UIEdgeInsets?
        let duration: TimeInterval?
        /// A backstop for a cancel MapLibre never reports.
        let until: Date
    }

    func save(_ map: MLNMapView) -> Saved { Saved(camera: map.camera, insets: insets) }

    /// Runs `work` after `delay` unless another flight is scheduled, or a
    /// gesture starts, first.
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// She took the map (a gesture began): queued and running flights are
    /// hers no more.
    func gestureBegan() {
        cancelPending()
        flight = nil
    }

    /// The flight still under way, if any — read BEFORE changing the
    /// content inset (which cancels it), handed back to `resume` after.
    var flightUnderWay: Flight? {
        guard let flight, flight.until > Date() else { return nil }
        return flight
    }

    /// Flies an interrupted flight again, to the same target with the same
    /// absolute padding (MapLibre re-reads it over the new content inset).
    func resume(_ interrupted: Flight?, on map: MLNMapView) {
        // (the cancel may already have reported it ended; a newer flight wins)
        guard let interrupted, flightCounter == interrupted.id else { return }
        move(map, to: interrupted.camera, insets: interrupted.insets, duration: interrupted.duration)
    }

    /// The content inset changed: MapLibre re-centres with it as the padding.
    func contentInsetChanged() { insets = nil }

    /// The padding MapLibre takes on top of the content inset for absolute
    /// insets `absolute` (never less than the content inset).
    static func extra(_ absolute: UIEdgeInsets, over content: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: max(0, absolute.top - content.top), left: max(0, absolute.left - content.left),
                     bottom: max(0, absolute.bottom - content.bottom), right: max(0, absolute.right - content.right))
    }

    /// The camera that shows `box` [west, south, east, north] whole inside
    /// `insets` (absolute, from the map's bounds), no closer than `maxZoom`.
    /// Fly it with the same insets.
    static func fit(_ box: [Double], maxZoom: Double, insets: UIEdgeInsets, in map: MLNMapView) -> MLNMapCamera {
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                                         ne: CLLocationCoordinate2D(latitude: box[3], longitude: box[2]))
        let camera = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: extra(insets, over: map.contentInset))
        let size = map.bounds.size
        let lat = camera.centerCoordinate.latitude
        let zoom = MLNZoomLevelForAltitude(camera.altitude, 0, lat, size)
        if !zoom.isFinite || zoom > maxZoom { camera.altitude = MLNAltitudeForZoomLevel(maxZoom, 0, lat, size) }
        camera.heading = 0
        camera.pitch = 0
        return camera
    }

    /// A camera looking at `centre` at `zoom`.
    static func looking(at centre: CLLocationCoordinate2D, zoom: Double, in map: MLNMapView) -> MLNMapCamera {
        MLNMapCamera(lookingAtCenter: centre, altitude: MLNAltitudeForZoomLevel(zoom, 0, centre.latitude, map.bounds.size),
                     pitch: 0, heading: 0)
    }

    /// A flight to `camera` with `insets` (absolute; nil = the content
    /// inset), `duration` nil = MapLibre's own; Reduce Motion: a cut.
    func move(_ map: MLNMapView, to camera: MLNMapCamera, insets: UIEdgeInsets?, duration: TimeInterval? = nil) {
        cancelPending()
        let content = map.contentInset
        let extra = insets.map { Self.extra($0, over: content) } ?? .zero
        let absolute = UIEdgeInsets(top: content.top + extra.top, left: content.left + extra.left,
                                    bottom: content.bottom + extra.bottom, right: content.right + extra.right)
        self.insets = extra == .zero ? nil : absolute
        if UIAccessibility.isReduceMotionEnabled || duration == 0 {
            flight = nil
            map.setCamera(camera, withDuration: 0, animationTimingFunction: nil, edgePadding: extra, completionHandler: nil)
        } else {
            flightCounter += 1
            let id = flightCounter
            flight = Flight(id: id, camera: camera, insets: insets.map { _ in absolute }, duration: duration,
                            until: Date().addingTimeInterval(max(duration ?? 0, 4) + 1))
            map.fly(to: camera, edgePadding: extra, withDuration: duration ?? -1) { [weak self] in
                // arrived (or cancelled): either way no longer under way
                MainActor.assumeIsolated { if self?.flight?.id == id { self?.flight = nil } }
            }
        }
    }

    /// Back to a saved camera, with the padding it was read under.
    func restore(_ map: MLNMapView, to saved: Saved, duration: TimeInterval? = nil) {
        move(map, to: saved.camera, insets: saved.insets, duration: duration)
    }

    /// `setCenter` (the content inset as padding).
    func setCenter(_ map: MLNMapView, _ centre: CLLocationCoordinate2D, zoom: Double, animated: Bool) {
        cancelPending()
        flight = nil
        insets = nil
        map.setCenter(centre, zoomLevel: zoom, animated: animated)
    }

    /// User tracking moves the camera with the content inset as padding.
    func trackingStarted() {
        cancelPending()
        flight = nil
        insets = nil
    }
}
