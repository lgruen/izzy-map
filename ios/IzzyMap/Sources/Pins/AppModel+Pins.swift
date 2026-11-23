import CoreLocation
import Foundation

/// The window's pin gestures and card actions (docs/PINS_PLAN.md §4–5).
/// The records live in the shared `PinStore`; selection, the move mode,
/// the Undo banner and the notices are this window's. With pins switched
/// off (`pins == nil`) every action does nothing.
extension AppModel {
    /// The selected pin's record, if the card shows one that still exists.
    var selectedPin: SavedPin? {
        selection?.pinID.flatMap { pins?.pin($0) }
    }

    func selectPin(_ id: UUID) {
        movingPin = nil
        select(.pin(id))
    }

    /// A long-press on the map: a pin there, its card open with the title
    /// field ready.
    func dropPin(at coordinate: CLLocationCoordinate2D) {
        guard let pins else { return }
        let pin = pins.addPin(latitude: coordinate.latitude, longitude: coordinate.longitude, placedBy: .map)
        pinPlaced()
        selectPin(pin.id)
        pinTitleFocus = pin.id
    }

    /// The pin button: a pin at the freshest usable fix, with its accuracy
    /// and altitude; the camera eases to it if it is out of sight. No
    /// usable fix → the honest notice, never a guess; location never asked
    /// for yet → iOS asks (and the notice says to wait or long-press).
    func pinCurrentLocation() {
        guard let pins else { return }
        guard let fix = fixForPin() else { return }
        if notice == .noFixForPin { dismissNotice() }
        let pin = pins.addPin(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, placedBy: .gps,
                              accuracy: fix.horizontalAccuracy,
                              altitude: fix.verticalAccuracy > 0 ? fix.altitude : nil)
        pinPlaced()
        selectPin(pin.id)
        focusPin(latitude: pin.lat, longitude: pin.lon)
    }

    /// The usable fix, or nil after saying why there is none.
    private func fixForPin() -> CLLocation? {
        if isLocationDenied {
            showLocationDenied()
            return nil
        }
        guard let fix = usableFix else {
            if authorization == .notDetermined { requestLocation() }
            showNoFixForPin()
            return nil
        }
        return fix
    }

    // MARK: Move

    /// "Tap the map at the new spot": the next map tap moves the selected pin.
    func startMovingPin() {
        guard let id = selection?.pinID else { return }
        movingPin = id
    }

    func cancelPinMove() { movingPin = nil }

    /// The map tap while moving: the pin goes there, placed by hand.
    func movePin(to coordinate: CLLocationCoordinate2D) {
        guard let id = movingPin, let pin = pins?.pin(id) else {
            movingPin = nil
            return
        }
        movingPin = nil
        pins?.move(pin, latitude: coordinate.latitude, longitude: coordinate.longitude, placedBy: .map)
        if selection?.pinID != id { selectPin(id) }
    }

    /// "To my location": the freshest usable fix, or the honest notice.
    func movePinToMyLocation() {
        guard let pins, let pin = selectedPin else { return }
        movingPin = nil
        guard let fix = fixForPin() else { return }
        pins.move(pin, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, placedBy: .gps,
                  accuracy: fix.horizontalAccuracy, altitude: fix.verticalAccuracy > 0 ? fix.altitude : nil)
        focusPin(latitude: pin.lat, longitude: pin.lon)
    }

    // MARK: Delete

    /// Soft delete; the card closes and a banner offers Undo.
    func deletePin(_ id: UUID) {
        guard let pins, let pin = pins.pin(id) else { return }
        pins.flush()
        pins.delete(pin)
        if selection?.pinID == id { clearSelection() }
        if movingPin == id { movingPin = nil }
        setPinUndo(PinUndo(pin: id, title: pin.title, serial: (pinUndo?.serial ?? 0) + 1))
    }

    /// Undo: the pin is back, its card open again.
    func undoPinDelete() {
        guard let undo = pinUndo else { return }
        setPinUndo(nil)
        guard let pins, let pin = pins.anyPin(undo.pin) else { return }
        pins.restore(pin)
        selectPin(pin.id)
    }
}
