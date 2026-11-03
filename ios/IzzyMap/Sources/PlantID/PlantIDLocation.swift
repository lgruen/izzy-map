import CoreLocation
import Foundation
import IzzyKit

/// Where the photo was taken, for the location prior: the photo's own GPS
/// metadata, else where she is now (asking permission the first time),
/// else none — the identifier then ranks on the photo alone.
nonisolated enum PlantIDPlace: Equatable, Sendable {
    case photo(GeoPoint)
    case current(GeoPoint)
    case none

    var point: GeoPoint? {
        switch self {
        case let .photo(p), let .current(p): p
        case .none: nil
        }
    }
}

/// A one-shot current position (When In Use): a recent fix if the system
/// has one, else one request with a time limit. Never keeps updating.
@MainActor
final class PlantIDLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<GeoPoint?, Never>] = []
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// The current position, or nil (denied, no fix within `limit`).
    func current(limit: Duration = .seconds(8)) async -> GeoPoint? {
        #if DEBUG
        if let forced = Self.debugOverride { return forced.point }
        #endif
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        default: break
        }
        if let l = manager.location, l.timestamp.timeIntervalSinceNow > -120, l.horizontalAccuracy >= 0,
           l.horizontalAccuracy < 1000 {
            return GeoPoint(longitude: l.coordinate.longitude, latitude: l.coordinate.latitude)
        }
        return await withCheckedContinuation { c in
            waiting.append(c)
            guard waiting.count == 1 else { return }
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    private func finish(_ point: GeoPoint?) {
        timeout?.cancel()
        timeout = nil
        let all = waiting
        waiting = []
        for c in all { c.resume(returning: point) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard !self.waiting.isEmpty else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let p = GeoPoint(longitude: l.coordinate.longitude, latitude: l.coordinate.latitude)
        Task { @MainActor in self.finish(p) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    #if DEBUG
    /// `-plantIDLocation <lat,lon | none>`: no CoreLocation (UI tests,
    /// screenshots). Start a southern latitude with a space (" -42.9,147.3"):
    /// a value beginning with "-" would be read as another argument.
    static var debugOverride: PlantIDPlace? {
        guard let raw = UserDefaults.standard.string(forKey: "plantIDLocation") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return PlantIDPlace.none }
        return .current(GeoPoint(longitude: parts[1], latitude: parts[0]))
    }
    #endif
}
