import CoreLocation
import Foundation

/// Switches for features that are built but not ready to ship.
nonisolated enum Features {
    /// Pins (docs/PINS_PLAN.md). Must not reach a TestFlight build before
    /// iCloud sync is on (§3, last bullet: whether a store that started
    /// local-only uploads its rows later is unproven). Off: no pin button,
    /// no long-press, no pin layers, and the store is never opened (no
    /// file is created). On in DEBUG builds only — the one place to flip.
    #if DEBUG
    static let pins = true
    #else
    static let pins = false
    #endif
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
