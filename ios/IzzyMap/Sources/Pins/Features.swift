import CoreLocation
import Foundation

/// Switches for whole features — the one place to turn one off again.
nonisolated enum Features {
    /// Pins (docs/PINS_PLAN.md). On in every build since 2026-11-24: iCloud
    /// sync ships with them (§3, last bullet) — the container exists and
    /// its CloudKit schema is deployed to Production. Off would mean: no
    /// pin button, no long-press, no pin layers, no Pins screen, and the
    /// store is never opened (no file is created). DEBUG builds keep their
    /// own store file (`PinStore.defaultStoreURL`, `Pins-dev/`) and talk to
    /// CloudKit's Development environment; TestFlight builds use `Pins/`
    /// and Production.
    static let pins = true
}

/// Core Location's own latest position for the pin button. MapLibre
/// Native 7.0.0 drops a new sample whose coordinate equals the last one
/// (measured: `StandingStillTests`), so while she stands still its last
/// report ages although Core Location keeps delivering fresh fixes; a
/// manager of our own, never started, reads the system's latest one
/// (`CLLocationManager.location`). Created on the first press.
@MainActor
enum SystemLocation {
    private static var manager: CLLocationManager?

    static var latest: CLLocation? {
        let m = manager ?? CLLocationManager()
        manager = m
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return m.location
        default: return nil
        }
    }
}
