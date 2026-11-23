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

    /// Every way a pin's card opens (a tap, Undo, a row in Pins) shows the
    /// pins first: a card and ring for a pin that isn't drawn would lie.
    func selectPin(_ id: UUID) {
        movingPin = nil
        showPinsLayer()
        select(.pin(id))
    }

    /// A long-press on the map: a pin there, its card open with the title
    /// field ready.
    func dropPin(at coordinate: CLLocationCoordinate2D) {
        guard let pins else { return }
        let pin = pins.addPin(latitude: coordinate.latitude, longitude: coordinate.longitude, placedBy: .map)
        showPinsLayer()
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
        guard let fix = fixForPin(placing: true) else { return }
        if notice?.isPinNotice == true { dismissNotice() }
        let pin = pins.addPin(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, placedBy: .gps,
                              accuracy: fix.horizontalAccuracy,
                              altitude: fix.verticalAccuracy > 0 ? fix.altitude : nil)
        showPinsLayer()
        pinPlaced()
        selectPin(pin.id)
        focusPin(latitude: pin.lat, longitude: pin.lon)
    }

    /// The usable fix, or nil after saying why there is none
    /// (`pinNotice`). `placing`: the pin button (its notices name the
    /// long-press), not "Move to my location".
    private func fixForPin(placing: Bool) -> CLLocation? {
        if isLocationDenied {
            show(pinNotice(placing: placing))
            return nil
        }
        if let fix = usableFix { return fix }
        if authorization == .notDetermined { requestLocation() }
        show(pinNotice(placing: placing))
        return nil
    }

    /// Why there is no fix, in words that say what to do: location off →
    /// Settings (and, from the pin button, the long-press); iOS still
    /// asking, or no fix yet since it was allowed → wait (or long-press);
    /// otherwise (fixes came, none recent or close enough) → long-press.
    func pinNotice(placing: Bool) -> LocationNotice {
        if isLocationDenied { return placing ? .deniedForPin : .denied }
        if authorization == .notDetermined || (lastLocation == nil && systemLocation() == nil) { return .waitingForPin }
        return .noFixForPin
    }

    // MARK: Move

    /// "Move on map": the next map tap moves the selected pin ("Tap the
    /// new spot" says the bar).
    func startMovingPin() {
        guard let id = selection?.pinID else { return }
        movingPin = id
    }

    func cancelPinMove() { movingPin = nil }

    /// The map tap while moving: the pin goes there, placed by hand; the
    /// pill offers Undo (a slip of the finger must not move a survey point
    /// for good).
    func movePin(to coordinate: CLLocationCoordinate2D) {
        guard let id = movingPin, let pins, let pin = pins.pin(id) else {
            movingPin = nil
            return
        }
        movingPin = nil
        let from = Self.spot(pin)
        pins.move(pin, latitude: coordinate.latitude, longitude: coordinate.longitude, placedBy: .map)
        offerMoveUndo(pin, from: from)
        if selection?.pinID != id { selectPin(id) }
    }

    /// "Move to my location": the freshest usable fix, or the honest
    /// notice; Undo as for a move on the map.
    func movePinToMyLocation() {
        guard let pins, let pin = selectedPin else { return }
        movingPin = nil
        guard let fix = fixForPin(placing: false) else { return }
        let from = Self.spot(pin)
        pins.move(pin, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, placedBy: .gps,
                  accuracy: fix.horizontalAccuracy, altitude: fix.verticalAccuracy > 0 ? fix.altitude : nil)
        offerMoveUndo(pin, from: from)
        focusPin(latitude: pin.lat, longitude: pin.lon)
    }

    private static func spot(_ pin: SavedPin) -> PinSpot {
        PinSpot(latitude: pin.lat, longitude: pin.lon, placedBy: pin.placedBy, accuracy: pin.accuracy, altitude: pin.altitude)
    }

    private func offerMoveUndo(_ pin: SavedPin, from: PinSpot) {
        setPinUndo(PinUndo(pin: pin.id, title: PinText.name(title: pin.title, note: "") ?? "", movedFrom: from,
                           serial: (pinUndo?.serial ?? 0) + 1))
    }

    // MARK: Delete

    /// Soft delete; the card closes and a banner offers Undo.
    func deletePin(_ id: UUID) {
        guard let pins, let pin = pins.pin(id) else { return }
        pins.flush()
        pins.delete(pin)
        if selection?.pinID == id { clearSelection() }
        if movingPin == id { movingPin = nil }
        setPinUndo(PinUndo(pin: id, title: pin.displayTitle, serial: (pinUndo?.serial ?? 0) + 1))
    }

    /// Soft delete of a project and its pins (the Pins screen's editor); a
    /// banner offers Undo, as for a pin.
    func deleteProject(_ project: PinProject) {
        guard let pins else { return }
        pins.flush()
        let count = pins.pins(in: project).count
        pins.deleteProject(project)
        if let id = selection?.pinID, pins.pin(id) == nil { clearSelection() }
        if let id = movingPin, pins.pin(id) == nil { movingPin = nil }
        setPinUndo(PinUndo(pin: nil, project: project.id, title: PinText.projectName(project.name), pinCount: count,
                           serial: (pinUndo?.serial ?? 0) + 1))
    }

    /// The Undo pill on the map — not while the Pins screen is up (it
    /// shows the pill at its own foot).
    var mapPinUndo: PinUndo? { modal?.presentation == .pins ? nil : pinUndo }

    /// Undo: the pin is back, its card open again — or the project is back
    /// with the pins that went with it (the Pins screen shows it again).
    func undoPinDelete() {
        guard let undo = pinUndo else { return }
        setPinUndo(nil)
        guard let pins else { return }
        if let id = undo.project {
            if let project = pins.deletedProjects.first(where: { $0.id == id }) { pins.restoreProject(project) }
            return
        }
        guard let id = undo.pin, let pin = pins.anyPin(id) else { return }
        if let from = undo.movedFrom {
            // a move: back to where it was, as it was placed (its card stays
            // or opens; the camera brings it into view)
            guard pin.deletedAt == nil else { return }
            pins.move(pin, latitude: from.latitude, longitude: from.longitude,
                      placedBy: SavedPin.Placement(rawValue: from.placedBy) ?? .map,
                      accuracy: from.accuracy, altitude: from.altitude)
            if selection?.pinID != id { selectPin(id) }
            focusPin(latitude: from.latitude, longitude: from.longitude)
            return
        }
        pins.restore(pin)
        selectPin(pin.id)
    }

    // MARK: Pins screen

    /// Pins are drawn (Layers → Also show → Pins). Adding a pin, or asking
    /// to see pins, turns them back on.
    func showPinsLayer() {
        if !layers.pins { layers.pins = true }
    }

    /// "Show on map": the screen closes and the camera frames these pins
    /// (the ones on the map); the layers stay as they are, except that
    /// hidden pins are shown again.
    func showOnMap(_ list: [SavedPin]) {
        let coordinates = list.filter(\.isOnMap).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let box = PinFraming.box(coordinates) else { return }
        leaveForMap()
        pinsFit = PinsFit(target: .box(box), serial: (pinsFit?.serial ?? 0) + 1)
    }

    /// A pin row: the screen closes, the pin's card opens and the camera
    /// brings it into view.
    func showPin(_ id: UUID) {
        guard let pin = pins?.pin(id), pin.isOnMap else { return }
        leaveForMap()
        selectPin(id)
        pinsFit = PinsFit(target: .pin(latitude: pin.lat, longitude: pin.lon), serial: (pinsFit?.serial ?? 0) + 1)
    }

    private func leaveForMap() {
        pins?.flush()
        dismissModal()
        if isFraming { cancelFraming() }
        endSpotlight()
        if search.isActive { search.end() }
        // following would drag the camera straight off the pins
        if trackingMode != .off { trackingMode = .off }
        showPinsLayer()
    }
}

