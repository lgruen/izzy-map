import CoreLocation
import Foundation
import IzzyKit
import MapLibre
import SwiftData
import Testing
import UIKit
@testable import IzzyMap

/// A clock the pin store reads (`PinStore.now`), moved by hand.
@MainActor
final class DateBox {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(days: Double) { now = now.addingTimeInterval(days * 24 * 60 * 60) }
}

@MainActor
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "izzymap-pintests-\(UUID().uuidString)")!
}

/// The store on an in-memory container: edits, soft delete, restore,
/// purge, the last-used project, the change signal.
@MainActor
@Suite struct PinStoreTests {
    private func store(_ clock: DateBox = DateBox(), defaults: UserDefaults? = nil) -> PinStore {
        PinStore.inMemory(defaults: defaults ?? freshDefaults(), now: { clock.now })
    }

    /// Every pin in the store, deleted or not, read through a separate
    /// context — i.e. what was SAVED, not what the main context holds.
    private func saved(_ store: PinStore) throws -> [SavedPin] {
        try ModelContext(store.container).fetch(FetchDescriptor<SavedPin>())
    }

    @Test func addingAPinSavesItWithItsPlacement() throws {
        let clock = DateBox()
        let s = store(clock)
        let before = s.revision
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map, accuracy: 12, altitude: 300)
        #expect(s.revision > before)
        #expect(s.pins.map(\.id) == [pin.id] && s.mapPins.map(\.id) == [pin.id])
        #expect(pin.placement == .map && pin.createdAt == clock.now && pin.modifiedAt == clock.now)
        // a hand-placed pin carries no GPS accuracy or altitude
        #expect(pin.accuracy == nil && pin.altitude == nil)
        let gps = s.addPin(latitude: -42.8, longitude: 147.2, placedBy: .gps, accuracy: 6, altitude: 410)
        #expect(gps.placedBy == "gps" && gps.accuracy == 6 && gps.altitude == 410)
        #expect(try saved(s).count == 2)
    }

    @Test func typingStampsModifiedAtAndIsSavedOnFlush() throws {
        let clock = DateBox()
        let s = store(clock)
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        clock.advance(days: 1)
        let before = s.revision
        s.setTitle(pin, "Seep below the track")
        s.setNote(pin, "Sphagnum, Richea")
        #expect(s.revision > before)  // the map's label follows at once
        #expect(pin.modifiedAt == clock.now)
        // not yet saved (typing waits for a pause) …
        #expect(try saved(s).first?.title == "")
        // … until the card closes or the app leaves the foreground
        s.flush()
        #expect(try saved(s).first?.title == "Seep below the track")
        #expect(try saved(s).first?.note == "Sphagnum, Richea")
    }

    @Test func typingIsSavedAfterAPauseWithoutAFlush() async throws {
        let s = store()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.setTitle(pin, "Gate")
        try await Task.sleep(for: PinStore.saveDelay + .milliseconds(400))
        #expect(try saved(s).first?.title == "Gate")
    }

    @Test func movingRecordsHowItWasPlaced() {
        let s = store()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .gps, accuracy: 5, altitude: 100)
        s.move(pin, latitude: -42.91, longitude: 147.31, placedBy: .map, accuracy: 5, altitude: 100)
        #expect(pin.lat == -42.91 && pin.lon == 147.31)
        // moved by hand: the old fix's accuracy would now be a lie
        #expect(pin.placement == .map && pin.accuracy == nil && pin.altitude == nil)
    }

    @Test func softDeleteRestoreAndPurgeAfterThirtyDays() throws {
        let clock = DateBox()
        let s = store(clock)
        let keep = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let gone = s.addPin(latitude: -42.8, longitude: 147.2, placedBy: .map)
        s.delete(gone)
        #expect(s.pins.map(\.id) == [keep.id] && s.mapPins.map(\.id) == [keep.id])
        #expect(gone.deletedAt == clock.now && gone.modifiedAt == clock.now)
        // still in the store, restorable
        #expect(s.anyPin(gone.id) != nil)
        s.restore(gone)
        #expect(Set(s.pins.map(\.id)) == [keep.id, gone.id])

        s.delete(gone)
        clock.advance(days: 29.9)
        s.purge()
        #expect(try saved(s).count == 2)
        clock.advance(days: 0.2)  // now 30.1 days after the delete
        s.purge()
        #expect(try saved(s).map(\.id) == [keep.id])
        #expect(s.anyPin(gone.id) == nil)
    }

    @Test func deletingAProjectTakesItsPinsAlongAndRestoringBringsOnlyThose() throws {
        let clock = DateBox()
        let s = store(clock)
        let project = s.addProject(name: "Knocklofty", colour: .teal)
        let a = s.addPin(latitude: -42.88, longitude: 147.31, placedBy: .map)
        let b = s.addPin(latitude: -42.89, longitude: 147.32, placedBy: .map)
        #expect(a.project?.id == project.id && b.project?.id == project.id)
        clock.advance(days: 1)
        s.delete(b)  // deleted on its own, earlier
        clock.advance(days: 1)
        s.deleteProject(project)
        #expect(s.projects.isEmpty && s.pins.isEmpty)
        s.restoreProject(project)
        #expect(s.projects.map(\.id) == [project.id])
        #expect(s.pins.map(\.id) == [a.id])  // b stays in Recently deleted
        // purge 30 days on: project and pins really go
        s.deleteProject(project)
        clock.advance(days: 31)
        s.purge()
        #expect(try saved(s).isEmpty)
        #expect(try ModelContext(s.container).fetch(FetchDescriptor<PinProject>()).isEmpty)
    }

    @Test func archivedProjectsPinsLeaveTheMap() {
        let s = store()
        let project = s.addProject(name: "Old site", colour: .brown)
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        #expect(s.mapPins.map(\.id) == [pin.id])
        s.setArchived(project, true)
        #expect(s.mapPins.isEmpty)
        #expect(s.pins.map(\.id) == [pin.id])  // not deleted
        s.setArchived(project, false)
        #expect(s.mapPins.map(\.id) == [pin.id])
    }

    @Test func newPinsJoinTheLastUsedProject() {
        let defaults = freshDefaults()
        let s = store(defaults: defaults)
        #expect(s.lastUsedProject == nil)
        #expect(s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map).project == nil)
        let first = s.addProject(name: "First", colour: .gold)
        #expect(s.lastUsedProject?.id == first.id)
        let second = s.addProject(name: "Second", colour: .violet)
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        #expect(pin.project?.id == second.id)
        // the chip moves it, and makes that project the one used last
        s.setProject(pin, first)
        #expect(s.lastUsedProject?.id == first.id)
        #expect(s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map).project?.id == first.id)
        // Unfiled is a choice too
        s.setProject(pin, nil)
        #expect(pin.project == nil && s.lastUsedProject == nil)
        // remembered across launches (UserDefaults), forgotten when archived
        s.lastUsedProject = second
        let reopened = PinStore(container: s.container, defaults: defaults)
        #expect(reopened.lastUsedProject?.id == second.id)
        reopened.setArchived(reopened.project(second.id)!, true)
        #expect(reopened.lastUsedProject == nil)
    }

    @Test func newProjectsTakeTheNextUnusedColour() {
        let s = store()
        // the first project skips the standard (Unfiled's) orange: filing a
        // fresh pin in it changes the mark
        #expect(PinColour.standard == .orange)
        #expect(s.nextProjectColour() == .gold)
        s.addProject(name: "A", colour: .gold)
        s.addProject(name: "B", colour: .olive)
        #expect(s.nextProjectColour() == .teal)
        // a project already in orange doesn't change the order of the rest
        s.addProject(name: "C", colour: .orange)
        #expect(s.nextProjectColour() == .teal)
        // the standard comes only once the other seven are taken
        for colour in [PinColour.teal, .violet, .magenta, .pink] { s.addProject(name: colour.title, colour: colour) }
        let t = store()
        for colour in PinColour.allCases where colour != .standard { t.addProject(name: colour.title, colour: colour) }
        #expect(t.nextProjectColour() == .standard)
        #expect(s.nextProjectColour() == .brown)
    }

    /// An import (another context's save — how CloudKit records will
    /// arrive) re-reads the lists and fires the signal.
    @Test func theSignalFiresWhenTheStoreChangesUnderneath() async throws {
        let s = store()
        let before = s.revision
        let other = ModelContext(s.container)
        other.insert(SavedPin(lat: -41.4, lon: 147.1, placedBy: .map, project: nil, now: .now))
        try other.save()
        await settle { s.revision > before }
        #expect(s.revision > before)
        #expect(s.pins.count == 1 && s.pins.first?.lat == -41.4)
    }

    @Test func anOnDiskStoreKeepsPinsAcrossReopening() throws {
        let dir = URL.temporaryDirectory.appending(path: "pins-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Pins.store")
        do {
            let s = PinStore(container: PinStore.makeContainer(url: url).container, defaults: freshDefaults())
            let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
            s.setTitle(pin, "Kept")
            s.flush()
        }
        let reopened = PinStore(container: PinStore.makeContainer(url: url).container, defaults: freshDefaults())
        #expect(reopened.pins.map(\.title) == ["Kept"])
    }

    @Test func theDefaultStoreLivesInApplicationSupportAndIsBackedUp() throws {
        let url = PinStore.defaultStoreURL()
        #expect(url.path(percentEncoded: false).contains("Application Support/Pins-dev/"))  // DEBUG
        #expect(url.lastPathComponent == "Pins.store")
        // the test host opened it at launch (Features.pins is on)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        for item in [url, url.deletingLastPathComponent()] {
            let values = try item.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup != true, "\(item.lastPathComponent) is excluded from backup")
        }
    }

    /// A store file that won't open: pins live in memory (and the map says
    /// so), and the file stays exactly as it was — never deleted, never
    /// overwritten, not purged.
    @Test func anUnreadableStoreFallsBackToMemoryAndLeavesTheFileAlone() throws {
        let dir = URL.temporaryDirectory.appending(path: "pins-bad-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Pins.store")
        let junk = Data(repeating: 0x5A, count: 8192)
        try junk.write(to: url)
        let opened = PinStore.makeContainer(url: url)
        #expect(opened.failed)
        let s = PinStore(container: opened.container, openFailed: opened.failed, defaults: freshDefaults())
        #expect(s.openFailed)
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.setTitle(pin, "Only in memory")
        s.flush()
        #expect(s.pins.count == 1)
        #expect(try Data(contentsOf: url) == junk)
        let healthy = PinStore.inMemory(defaults: freshDefaults())
        #expect(!healthy.openFailed)
    }

    /// Typing reaches the map only when it changes what the map draws.
    @Test func onlyLabelChangesSignalTheMap() {
        let s = store()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        var r = s.revision
        // a note is never a label (I-20)
        s.setNote(pin, "a note the map never shows")
        #expect(s.revision == r)
        s.setTitle(pin, "Gate")
        #expect(s.revision > r)
        r = s.revision
        s.setNote(pin, "titled now: the map never shows the note")
        #expect(s.revision == r)
        s.setTitle(pin, "Gate ")  // the folded label trims: same label
        #expect(s.revision == r)
        s.setTitle(pin, "Gate post")
        #expect(s.revision > r)
        r = s.revision
        s.setTitle(pin, "🐦")
        #expect(s.revision > r)  // label gone
        r = s.revision
        s.setTitle(pin, "🐦🐦")  // still no label
        #expect(s.revision == r)
        #expect(pin.title == "🐦🐦" && pin.note == "titled now: the map never shows the note")
    }

    @Test func switchedOffThereIsNoStore() {
        #expect(PinStore.launch(enabled: false) == nil)
    }
}

