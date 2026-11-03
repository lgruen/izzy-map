import IzzyKit
import MapLibre
import UIKit

/// The picked place on the map: a MapLibre point annotation with its own
/// view (an ink pin with a white halo — data, so no glass), and the camera
/// flight to it. Annotations live outside the style, so the pin survives
/// every style reload (layer changes) untouched. Owned by MapCoordinator
/// (`searchPins`); MapView hands it the model's pin on each update.
@MainActor
final class SearchPinPresenter {
    private var annotation: SearchPinAnnotation?
    private var appliedFlight: (id: String, flight: Int)?
    private let camera: MapCamera
    /// The unobscured map area, as insets from the map's bounds.
    private var framing: UIEdgeInsets = .zero

    init(camera: MapCamera) {
        self.camera = camera
    }

    /// Highest zoom a search flight lands at: above z17 offline tiles are
    /// stretched z15 pack tiles, soft enough to read as broken.
    static let maxFlightZoom = 17.0

    func apply(_ pin: SearchModel.Pin?, framing: UIEdgeInsets, to map: MLNMapView) {
        self.framing = framing
        guard let pin else {
            if let annotation { map.removeAnnotation(annotation) }
            annotation = nil
            appliedFlight = nil
            return
        }
        let result = pin.result
        if annotation?.result.id != result.id || annotation?.result.name != result.name {
            if let annotation { map.removeAnnotation(annotation) }
            let a = SearchPinAnnotation(result: result)
            map.addAnnotation(a)
            annotation = a
        }
        guard appliedFlight?.id != result.id || appliedFlight?.flight != pin.flight else { return }
        appliedFlight = (result.id, pin.flight)
        // the phone's sheet drops from large to its glance first: fly once
        // the chrome has settled, with the insets it then has (a gesture
        // before then cancels it — MapCamera)
        camera.schedule(after: 0.35) { [weak self, weak map] in
            guard let self, let map, self.appliedFlight?.id == result.id else { return }
            self.fly(map, to: result)
        }
    }

    func view(for annotation: any MLNAnnotation, in map: MLNMapView) -> MLNAnnotationView? {
        guard let pin = annotation as? SearchPinAnnotation else { return nil }
        let view = map.dequeueReusableAnnotationView(withIdentifier: SearchPinView.reuseID) as? SearchPinView
            ?? SearchPinView(reuseIdentifier: SearchPinView.reuseID)
        view.configure(for: pin.result)
        return view
    }

    private func fly(_ map: MLNMapView, to result: SearchResult) {
        let size = map.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let pad = UIEdgeInsets(top: framing.top + 8, left: framing.left + 8,
                               bottom: framing.bottom + 8, right: framing.right + 8)
        let target: MLNMapCamera
        switch result.camera {
        case let .fit(box, maxZoom, padding):
            let edge = UIEdgeInsets(top: pad.top + padding, left: pad.left + padding,
                                    bottom: pad.bottom + padding, right: pad.right + padding)
            target = MapCamera.fit([box.west, box.south, box.east, box.north],
                                   maxZoom: min(maxZoom, Self.maxFlightZoom), insets: edge, in: map)
        case let .point(p, zoom):
            target = MapCamera.looking(at: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                                       zoom: min(zoom, Self.maxFlightZoom), in: map)
        }
        // the same padding as the fit: the place lands centred in the
        // uncovered map
        let from = map.centerCoordinate
        let km = SearchText.km(lat1: from.latitude, lon1: from.longitude,
                               lat2: target.centerCoordinate.latitude, lon2: target.centerCoordinate.longitude)
        camera.move(map, to: target, insets: pad, duration: Self.flightDuration(km: km))
    }

    /// Longer for farther, on a log scale: a street away 0.5 s, the far
    /// end of the state 1.2 s (capped).
    nonisolated static func flightDuration(km: Double) -> TimeInterval {
        min(1.2, max(0.4, 0.4 + 0.32 * log10(1 + max(0, km))))
    }
}

/// The pin's annotation: the result it marks.
final class SearchPinAnnotation: NSObject, MLNAnnotation {
    let result: SearchResult
    let coordinate: CLLocationCoordinate2D
    var title: String? { result.name }
    var subtitle: String? { result.meta }

    init(result: SearchResult) {
        self.result = result
        coordinate = CLLocationCoordinate2D(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
    }
}

/// The search pin: an ink head on a short stem, its tip on the place, every
/// stroke inside a white halo (reads over aerial photos and dark topo
/// alike). Printed matter like the selection line: no glass, no shadow,
/// the same ink in dark mode (the map is paper either way).
final class SearchPinView: MLNAnnotationView {
    static let reuseID = "search-pin"
    private let halo = CAShapeLayer()
    private let ink = CAShapeLayer()
    private let eye = CAShapeLayer()
    private static let size = CGSize(width: 30, height: 42)
    /// The tip's distance above the view's bottom edge (room for the halo).
    private static let tipInset: CGFloat = 3

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: Self.size)
        // the tip, not the view's centre, sits on the coordinate
        centerOffset = CGVector(dx: 0, dy: -(Self.size.height / 2 - Self.tipInset))
        isUserInteractionEnabled = false
        let (head, stem) = Self.paths(in: CGRect(origin: .zero, size: Self.size))
        let whole = UIBezierPath()
        whole.append(head)
        whole.append(stem)
        halo.path = whole.cgPath
        halo.fillColor = UIColor.white.cgColor
        halo.strokeColor = UIColor.white.cgColor
        halo.lineWidth = 5
        halo.lineJoin = .round
        halo.lineCap = .round
        ink.path = head.cgPath
        ink.fillColor = Self.inkColor.cgColor
        let stemLayer = CAShapeLayer()
        stemLayer.path = stem.cgPath
        stemLayer.strokeColor = Self.inkColor.cgColor
        stemLayer.lineWidth = 2.5
        stemLayer.lineCap = .round
        let r: CGFloat = 3.5
        eye.path = UIBezierPath(ovalIn: CGRect(x: Self.size.width / 2 - r, y: 13 - r, width: 2 * r, height: 2 * r)).cgPath
        eye.fillColor = UIColor.white.cgColor
        for l in [halo, stemLayer, ink, eye] { layer.addSublayer(l) }
        isAccessibilityElement = true
        accessibilityIdentifier = "search-pin"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Near-black ink, the chrome's light-mode label colour.
    private static let inkColor = UIColor(white: 0.08, alpha: 1)

    func configure(for result: SearchResult) {
        accessibilityLabel = "Pin: \(result.name)"
        accessibilityValue = result.meta.replacingOccurrences(of: " · ", with: ", ")
    }

    /// Head: a circle at the top; stem: a line down to the tip.
    private static func paths(in rect: CGRect) -> (UIBezierPath, UIBezierPath) {
        let cx = rect.midX, headR: CGFloat = 10
        let head = UIBezierPath(ovalIn: CGRect(x: cx - headR, y: 3, width: 2 * headR, height: 2 * headR))
        let stem = UIBezierPath()
        stem.move(to: CGPoint(x: cx, y: 3 + 2 * headR - 1))
        stem.addLine(to: CGPoint(x: cx, y: rect.maxY - tipInset))
        return (head, stem)
    }
}

// MapLibre asks its delegate for annotation views; the search pin is the
// only annotation the app adds.
extension MapCoordinator {
    @objc(mapView:viewForAnnotation:)
    func mapView(_ mapView: MLNMapView, viewFor annotation: any MLNAnnotation) -> MLNAnnotationView? {
        searchPins.view(for: annotation, in: mapView)
    }
}