/// Where the Pins screen can be opened from — the chip's "All pins…", the
/// Layers row, ⌘P, the Storage row — all of them only while pins are on.
enum PinsEntry {
    static func available(_ model: AppModel) -> Bool { model.pins != nil }
}

// MARK: - Deleting for real

extension AppModel {
    /// Recently deleted's "Delete now" / "Delete all now", confirmed. The
    /// Undo banner goes if what it would bring back is gone.
    func deleteNow(_ request: PinsDeleteNow) {
        guard let pins else { return }
        switch request.target {
        case let .project(id):
            if let project = pins.deletedProjects.first(where: { $0.id == id }) { pins.deleteNow(project) }
        case let .pin(id):
            if let pin = pins.anyPin(id), pin.deletedAt != nil { pins.deleteNow(pin) }
        case .all:
            pins.deleteAllNow()
        }
        clearStaleUndo()
    }

    /// Purges what was deleted more than 30 days ago (at launch, when the
    /// window comes back to the foreground, when Recently deleted opens).
    func purgePins() {
        guard let pins else { return }
        pins.purge()
        clearStaleUndo()
    }

    /// The Undo banner whose subject no longer exists (deleted for good)
    /// goes: its Undo could do nothing.
    func clearStaleUndo() {
        guard let undo = pinUndo, let pins else { return }
        let alive: Bool = if let id = undo.project {
            pins.deletedProjects.contains { $0.id == id } || pins.project(id) != nil
        } else if let id = undo.pin {
            pins.anyPin(id) != nil
        } else { false }
        if !alive { setPinUndo(nil) }
    }
}