@MainActor
@Suite struct PinPaletteTests {
    @Test func eightNamedColoursNoneOfThemReserved() {
        let hexes = PinColour.allCases.map { $0.hex.uppercased() }
        #expect(hexes.count == 8 && Set(hexes).count == 8)
        // selection red, tree green, system blue
        for reserved in ["#FF3B30", StyleBuilder.treeGreen.uppercased(), "#007AFF", "#0088FF", PinColour.fallbackHex] {
            #expect(!hexes.contains(reserved), "\(reserved)")
        }
    }

    @Test func storedByNameUnknownNamesDrawGrey() {
        #expect(PinColour.named("teal") == .teal)
        #expect(PinColour.named("Teal") == .teal)
        #expect(PinColour.named("chartreuse") == nil)
        #expect(PinColour.named(nil) == nil)
        #expect(PinColour.hex(forName: "chartreuse") == PinColour.fallbackHex)
        #expect(PinColour.hex(forName: "") == PinColour.fallbackHex)
        #expect(PinColour.hex(forName: "violet") == PinColour.violet.hex)
    }

    @Test func aPinTakesItsOwnColourThenItsProjectsThenTheStandard() {
        let s = PinStore.inMemory(defaults: freshDefaults())
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        #expect(pin.effectiveColourName == PinColour.standard.rawValue)
        let project = s.addProject(name: "Site", colour: .magenta)
        s.setProject(pin, project)
        #expect(pin.effectiveColourName == "magenta")
        s.setColour(pin, "pink")
        #expect(pin.effectiveColourName == "pink")
        s.setColour(pin, nil)
        #expect(pin.effectiveColourName == "magenta")
        // a name from a newer build: drawn grey, nothing breaks
        s.setColour(pin, "ultramarine")
        #expect(PinPresenter.features([pin]).first?.attribute(forKey: "color") as? String == PinColour.fallbackHex)
    }
}

