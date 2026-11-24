import CoreLocation
import Foundation
import os

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
    /// for yet, or no fix since it was allowed → iOS asks, the notice says
    /// to wait (or long-press) and the pin waits for the first fresh fix
    /// (`PendingPin`).
    func pinCurrentLocation() {
        guard pins != nil else { return }
        guard let fix = fixForPin(placing: true) else { return }
        placePin(at: fix)
    }

    /// A pin at `fix`, placed by GPS, its card open (the pin button, or
    /// the fix it waited for).
    private func placePin(at fix: CLLocation) {
        guard let pins else { return }
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
    /// long-press, and "Waiting for a location fix" holds the request),
    /// not "Move to my location" (which never waits).
    private func fixForPin(placing: Bool) -> CLLocation? {
        if isLocationDenied {
            show(pinNotice(placing: placing))
            return nil
        }
        if let fix = usableFix { return fix }
        if authorization == .notDetermined { requestLocation() }
        let notice = pinNotice(placing: placing)
        show(notice)
        if placing, notice == .waitingForPin { pendingPin = PendingPin(pressedAt: wallClock()) }
        return nil
    }

    /// A location came while the pin button waits. Only a FRESH fix — taken
    /// at or after the press, accurate enough for a pin — fulfils it: Core
    /// Location's cached sample, often the first one delivered after the
    /// permission prompt, is older than the press and changes nothing (the
    /// wait and its notice stay; the notice's time runs out on its own).
    /// A fresh fix while something else is up (a sheet, search, a move,
    /// the background) ends the wait without a pin.
    func fixArrived(_ location: CLLocation?) {
        guard let pending = pendingPin else { return }
        guard let location, pending.isFulfilled(by: location) else {
            if let location {
                Self.pinLogger.debug("""
                    pin button waits on: fix \(location.timestamp.timeIntervalSince(pending.pressedAt), format: .fixed(precision: 1)) s \
                    after the press, ± \(location.horizontalAccuracy, format: .fixed(precision: 0)) m
                    """)
            }
            return
        }
        pendingPin = nil
        if notice == .waitingForPin { dismissNotice() }
        guard pinPlacementIsClear else {
            Self.pinLogger.debug("pin button's fix came while something else was up: \(self.pinPlacementState, privacy: .public)")
            return
        }
        placePin(at: location)
    }

    /// iOS's permission prompt, raised by the pin button, answered. Allow:
    /// the wait goes on and its notice gets its full time again (reading
    /// the prompt must not use it up — the fix only starts coming now).
    /// Don't Allow: the denied notice, with the long-press.
    func pinButtonAnswered(_ status: CLAuthorizationStatus) {
        guard let pending = pendingPin, notice == .waitingForPin else { return }
        if isLocationDenied {
            show(.deniedForPin)
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            show(.waitingForPin)
            pendingPin = pending
        }
    }

    /// Ends the pin button's wait without a pin, and takes its notice
    /// down — called by everything else she can do meanwhile: another
    /// selection, a search, a move, a sheet, the camera or library, the
    /// reader, a photo, a pushed card view, framing an area, the
    /// background (a notice dismissed or replaced ends it too).
    func cancelPendingPin() {
        guard pendingPin != nil else { return }
        Self.pinLogger.debug("pin button's wait cancelled: \(self.pinPlacementState, privacy: .public)")
        pendingPin = nil
        if notice == .waitingForPin { dismissNotice() }
    }

    private static let pinLogger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Pins")

    /// Nothing but the map: what must still hold when the fix the pin
    /// button waited for arrives.
    var pinPlacementIsClear: Bool {
        modal == nil && !search.isActive && movingPin == nil && !pinProjectForm && !pinPhotoSourceShown
            && photoViewer == nil && !documents.isReading && cardPath.isEmpty && !isFraming && !pinsScreenShown
            && !sceneInBackground
    }

    /// What `pinPlacementIsClear` looked at (the debug log).
    private var pinPlacementState: String {
        "modal \(modal?.id ?? "-") search \(search.isActive) moving \(movingPin != nil) form \(pinProjectForm) "
            + "photos \(pinPhotoSourceShown) viewer \(photoViewer != nil) reader \(documents.isReading) "
            + "path \(cardPath.count) framing \(isFraming) pins \(pinsScreenShown) background \(sceneInBackground) "
            + "selection \(selection.map { "\($0.feature)" } ?? "-")"
    }

    /// The window's scene phase. Going to the background ends the wait; so
    /// does going inactive, unless iOS's own permission prompt is what
    /// covers the app (the pin button raised it: the answer, then the
    /// fix, are what she is waiting for).
    func scenePhaseChanged(active: Bool, background: Bool) {
        sceneInBackground = background
        if background || (!active && authorization != .notDetermined) { cancelPendingPin() }
    }

    /// Why there is no fix, in words that say what to do: location off →
    /// Settings (and, from the pin button, the long-press); iOS still
    /// asking, or no fix yet since it was allowed → wait (or long-press);
    /// otherwise (fixes came, none recent or close enough) → long-press.
    func pinNotice(placing: Bool) -> LocationNotice {
        if isLocationDenied { return placing ? .deniedForPin : .deniedForMove }
        // Move: one honest line, whether a fix is still to come or none
        // usable came — "Move on map" is the other way
        guard placing else { return .noFixForMove }
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
        revealMovedPin()
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
        // a "No location yet" from an earlier try is moot now
        if notice?.isPinNotice == true { dismissNotice() }
        offerMoveUndo(pin, from: from)
        revealMovedPin()
    }

    private static func spot(_ pin: SavedPin) -> PinSpot {
        PinSpot(latitude: pin.lat, longitude: pin.lon, placedBy: pin.placedBy, accuracy: pin.accuracy, altitude: pin.altitude)
    }

    private func offerMoveUndo(_ pin: SavedPin, from: PinSpot) {
        setPinUndo(PinUndo(pin: pin.id, title: pin.displayTitle, movedFrom: from,
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
    var mapPinUndo: PinUndo? { modal?.presentation == .pins || pinsScreenShown ? nil : pinUndo }

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
            revealMovedPin()
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

/// The pin button's request while it waits for a fix: the time of the
/// press, which a fix must not predate.
nonisolated struct PendingPin: Equatable, Sendable {
    let pressedAt: Date

    /// A fix taken at or after the press, with a valid accuracy no worse
    /// than a pin may have (`AppModel.pinMaxAccuracy`).
    func isFulfilled(by fix: CLLocation) -> Bool {
        fix.timestamp >= pressedAt && fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= AppModel.pinMaxAccuracy
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
                             message: (n == 0 ? "" : "Its \(PinText.count(n)) go with it. ") + "This can’t be undone.",
                             button: "Delete")
    }

    static func pin(_ pin: SavedPin) -> PinsDeleteNow {
        PinsDeleteNow(target: .pin(pin.id), title: "Delete “\(pin.displayTitle)” now?",
                      message: "This can’t be undone.", button: "Delete")
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
                             message: "\(what.prefix(1).uppercased() + what.dropFirst()). This can’t be undone.",
                             button: "Delete all")
    }
}