/// A confirmed "Delete now": what to delete, by id, with the dialog's words
/// taken when it opens — the dialog never reads a record while it animates
/// away after the delete (a deleted SwiftData object may trap when read).
struct PinsDeleteNow: Identifiable, Equatable {
    enum Target: Equatable { case project(UUID), pin(UUID), all }

    let target: Target
    let title: String
    let message: String
    let button: String

    var id: String {
        switch target {
        case let .project(id): "project-\(id)"
        case let .pin(id): "pin-\(id)"
        case .all: "all"
        }
    }

    static func project(_ project: PinProject, in store: PinStore) -> PinsDeleteNow {
        let n = store.pinsDeleted(with: project).count
        return PinsDeleteNow(target: .project(project.id), title: "Delete “\(PinText.projectName(project.name))” now?",
                             message: (n == 0 ? "The project is" : "The project and its \(PinText.count(n)) are")
                                 + " deleted for good. This can’t be undone.",
                             button: "Delete")
    }

    static func pin(_ pin: SavedPin) -> PinsDeleteNow {
        PinsDeleteNow(target: .pin(pin.id), title: "Delete “\(pin.displayTitle)” now?",
                      message: "The pin is deleted for good. This can’t be undone.", button: "Delete")
    }

    /// Names everything it removes: the projects with the pins that went
    /// with them, and the pins deleted on their own.
    static func all(in store: PinStore) -> PinsDeleteNow {
        let projects = store.deletedProjects.count
        let withThem = store.deletedProjects.reduce(0) { $0 + store.pinsDeleted(with: $1).count }
        let alone = store.deletedPins.count
        var parts: [String] = []
        if projects > 0 {
            let noun = projects == 1 ? "1 project" : "\(projects.formatted()) projects"
            parts.append(withThem == 0 ? noun : "\(noun) with \(projects == 1 ? "its" : "their") \(PinText.count(withThem))")
        }
        if alone > 0 {
            parts.append(projects == 0 ? PinText.count(alone)
                : "\(PinText.count(alone)) deleted on \(alone == 1 ? "its" : "their") own")
        }
        let what = parts.joined(separator: " and ")
        return PinsDeleteNow(target: .all, title: "Delete everything here now?",
                             message: "\(what.prefix(1).uppercased() + what.dropFirst()) — deleted for good. This can’t be undone.",
                             button: "Delete All")
    }
}