/// The map side: features, and the runtime layers' place in the style
/// after the style reloads (MapLibre's own parse of StyleBuilder's style).
@MainActor
@Suite(.serialized) struct PinMapTests {
    @Test func featuresCarryIdColourAndALatin1Label() {
        let s = PinStore.inMemory(defaults: freshDefaults())
        let a = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.setTitle(a, "Smith’s gully – north")
        let b = s.addPin(latitude: -42.8, longitude: 147.2, placedBy: .map)
        s.setTitle(b, "Nest 🐦")
        let features = PinPresenter.features(s.mapPins)
        #expect(features.count == 2)
        #expect(features[0].attribute(forKey: "id") as? String == a.id.uuidString)
        #expect(features[0].attribute(forKey: "label") as? String == "Smith's gully - north")
        #expect(features[1].attribute(forKey: "label") as? String == "")  // no label rather than a dropped one
        #expect(features[0].coordinate.latitude == -42.9)
    }

    private func layerIDs(_ map: MLNMapView) -> [String] {
        (map.style?.layers ?? []).map(\.identifier).filter { !$0.hasPrefix("org.maplibre.") }
    }

    @Test func pinLayersSitBetweenTreesAndSelectionAfterEveryStyleLoad() async throws {
        let tables = StyleBuilderTests.bundled
        try #require(tables.trees != nil, "bundled trees")
        var state = LayerState.default
        state.trees = true
        let model = AppModel(data: StyleBuilderTests.all, tables: tables, layers: state)
        model.pins!.addPin(latitude: -42.88, longitude: 147.33, placedBy: .map)
        let coordinator = MapCoordinator(model: model)
        let json = StyleBuilder.json(state: state, data: StyleBuilderTests.all, tables: tables)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), styleJSON: json)
        map.delegate = coordinator

        func check(_ when: String) throws {
            let ids = layerIDs(map)
            let L = StyleBuilder.LayerID.self
            let trees = try #require(ids.lastIndex(of: L.treesLabel), "\(when): trees")
            let first = try #require(ids.firstIndex(of: L.pinsHalo), "\(when): pins")
            let ring = try #require(ids.firstIndex(of: L.selectionPoint), "\(when): selection ring")
            #expect(trees < first, "\(when): \(ids)")
            #expect(ids[first ..< first + L.pins.count] == ArraySlice(L.pins), "\(when): \(ids)")
            // the ring (a selected pin's, a tree's) stays on top; a selected
            // polygon's (or tree area's) red line runs under the pins (I-21)
            #expect(first + L.pins.count == ring, "\(when): \(ids)")
            for line in [L.selectedFeature, L.selectionOutline] {
                if let i = ids.firstIndex(of: line) { #expect(i < first, "\(when): \(line) under the pins: \(ids)") }
            }
            #expect(map.style?.source(withIdentifier: StyleBuilder.SourceID.pins) is MLNShapeSource, "\(when)")
        }

        coordinator.mapView(map, didFinishLoading: try #require(map.style))
        try check("first load")

        // a layer change re-sets the whole style: the runtime layers come back
        state.base = .aerial
        state.overlay = .geology
        map.styleJSON = StyleBuilder.json(state: state, data: StyleBuilderTests.all, tables: tables)
        // MapLibre swaps the style in and tells its delegate (the coordinator)
        for _ in 0 ..< 60 where map.style?.layer(withIdentifier: StyleBuilder.LayerID.geologyFill) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(map.style?.layer(withIdentifier: StyleBuilder.LayerID.geologyFill) != nil, "the new style loaded")
        if map.style?.layer(withIdentifier: StyleBuilder.LayerID.pinsMark) == nil {
            // no delegate call on a window-less map: what didFinishLoading does
            coordinator.mapView(map, didFinishLoading: try #require(map.style))
        }
        try check("after a reload")

        // a new pin reaches the source without a style reload
        model.pins!.addPin(latitude: -42.89, longitude: 147.34, placedBy: .map)
        coordinator.apply(pins: model.pins, selectedPin: nil, to: map)
        try check("after an edit")
    }
}

/// A pin deleted on the other device (an import) closes its card here.
@MainActor
@Suite struct PinSelectionTests {
    @Test func aSelectedPinThatGoesAwayClosesItsCard() async throws {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        let id = try #require(model.selection?.pinID)
        let coordinator = MapCoordinator(model: model)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[]}"##)
        coordinator.apply(pins: model.pins, selectedPin: id, to: map)
        #expect(model.selection?.pinID == id)
        let other = ModelContext(model.pins!.container)
        let copy = try #require(try other.fetch(FetchDescriptor<SavedPin>()).first)
        copy.deletedAt = .now
        try other.save()
        await settle { model.pins!.pin(id) == nil }
        coordinator.apply(pins: model.pins, selectedPin: id, to: map)
        await settle { model.selection == nil }
        #expect(model.selection == nil)
    }
}

/// L-02: the selected disc at 13 pt — still wider than the location dot
/// (~11 pt with its rim), the red ring hugging it as before.
@Suite struct SelectedPinGeometryTests {
    @Test func theRingHugsTheSmallerDisc() {
        #expect(PinPresenter.selectedRadius == 13)
        #expect(PinPresenter.selectedRadius - 11 >= 2, "a 2 pt band of the pin's colour round the dot")
        let outer = PinPresenter.selectedRadius + PinPresenter.selectedHalo + PinPresenter.keyline
        #expect(StyleBuilder.pinRingRadius - outer == 1.25)
    }
}

