import CoreLocation
import MapLibre
import Testing
import UIKit
@testable import IzzyMap

/// The user dot and its heading arrow, on a real MLNMapView driven by a
/// fake location manager (no Core Location, no permission prompt).
@MainActor
@Suite struct UserLocationTests {
    private static let style = ##"{"version":8,"sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"#ffffff"}}]}"##

    private func map(_ manager: FakeLocationManager, coordinator: MapCoordinator) -> MLNMapView {
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), styleJSON: Self.style)
        map.locationManager = manager
        map.delegate = coordinator
        return map
    }

    @Test func authorisedLocationShowsTheDotWithItsHeadingArrow() {
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let coordinator = MapCoordinator(model: AppModel(data: .none, tables: .empty))
        let map = map(manager, coordinator: coordinator)
        coordinator.mapView(map, didChangeLocationManagerAuthorization: manager)
        #expect(map.showsUserLocation)
        #expect(map.showsUserHeadingIndicator)
        #expect(manager.updatingHeading)
        // the arrow is no tracking mode: the map stays where it is
        #expect(map.userTrackingMode == .none)
    }

    /// The heading switch turns the dot on by itself, and the dot asks for
    /// permission: neither may happen before location is allowed.
    @Test func undecidedLocationShowsNeitherAndAsksNothing() {
        let manager = FakeLocationManager(status: .notDetermined)
        let coordinator = MapCoordinator(model: AppModel(data: .none, tables: .empty))
        let map = map(manager, coordinator: coordinator)
        coordinator.mapView(map, didChangeLocationManagerAuthorization: manager)
        #expect(!map.showsUserLocation)
        #expect(!map.showsUserHeadingIndicator)
        #expect(!manager.requestedAuthorization)
        #expect(!manager.updatingHeading)
    }

    /// MapLibre reports every heading through `didUpdate userLocation` with
    /// the location it already has. With the arrow on, headings keep coming
    /// whenever the dot shows: they must not count as fixes, or a phone
    /// that lost GPS would never hear "no fix" (and the message would be
    /// dismissed by turning around).
    @Test func aHeadingIsNoFix() async {
        let clock = ManualClock()
        let model = AppModel(data: .none, tables: .empty, clock: clock.clock)
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let coordinator = MapCoordinator(model: model)
        let map = map(manager, coordinator: coordinator)
        coordinator.mapView(map, didChangeLocationManagerAuthorization: manager)
        model.authorization = .authorizedWhenInUse

        // one real fix (it shows as the dot), then following starts while
        // it is still recent: the watch waits for it to go stale
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        manager.deliver(Self.fix(-42.88, 147.33, at: t0))
        clock.advance(by: .seconds(30))
        model.cycleTracking()
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.noFixDelay)  // fix 40 s old
        await settle { clock.sleeperCount > 0 }

        // the phone turns, no new position
        let heading = FakeHeading(90)
        manager.deliver(heading)
        // MapLibre takes the heading on the main queue, then calls the delegate
        await settle { map.userLocation?.heading === heading }
        #expect(map.userLocation?.heading?.trueHeading == 90)

        clock.advance(by: AppModel.fixStaleAfter - .seconds(40))  // 60 s: stale
        await settle { model.notice != nil }
        #expect(model.notice == .noFix)

        // turning again doesn't dismiss the message either
        // (MapLibre keeps only a heading that differs from the last)
        let turned = FakeHeading(180)
        manager.deliver(turned)
        await settle { map.userLocation?.heading === turned }
        #expect(map.userLocation?.heading?.trueHeading == 180)
        #expect(model.notice == .noFix)

        // a new position is a fix (the path is live)
        manager.deliver(Self.fix(-42.881, 147.331, at: t0 + 61))
        #expect(model.notice == nil)
    }

    private static func fix(_ latitude: Double, _ longitude: Double, at time: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: time)
    }

    /// iOS's calibration prompt only in heading-up mode, as before the
    /// arrow: asked the way Core Location asks MapLibre.
    @Test func calibrationPromptOnlyInHeadingUpMode() {
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let coordinator = MapCoordinator(model: AppModel(data: .none, tables: .empty))
        let map = map(manager, coordinator: coordinator)
        coordinator.mapView(map, didChangeLocationManagerAuthorization: manager)
        let mayPrompt = { manager.delegate?.locationManagerShouldDisplayHeadingCalibration(manager) ?? false }
        #expect(!mayPrompt())
        coordinator.apply(tracking: .follow, to: map)
        #expect(!mayPrompt())
        coordinator.apply(tracking: .followWithHeading, to: map)
        #expect(mayPrompt())
        // a pan ends following: MapLibre sets the mode itself
        map.userTrackingMode = .none
        #expect(!mayPrompt())
        coordinator.apply(tracking: .followWithHeading, to: map)
        coordinator.apply(tracking: .off, to: map)
        #expect(!mayPrompt())
    }
}

/// An `MLNLocationManager` that only records what the map asks of it.
final class FakeLocationManager: NSObject, MLNLocationManager {
    weak var delegate: (any MLNLocationManagerDelegate)?
    let authorizationStatus: CLAuthorizationStatus
    var headingOrientation: CLDeviceOrientation = .portrait
    private(set) var requestedAuthorization = false
    private(set) var updatingHeading = false

    init(status: CLAuthorizationStatus) {
        authorizationStatus = status
    }

    func requestAlwaysAuthorization() { requestedAuthorization = true }
    func requestWhenInUseAuthorization() { requestedAuthorization = true }
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
    func startUpdatingHeading() { updatingHeading = true }
    func stopUpdatingHeading() { updatingHeading = false }
    func dismissHeadingCalibrationDisplay() {}

    func deliver(_ location: CLLocation) {
        delegate?.locationManager(self, didUpdate: [location])
    }

    func deliver(_ heading: CLHeading) {
        delegate?.locationManager(self, didUpdate: heading)
    }
}

/// A valid compass reading (Core Location vends no initialiser for one).
/// Never let Swift Testing describe one: CLHeading's `description` reads
/// state the fake doesn't have.
nonisolated final class FakeHeading: CLHeading {
    private let direction: CLLocationDirection

    init(_ direction: CLLocationDirection) {
        self.direction = direction
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var headingAccuracy: CLLocationDirection { 10 }
    override var magneticHeading: CLLocationDirection { direction }
    override var trueHeading: CLLocationDirection { direction }
}