/// Keeping the selected pin in sight never fights her (review S2-1): the
/// panel changing asks for a reveal, a pill or a notice never does, and
/// after her first gesture nothing does until the next selection.
@MainActor
@Suite struct PinRevealTests {
    @Test func onlyThePanelAsksAndOnlyUntilHerGesture() throws {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        let id = try #require(model.selection?.pinID)
        let coordinator = MapCoordinator(model: model)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[]}"##)
        var chrome = MapChrome(visibleInsets: UIEdgeInsets(top: 60, left: 0, bottom: 300, right: 0),
                               panelFrame: CGRect(x: 8, y: 544, width: 374, height: 300))
        coordinator.apply(chrome: chrome, to: map)
        coordinator.apply(pins: model.pins, selectedPin: id, to: map)
        #expect(coordinator.revealsScheduled == 1, "the new selection")

        // a pill or a notice appears, then goes: never a reveal
        chrome.visibleInsets = UIEdgeInsets(top: 140, left: 0, bottom: 300, right: 0)
        coordinator.apply(chrome: chrome, to: map)
        chrome.visibleInsets = UIEdgeInsets(top: 60, left: 0, bottom: 300, right: 0)
        coordinator.apply(chrome: chrome, to: map)
        #expect(coordinator.revealsScheduled == 1, "pills and notices don't move the map")

        // the sheet changes detent for this card: one
        chrome.panelFrame = CGRect(x: 8, y: 400, width: 374, height: 444)
        coordinator.apply(chrome: chrome, to: map)
        #expect(coordinator.revealsScheduled == 2, "the detent")

        // she pans: from now on nothing, not even the detent
        coordinator.mapView(map, regionWillChangeWith: .gesturePan, animated: false)
        chrome.panelFrame = CGRect(x: 8, y: 544, width: 374, height: 300)
        coordinator.apply(chrome: chrome, to: map)
        coordinator.apply(pins: model.pins, selectedPin: id, to: map)
        #expect(coordinator.revealsScheduled == 2, "after her gesture")
        #expect(!coordinator.revealGate.armed)

        // a programmatic move (a flight) is not her gesture
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.91, longitude: 147.31))
        coordinator.apply(pins: model.pins, selectedPin: model.selection?.pinID, to: map)
        #expect(coordinator.revealsScheduled == 3, "the next pin")
        coordinator.mapView(map, regionWillChangeWith: .programmatic, animated: true)
        #expect(coordinator.revealGate.armed)
    }

    /// M-02: after a move (and after Undo of one) the pin is brought clear
    /// of the "Pin moved" pill too — asked for once per move, even after
    /// her gesture had made the map hers; her next gesture cancels it.
    @Test func aMoveAsksOnceToBringThePinClearOfItsPill() throws {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        let id = try #require(model.selection?.pinID)
        let coordinator = MapCoordinator(model: model)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[]}"##)
        // the pill (y 444–502) above the sheet at its glance
        let chrome = MapChrome(visibleInsets: UIEdgeInsets(top: 60, left: 0, bottom: 844 - 444, right: 0),
                               panelFrame: CGRect(x: 8, y: 560, width: 374, height: 284))
        coordinator.apply(chrome: chrome, to: map)
        coordinator.apply(pins: model.pins, selectedPin: id, to: map)
        coordinator.apply(pinReveal: model.pinRevealRequest, to: map)
        let before = coordinator.revealsScheduled
        coordinator.mapView(map, regionWillChangeWith: .gesturePan, animated: false)
        #expect(!coordinator.revealGate.armed)

        model.startMovingPin()
        // the tap lands just above the sheet, under where the pill appears
        let spot = map.convert(CGPoint(x: 195, y: 470), toCoordinateFrom: map)
        model.movePin(to: spot)
        coordinator.apply(pins: model.pins, selectedPin: id, to: map)
        coordinator.apply(pinReveal: model.pinRevealRequest, to: map)
        #expect(coordinator.revealsScheduled == before + 1, "one reveal for the move")
        #expect(coordinator.revealGate.armed)
        // the same request again: nothing more
        coordinator.apply(pinReveal: model.pinRevealRequest, to: map)
        #expect(coordinator.revealsScheduled == before + 1)

        // the reveal itself: the pin ends above the pill
        coordinator.revealSelectedPin(map, animated: false)
        let pin = try #require(model.selectedPin)
        let point = map.convert(CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon), toPointTo: map)
        #expect(point.y <= 444 - PinFraming.comfort.bottom + 0.5, "clear of the pill: \(point.y)")

        // Undo of the move asks again
        model.undoPinDelete()
        coordinator.apply(pinReveal: model.pinRevealRequest, to: map)
        #expect(coordinator.revealsScheduled == before + 2, "Undo of the move")
    }
}

/// `Features.pins` off at the map: no long-press recogniser, no pin layers.
@MainActor
@Suite struct PinsSwitchedOffMapTests {
    private func pressRecognisers(_ map: MLNMapView) -> Int {
        (map.gestureRecognizers ?? []).filter { ($0 as? UILongPressGestureRecognizer)?.minimumPressDuration == 0.5 }.count
    }

    @Test func offMeansNoLongPressAndNoLayers() throws {
        for enabled in [true, false] {
            let model = AppModel(shared: AppData(location: .none, tables: .empty, pinsEnabled: enabled))
            model.pins?.addPin(latitude: -42.88, longitude: 147.33, placedBy: .map)
            let coordinator = MapCoordinator(model: model)
            let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                 styleJSON: ##"{"version":8,"sources":{},"layers":[{"id":"bg","type":"background"}]}"##)
            coordinator.attach(to: map)
            coordinator.mapView(map, didFinishLoading: try #require(map.style))
            coordinator.apply(pins: model.pins, selectedPin: nil, to: map)
            #expect(pressRecognisers(map) == (enabled ? 1 : 0), "enabled \(enabled)")
            #expect((map.style?.layer(withIdentifier: StyleBuilder.LayerID.pinsMark) != nil) == enabled, "enabled \(enabled)")
        }
    }

    /// The pin button's pin out of sight: the camera goes to it; in sight: stays.
    @Test func aPinOutOfSightBringsTheCamera() throws {
        let model = AppModel(data: .none, tables: .empty)
        let coordinator = MapCoordinator(model: model)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[]}"##)
        map.setCenter(CLLocationCoordinate2D(latitude: -42.88, longitude: 147.33), zoomLevel: 15, animated: false)
        // in sight: nothing moves
        model.focusPin(latitude: -42.8801, longitude: 147.3301)
        coordinator.apply(pinFocus: model.pinFocus, framing: .zero, to: map, animated: false)
        #expect(abs(map.centerCoordinate.latitude - -42.88) < 1e-9)
        // 5 km away: the camera goes there, at the same zoom
        // (a window-less map never finishes an animation: the cut, as under Reduce Motion)
        model.focusPin(latitude: -42.93, longitude: 147.33)
        coordinator.apply(pinFocus: model.pinFocus, framing: .zero, to: map, animated: false)
        #expect(abs(map.centerCoordinate.latitude - -42.93) < 1e-4)
        #expect(abs(map.zoomLevel - 15) < 1e-6)
    }
}

/// The window's pin gestures and actions.
@MainActor
@Suite struct PinModelTests {
    private func model(_ clock: ManualClock = ManualClock()) -> AppModel {
        let m = AppModel(data: .none, tables: .empty, clock: clock.clock)
        // the tests hand the fixes in; never the test host's Core Location
        m.watchesFreshFixes = false
        return m
    }

    nonisolated private static let here = CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3)

    @Test func aLongPressDropsAPinSelectsItAndFocusesTheTitle() throws {
        let m = model()
        let placed = m.pinPlacedCount
        m.dropPin(at: Self.here)
        let pin = try #require(m.pins!.pins.first)
        #expect(pin.placement == .map && pin.lat == -42.9)
        #expect(m.selection?.pinID == pin.id && m.selectedPin?.id == pin.id)
        #expect(m.pinTitleFocus == pin.id)
        #expect(m.pinPlacedCount == placed + 1)  // the haptic's trigger
    }

    @Test func overlayAndTreeChangesKeepAPinCard() {
        let m = model()
        m.dropPin(at: Self.here)
        m.layers.overlay = .geology
        m.layers.trees.toggle()
        #expect(m.selection?.isPin == true)
    }

    @Test func escapeCancelsAMoveThenClosesTheCard() throws {
        let m = model()
        m.dropPin(at: Self.here)
        m.startMovingPin()
        #expect(m.escapeStep == .cancelPinMove)
        m.escape()
        #expect(m.movingPin == nil && m.selection?.isPin == true)
        #expect(m.escapeStep == .closeCard)
        m.escape()
        #expect(m.selection == nil)
    }

    @Test func moveModeTakesTheNextTap() throws {
        let m = model()
        m.dropPin(at: Self.here)
        let pin = try #require(m.selectedPin)
        m.startMovingPin()
        m.movePin(to: CLLocationCoordinate2D(latitude: -42.95, longitude: 147.35))
        #expect(m.movingPin == nil && pin.lat == -42.95 && pin.lon == 147.35)
        #expect(m.selection?.pinID == pin.id)
    }

    @Test func deleteOffersUndoWhichBringsThePinBack() async throws {
        let clock = ManualClock()
        let m = model(clock)
        m.dropPin(at: Self.here)
        let id = try #require(m.selectedPin?.id)
        m.deletePin(id)
        #expect(m.selection == nil && m.pins!.pins.isEmpty)
        #expect(m.pinUndo?.pin == id)
        m.undoPinDelete()
        #expect(m.pinUndo == nil && m.pins!.pins.map(\.id) == [id])
        #expect(m.selection?.pinID == id)
        // the banner goes by itself
        m.deletePin(id)
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.pinUndoDuration)
        await settle { m.pinUndo == nil }
        #expect(m.pinUndo == nil)
        #expect(m.pins!.pins.isEmpty)  // still deleted (Recently deleted)
    }

    /// The pin button never guesses: no fix → the notice, no pin.
    @Test func thePinButtonNeedsAUsableFix() throws {
        let m = model()
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var system: CLLocation?
        m.wallClock = { now }
        m.systemLocation = { system }
        m.authorization = .authorizedWhenInUse
        m.pinCurrentLocation()
        // allowed, but no fix has come yet: wait — or long-press
        #expect(m.pins?.pins.isEmpty == true && m.notice == .waitingForPin)
        // ("long‑press" never breaks across lines: U+2011)
        #expect(LocationNotice.waitingForPin.message.contains("long\u{2011}press"))
        #expect(LocationNotice.noFixForPin.message.contains("long\u{2011}press"))

        // a fix too coarse to pin: fixes came, none usable — long-press
        m.locationUpdated(Self.fix(accuracy: 3000, at: now))
        #expect(m.pins?.pins.isEmpty == true, "a coarse fix places nothing")
        m.pinCurrentLocation()
        #expect(m.pins?.pins.isEmpty == true && m.notice == .noFixForPin)

        // a good one: pinned with its accuracy and altitude, the camera told
        m.locationUpdated(Self.fix(accuracy: 6, altitude: 412, at: now))
        m.pinCurrentLocation()
        let pin = try #require(m.pins?.pins.first)
        #expect(pin.placement == .gps && pin.accuracy == 6 && pin.altitude == 412)
        #expect(m.selection?.pinID == pin.id)
        #expect(m.pinFocus?.latitude == pin.lat && m.pinFocus?.longitude == pin.lon)
        #expect(PinCard.source(pin) == "GPS ± 6\u{00A0}m · 412\u{00A0}m altitude")

        // a minute later MapLibre's last report is stale …
        now = now.addingTimeInterval(61)
        m.pinCurrentLocation()
        #expect(m.pins?.pins.count == 1 && m.notice == .noFixForPin)

        // … standing still, Core Location's own latest is fresh: that pins
        // (MapLibre drops a same-coordinate sample: StandingStillTests)
        system = Self.fix(accuracy: 4, altitude: 410, at: now.addingTimeInterval(-2))
        m.pinCurrentLocation()
        #expect(m.pins?.pins.count == 2)
        #expect(m.selectedPin?.accuracy == 4)
    }

    /// Of the two sources, the newer usable fix wins.
    @Test func theFreshestFixWins() {
        let m = model()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        m.wallClock = { now }
        m.locationUpdated(Self.fix(accuracy: 5, at: now.addingTimeInterval(-30)))
        m.systemLocation = { Self.fix(accuracy: 8, at: now.addingTimeInterval(-1)) }
        #expect(m.usableFix?.horizontalAccuracy == 8)
        m.systemLocation = { Self.fix(accuracy: 8, at: now.addingTimeInterval(-50)) }
        #expect(m.usableFix?.horizontalAccuracy == 5)
    }

    private static func fix(accuracy: Double, altitude: Double = 0, at time: Date) -> CLLocation {
        CLLocation(coordinate: here, altitude: altitude, horizontalAccuracy: accuracy,
                   verticalAccuracy: altitude == 0 ? -1 : 4, timestamp: time)
    }

    @Test func closingTheCardOrSelectingElseEndsAMove() throws {
        let m = model()
        m.dropPin(at: Self.here)
        m.startMovingPin()
        m.clearSelection()
        #expect(m.movingPin == nil)
        m.dropPin(at: Self.here)
        m.startMovingPin()
        m.select(.geology("Jd"))
        #expect(m.movingPin == nil)
    }

    @Test func escapeClosesTheNewProjectFormFirst() {
        let m = model()
        m.dropPin(at: Self.here)
        m.pinProjectForm = true
        #expect(m.escapeStep == .closeProjectForm)
        m.escape()
        #expect(!m.pinProjectForm && m.selection?.isPin == true)
        #expect(m.escapeStep == .closeCard)
        // a new selection never inherits an open form
        m.pinProjectForm = true
        m.dropPin(at: Self.here)
        #expect(!m.pinProjectForm)
        // something typed in it: Escape asks the form (its "Discard
        // changes" question), never throws the typing away
        m.pinProjectForm = true
        m.pinProjectFormEdited = true
        let asked = m.pinProjectFormEscape
        m.escape()
        #expect(m.pinProjectForm && m.pinProjectFormEscape == asked + 1)
    }

    /// Pins open over the iPad's Layers popover (or Storage): no second
    /// Undo pill on the map behind it, and ⌘P has nothing to open.
    @Test func thePinsScreenOverLayersKeepsTheMapPillDown() throws {
        let m = model()
        m.dropPin(at: Self.here)
        let id = try #require(m.selection?.pinID)
        m.deletePin(id)
        #expect(m.mapPinUndo != nil && m.canPresentPins)
        m.pinsScreenShown = true
        #expect(m.mapPinUndo == nil && m.pinUndo != nil)
        #expect(!m.canPresentPins)
    }

    /// `Features.pins` off: no store, and nothing pin-related happens.
    @Test func switchedOffPinsDoNothing() throws {
        let m = AppModel(shared: AppData(location: .none, tables: .empty, pinsEnabled: false))
        #expect(m.pins == nil)
        m.dropPin(at: Self.here)
        m.authorization = .authorizedWhenInUse
        m.pinCurrentLocation()
        #expect(m.selection == nil && m.notice == nil)
    }

    @Test func thePinButtonAsksWhenLocationWasNeverAllowed() {
        let m = model()
        m.systemLocation = { nil }
        m.authorization = .notDetermined
        let asked = m.locationRequest
        m.pinCurrentLocation()
        // iOS is asking: "Waiting for a location fix — or long-press …"
        #expect(m.locationRequest == asked + 1 && m.notice == .waitingForPin)
        m.authorization = .denied
        m.pinCurrentLocation()
        // the pin button's denied notice names the long-press, then Settings
        #expect(m.notice == .deniedForPin && m.pins!.pins.isEmpty)
        #expect(LocationNotice.deniedForPin.offersSettings && LocationNotice.denied.offersSettings)
        #expect(LocationNotice.deniedForPin.message.contains("long\u{2011}press"))
        // "Move to my location": its own denied notice — Move on map, then
        // Settings; never the long-press (that would place a second pin)
        m.dropPin(at: Self.here)
        m.movePinToMyLocation()
        #expect(m.notice == .deniedForMove && m.notice?.offersSettings == true)
        #expect(LocationNotice.deniedForMove.message.contains("Move on map"))
    }

    /// Review S2-2: "Move to my location" without a fix says how to MOVE
    /// it, whether a fix is still to come or none usable came.
    @Test func moveToMyLocationWithoutAFixPointsToMoveOnMap() throws {
        let m = model()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        m.wallClock = { now }
        m.systemLocation = { nil }
        m.dropPin(at: Self.here)
        let pin = try #require(m.selectedPin)
        for (status, fix) in [(CLAuthorizationStatus.notDetermined, nil),
                              (.authorizedWhenInUse, nil),
                              (.authorizedWhenInUse, Self.fix(accuracy: 3000, at: now))] {
            m.dismissNotice()
            m.authorization = status
            if let fix { m.locationUpdated(fix) }
            m.movePinToMyLocation()
            #expect(m.notice == .noFixForMove, "\(status.rawValue)")
            #expect(m.pendingPin == nil, "a move never waits")
            #expect(pin.lat == Self.here.latitude && pin.placement == .map)
        }
        for notice in [LocationNotice.noFixForMove, .deniedForMove] {
            #expect(!notice.message.contains("long-press"), "\(notice)")
            #expect(notice.isPinNotice)
        }
    }

    /// "No location yet — use Move on map instead." goes once there is a
    /// fix to move to, and when a later "Move to my location" works.
    @Test func theMoveNoticeGoesWithAFix() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = model()
        m.wallClock = { now }
        m.systemLocation = { nil }
        m.authorization = .authorizedWhenInUse
        m.dropPin(at: Self.here)
        m.movePinToMyLocation()
        #expect(m.notice == .noFixForMove)
        // a stale sample: still none to move to
        m.locationUpdated(Self.fix(accuracy: 5, at: now.addingTimeInterval(-120)))
        #expect(m.notice == .noFixForMove)
        m.locationUpdated(Self.fix(accuracy: 5, at: now))
        #expect(m.notice == nil, "a usable fix came")
        // the notice up, the system's own fix fresh (MapLibre silent): Move works and the notice goes
        let n = model()
        var system: CLLocation?
        n.wallClock = { now }
        n.systemLocation = { system }
        n.authorization = .authorizedWhenInUse
        n.dropPin(at: Self.here)
        n.movePinToMyLocation()
        #expect(n.notice == .noFixForMove)
        system = Self.fix(accuracy: 4, at: now)
        n.movePinToMyLocation()
        #expect(n.notice == nil && n.pinUndo?.movedFrom != nil)
        #expect(n.pendingPin == nil && n.pinRevealRequest > 0)
    }

    /// A model whose pin button is waiting (allowed, no fix yet), pressed
    /// at `pressed`.
    private func waiting(_ clock: ManualClock = ManualClock(), pressed: Date) -> AppModel {
        let m = model(clock)
        m.wallClock = { pressed }
        m.systemLocation = { nil }
        m.authorization = .authorizedWhenInUse
        m.pinCurrentLocation()
        return m
    }

    /// "Waiting for a location fix": the pin goes at the first FRESH fix —
    /// taken at or after the press — as a pin-button press would place it.
    @Test func aPinWaitingForAFixIsPlacedAtTheFirstFreshFix() throws {
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = waiting(pressed: pressed)
        #expect(m.notice == .waitingForPin && m.pendingPin == PendingPin(pressedAt: pressed))
        // Core Location's cached sample (older than the press) — often the
        // first one after the permission prompt — neither places nor ends it
        m.locationUpdated(Self.fix(accuracy: 6, at: pressed.addingTimeInterval(-30)))
        #expect(m.pins!.pins.isEmpty && m.notice == .waitingForPin && m.pendingPin != nil)
        // nor does a fresh but coarse one (a better one may follow)
        m.locationUpdated(Self.fix(accuracy: 3000, at: pressed.addingTimeInterval(1)))
        #expect(m.pins!.pins.isEmpty && m.notice == .waitingForPin && m.pendingPin != nil)
        // nor an invalid one
        m.locationUpdated(Self.fix(accuracy: -1, at: pressed.addingTimeInterval(1)))
        #expect(m.pins!.pins.isEmpty && m.pendingPin != nil)
        // the fresh fix: the pin, its accuracy honest (a Wi-Fi iPad's may be coarse)
        let placed = m.pinPlacedCount
        m.locationUpdated(Self.fix(accuracy: 180, altitude: 40, at: pressed.addingTimeInterval(2)))
        let pin = try #require(m.pins?.pins.first, "placed at the fresh fix")
        #expect(pin.placement == .gps && pin.accuracy == 180 && pin.altitude == 40)
        #expect(m.selection?.pinID == pin.id && m.pinPlacedCount == placed + 1)
        #expect(m.pinFocus?.latitude == pin.lat)
        #expect(m.notice == nil && m.pendingPin == nil)
        // a fix taken exactly at the press counts too
        let n = waiting(pressed: pressed)
        n.locationUpdated(Self.fix(accuracy: 5, at: pressed))
        #expect(n.pins!.pins.count == 1)
    }

    /// The wait never reads the system's cached position: only a fix
    /// that arrives counts.
    @Test func aWaitingPinIgnoresTheSystemsCachedPosition() {
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = waiting(pressed: pressed)
        m.wallClock = { pressed.addingTimeInterval(3) }
        m.systemLocation = { Self.fix(accuracy: 5, at: pressed.addingTimeInterval(-5)) }
        m.locationUpdated(nil)
        #expect(m.pins!.pins.isEmpty && m.pendingPin != nil)
    }

    /// Its notice runs out without a fresh fix: the honest "No location
    /// yet — long-press…", and a fix after that places nothing.
    @Test func aWaitingPinExpiresWithItsNotice() async {
        let clock = ManualClock()
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = waiting(clock, pressed: pressed)
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.noticeDuration)
        await settle { m.notice == .noFixForPin }
        #expect(m.notice == .noFixForPin && m.pendingPin == nil)
        m.locationUpdated(Self.fix(accuracy: 5, at: pressed.addingTimeInterval(11)))
        #expect(m.pins!.pins.isEmpty)
    }

    /// Anything else she does while it waits cancels it — silently, the
    /// waiting notice goes, and the fresh fix later places nothing.
    @Test func everythingElseCancelsAWaitingPin() throws {
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let cancels: [(String, (AppModel) -> Void)] = [
            ("notice dismissed", { $0.dismissNotice() }),
            ("notice replaced", { $0.show(.noFix) }),
            ("a map tap", { $0.select(.geology("Jd")) }),
            ("card closed", { $0.clearSelection() }),
            ("a long-press", { $0.dropPin(at: CLLocationCoordinate2D(latitude: -42.95, longitude: 147.35)) }),
            ("search", { $0.search.begin() }),
            ("Move", { $0.movingPin = UUID() }),
            ("a modal", { $0.present(.layers) }),
            ("the Pins screen over Layers", { $0.pinsScreenShown = true }),
            ("the project form", { $0.pinProjectForm = true }),
            ("camera or library", { $0.pinPhotoSourceShown = true }),
            ("a photo", { $0.photoViewer = UUID() }),
            ("a pushed card view", { $0.push(.group(key: "G", context: PlantContext())) }),
            ("framing an area", { $0.startFraming() }),
            ("the background", { $0.scenePhaseChanged(active: false, background: true) }),
            ("inactive (not iOS's prompt)", { $0.scenePhaseChanged(active: false, background: false) }),
        ]
        for (name, cancel) in cancels {
            let m = model()
            // a card open before the press (pushing needs one; the press
            // itself keeps it)
            m.select(.geology("Jd"))
            m.wallClock = { pressed }
            m.systemLocation = { nil }
            m.authorization = .authorizedWhenInUse
            m.pinCurrentLocation()
            #expect(m.pendingPin != nil && m.selection != nil, "\(name): waiting")
            cancel(m)
            #expect(m.pendingPin == nil, "\(name): cancelled")
            #expect(m.notice != .waitingForPin, "\(name): the waiting notice goes")
            let before = m.pins!.pins.count
            m.locationUpdated(Self.fix(accuracy: 5, at: pressed.addingTimeInterval(2)))
            #expect(m.pins!.pins.count == before, "\(name): nothing placed at the fix")
        }
    }

    /// iOS's own permission prompt (the pin button raised it) makes the
    /// window inactive: that is the wait itself, not something else.
    @Test func thePermissionPromptKeepsTheWait() throws {
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = model()
        m.wallClock = { pressed }
        m.systemLocation = { nil }
        m.authorization = .notDetermined
        m.pinCurrentLocation()
        #expect(m.pendingPin != nil && m.notice == .waitingForPin)
        m.scenePhaseChanged(active: false, background: false)  // the prompt
        #expect(m.pendingPin != nil)
        m.authorizationChanged(to: .authorizedWhenInUse)       // Allow
        // the wait goes on, its notice with its full time again
        #expect(m.notice == .waitingForPin && m.pendingPin == PendingPin(pressedAt: pressed))
        // the fix may come before the window is active again
        m.locationUpdated(Self.fix(accuracy: 8, at: pressed.addingTimeInterval(3)))
        #expect(m.pins?.pins.count == 1 && m.selection?.pinID != nil)
    }

    /// The prompt unanswered: the wait outlasts its notice's 10 s (she is
    /// reading the prompt), for up to a minute after the press.
    @Test func thePromptUnansweredKeepsTheWaitUpToAMinute() async {
        let clock = ManualClock()
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = model(clock)
        m.wallClock = { now }
        m.systemLocation = { nil }
        m.authorization = .notDetermined
        m.pinCurrentLocation()
        for _ in 0 ..< 5 {
            await settle { clock.sleeperCount > 0 }
            now = now.addingTimeInterval(10)
            clock.advance(by: AppModel.noticeDuration)
            await settle()
            #expect(m.notice == .waitingForPin && m.pendingPin != nil)
        }
        await settle { clock.sleeperCount > 0 }
        now = now.addingTimeInterval(10)
        clock.advance(by: AppModel.noticeDuration)
        await settle { m.notice == .noFixForPin }
        #expect(m.notice == .noFixForPin && m.pendingPin == nil, "a minute on: the honest notice")
    }

    /// Don't Allow: the denied notice (with the long-press), no wait.
    @Test func thePermissionPromptDeclinedSaysSo() {
        let m = model()
        m.wallClock = { Date(timeIntervalSinceReferenceDate: 1_000_000) }
        m.systemLocation = { nil }
        m.authorization = .notDetermined
        m.pinCurrentLocation()
        m.authorizationChanged(to: .denied)
        #expect(m.notice == .deniedForPin && m.pendingPin == nil)
    }

    /// The prompt answered Allow late: the notice's time starts again then.
    @Test func allowRestartsTheWaitingNoticesTime() async {
        let clock = ManualClock()
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = model(clock)
        m.wallClock = { pressed }
        m.systemLocation = { nil }
        m.authorization = .notDetermined
        m.pinCurrentLocation()
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(8))
        m.authorizationChanged(to: .authorizedWhenInUse)
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(8))
        await settle()
        #expect(m.notice == .waitingForPin && m.pendingPin != nil, "16 s after the press, 8 after Allow")
        m.locationUpdated(Self.fix(accuracy: 5, at: pressed.addingTimeInterval(16)))
        #expect(m.pins!.pins.count == 1)
    }

    /// The fresh fix arrives while something is up that no cancel path saw
    /// (checked again at arrival): the wait ends, no pin.
    @Test func aFixArrivingWhileSomethingIsUpPlacesNothing() {
        let pressed = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m = waiting(pressed: pressed)
        m.sceneInBackground = true
        m.locationUpdated(Self.fix(accuracy: 5, at: pressed.addingTimeInterval(2)))
        #expect(m.pins!.pins.isEmpty && m.pendingPin == nil && m.notice == nil)
        #expect(!m.pinPlacementIsClear)
    }

    /// Move offers Undo, which puts the pin back where — and as — it was.
    @Test func moveOffersUndoWhichPutsThePinBack() throws {
        let m = model()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        m.wallClock = { now }
        m.systemLocation = { nil }
        m.authorization = .authorizedWhenInUse
        m.locationUpdated(Self.fix(accuracy: 6, altitude: 412, at: now))
        m.pinCurrentLocation()
        let pin = try #require(m.selectedPin)
        #expect(pin.placement == .gps)
        m.startMovingPin()
        m.movePin(to: CLLocationCoordinate2D(latitude: -42.95, longitude: 147.35))
        #expect(pin.lat == -42.95 && pin.placement == .map && pin.accuracy == nil)
        let undo = try #require(m.pinUndo)
        #expect(undo.movedFrom != nil && PinUndoBanner.headline(undo) == "Pin moved")
        m.undoPinDelete()
        #expect(m.pinUndo == nil)
        #expect(pin.lat == Self.here.latitude && pin.lon == Self.here.longitude)
        #expect(pin.placement == .gps && pin.accuracy == 6 && pin.altitude == 412)
        #expect(m.selection?.pinID == pin.id && pin.deletedAt == nil)
        // a delete's pill says so
        m.deletePin(pin.id)
        #expect(m.pinUndo.map(PinUndoBanner.headline) == "Pin deleted")
    }

    /// The card's words: the source line and the colour reset button.
    @Test func theCardSaysHowAPinWasPlacedAndWhatItsColourResetsTo() throws {
        let m = model()
        m.dropPin(at: Self.here)
        let pin = try #require(m.selectedPin)
        #expect(PinCard.source(pin) == "By hand on the map")
        // the colour in effect, no override: no reset button
        #expect(PinCard.resetTitle(pin) == nil)
        m.pins!.setColour(pin, PinColour.teal.rawValue)
        #expect(PinCard.resetTitle(pin) == "Use standard colour")
        let site = m.pins!.addProject(name: "Knocklofty", colour: .violet)
        m.pins!.setProject(pin, site)
        #expect(PinCard.resetTitle(pin) == "Use project colour")
        m.pins!.setColour(pin, nil)
        #expect(PinCard.resetTitle(pin) == nil && pin.effectiveColourName == PinColour.violet.rawValue)
    }
}

/// What MapLibre Native 7.0.0 does with a new Core Location sample at the
/// SAME coordinate (standing still): observed through the delegate.
@MainActor
final class LocationSpy: NSObject, MLNMapViewDelegate {
    var timestamps: [Date] = []
    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
        if let t = userLocation?.location?.timestamp { timestamps.append(t) }
    }
}

@MainActor
@Suite struct StandingStillTests {
    /// Measured 2026-11-24: MapLibre Native 7.0.0 ignores a sample whose
    /// coordinate equals the last one — no delegate call, and
    /// `userLocation.location` keeps the OLD timestamp. So standing still,
    /// the map's last report ages while Core Location keeps fresh fixes;
    /// the pin button reads Core Location's own (`SystemLocation`). If a
    /// MapLibre update changes this, this test says so.
    @Test func mapLibreDropsASameCoordinateSample() async {
        let manager = FakeLocationManager(status: .authorizedWhenInUse)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[]}"##)
        map.locationManager = manager
        let spy = LocationSpy()
        map.delegate = spy
        map.showsUserLocation = true
        let c = CLLocationCoordinate2D(latitude: -42.88, longitude: 147.33)
        let t0 = Date(timeIntervalSinceReferenceDate: 0), t1 = t0.addingTimeInterval(120)
        manager.deliver(CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: t0))
        await settle { spy.timestamps.count >= 1 }
        #expect(spy.timestamps == [t0])
        manager.deliver(CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: t1))
        await settle { spy.timestamps.count >= 2 }
        #expect(spy.timestamps == [t0], "MapLibre now reports a same-coordinate sample")
        #expect(map.userLocation?.location?.timestamp == t0)
        // a moved sample does arrive
        let moved = CLLocationCoordinate2D(latitude: -42.8801, longitude: 147.33)
        manager.deliver(CLLocation(coordinate: moved, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                   timestamp: t1.addingTimeInterval(1)))
        await settle { spy.timestamps.count >= 2 }
        #expect(spy.timestamps.count == 2)
    }
}
