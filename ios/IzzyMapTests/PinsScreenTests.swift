import CoreLocation
import Foundation
import IzzyKit
import MapLibre
import SwiftData
import Testing
import UIKit
@testable import IzzyMap

@MainActor
private func freshStore(_ clock: DateBox = DateBox()) -> PinStore {
    PinStore.inMemory(defaults: UserDefaults(suiteName: "izzymap-pinsscreen-\(UUID().uuidString)")!, now: { clock.now })
}

/// One name for a pin everywhere: rows, the card's empty title, the map label.
@MainActor
@Suite struct PinTitleTests {
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)  // 2026-05-09

    @Test func titleThenNoteThenDate() {
        #expect(PinText.title(title: "  Gate ", note: "Locked", createdAt: day, now: day) == "Gate")
        #expect(PinText.title(title: "", note: "\n  \nSphagnum, Richea\nCheck in spring", createdAt: day, now: day) == "Sphagnum, Richea")
        #expect(PinText.title(title: " ", note: "", createdAt: day, now: day) == "Pin · \(PinText.shortDate(day, now: day))")
        // another year's pin says which
        let later = day.addingTimeInterval(400 * 86_400)
        let other = PinText.title(title: "", note: "", createdAt: day, now: later)
        #expect(other.contains("2026") && other.hasPrefix("Pin · "))
    }

    @Test func aLongFirstLineIsClippedOnAWord() {
        let line = "Wattle regrowth along the fire trail — mostly Acacia dealbata and some melanoxylon"
        let title = PinText.title(title: "", note: line, createdAt: day, now: day)
        #expect(title.hasSuffix("…") && title.count <= PinText.noteTitleLimit + 1)
        #expect(line.hasPrefix(String(title.dropLast())))
        #expect(!title.dropLast().hasSuffix(" "))
    }

    @Test func theMapLabelAndTheCardUseTheSameName() {
        let s = freshStore()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        #expect(pin.displayTitle.hasPrefix("Pin · "))
        // no title, no note: the map draws no label (dates would clutter it)
        #expect(PinPresenter.label(pin) == nil)
        #expect(PinPresenter.features([pin]).first?.attribute(forKey: "label") as? String == "")
        // a note is never the map label (I-20: a note is no name)
        s.setNote(pin, "Smith’s gully – north side\nmore")
        #expect(PinPresenter.features([pin]).first?.attribute(forKey: "label") as? String == "")
        // a title is, folded to Latin-1
        s.setTitle(pin, "Smith’s gully – north side")
        #expect(PinPresenter.features([pin]).first?.attribute(forKey: "label") as? String == "Smith's gully - north side")
        s.setTitle(pin, "Nest 🐦")
        // one the map can't draw: no label rather than a dropped one
        #expect(pin.displayTitle == "Nest 🐦" && PinPresenter.label(pin) == nil)
    }

    @Test func aNoteNeverSignalsTheMap() {
        let s = freshStore()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        var before = s.revision
        s.setNote(pin, "Seep")  // untitled: still no label (I-20)
        #expect(s.revision == before)
        s.setTitle(pin, "Gate")
        #expect(s.revision > before)
        before = s.revision
        s.setNote(pin, "Anything")  // titled: the note never shows on the map
        #expect(s.revision == before)
    }

    /// Long titles are clipped on a word boundary before the map folds them.
    @Test func aLongTitleIsClippedForTheMap() throws {
        let s = freshStore()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.setTitle(pin, "Wattle regrowth along the fire trail below the old quarry gate")
        let label = try #require(PinPresenter.label(pin))
        #expect(label.hasSuffix("...") && label.count <= PinPresenter.labelLimit + 3)
        #expect(MapText.isLatin1(label))
    }

    @Test func dateRangesReadLikeTheSingleDates() {
        let cal = Calendar.current
        let a = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        let b = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        let c = cal.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 12))!
        let now = b
        #expect(PinText.dateRange([], now: now) == nil)
        #expect(PinText.dateRange([b], now: now) == PinText.shortDate(b, now: now))
        let month = PinText.dateRange([b, a], now: now)!
        #expect(month.contains(PinText.shortDate(b, now: now)) || month.contains("11"))
        #expect(PinText.dateRange([a, c], now: now) == "\(PinText.shortDate(a, now: now)) – \(PinText.shortDate(c, now: now))")
        #expect(PinText.count(1) == "1 pin" && PinText.count(12) == "12 pins")
    }
}

/// What the Pins screen's lists show as projects are archived, deleted,
/// restored and purged.
@MainActor
@Suite struct PinsListTests {
    @Test func archivingMovesAProjectOutOfTheWayButKeepsItsPins() {
        let s = freshStore()
        let site = s.addProject(name: "Old site", colour: .brown)
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.setArchived(site, true)
        #expect(s.activeProjects.isEmpty && s.archivedProjects.map(\.id) == [site.id])
        #expect(s.pins(in: site).map(\.id) == [pin.id])  // listed on its page
        #expect(s.mapPins.isEmpty && !pin.isOnMap)  // not on the map, not a way to it
        s.setArchived(site, false)
        #expect(s.activeProjects.map(\.id) == [site.id] && pin.isOnMap)
    }

    @Test func deletingAProjectListsItOnceWithItsPins() throws {
        let clock = DateBox()
        let s = freshStore(clock)
        let site = s.addProject(name: "Knocklofty", colour: .teal)
        let a = s.addPin(latitude: -42.88, longitude: 147.31, placedBy: .map)
        let b = s.addPin(latitude: -42.89, longitude: 147.32, placedBy: .map)
        s.setProject(b, nil)
        let alone = s.addPin(latitude: -42.87, longitude: 147.30, placedBy: .map)
        s.setProject(alone, site)
        #expect(alone.project?.id == site.id && a.project?.id == site.id)
        clock.advance(days: 1)
        s.delete(alone)  // deleted on its own, BEFORE the project
        clock.advance(days: 1)
        #expect(s.pins(in: nil).map(\.id) == [b.id] && s.unfiledCount == 1)
        s.deleteProject(site)
        #expect(s.projects.isEmpty && s.pins.map(\.id) == [b.id])
        #expect(s.deletedProjects.map(\.id) == [site.id])
        #expect(s.pinsDeleted(with: site).map(\.id) == [a.id])
        // listed exactly once: on its own, not under the project
        #expect(s.deletedPins.map(\.id) == [alone.id])
        #expect(s.daysLeft(site.deletedAt) == 30)
        clock.advance(days: 29.5)
        #expect(s.daysLeft(site.deletedAt) == 1)

        // restoring the project brings back only the pins that went with it
        s.restoreProject(site)
        #expect(s.projects.map(\.id) == [site.id] && s.pins(in: site).map(\.id) == [a.id])
        #expect(alone.deletedAt != nil && s.deletedPins.map(\.id) == [alone.id])

        // deleted again with the project: still listed once, on its own
        s.deleteProject(site)
        #expect(s.deletedPins.map(\.id) == [alone.id] && s.pinsDeleted(with: site).map(\.id) == [a.id])
        // restored while its project is deleted, it comes back Unfiled
        s.restore(alone)
        #expect(alone.project == nil && alone.isOnMap && s.unfiledCount == 2)
        #expect(s.deletedPins.isEmpty && s.deletedProjects.map(\.id) == [site.id])
    }

    @Test func deleteNowAndDeleteAllNowAreForGood() throws {
        let s = freshStore()
        let site = s.addProject(name: "Gone", colour: .gold)
        let inSite = s.addPin(latitude: -42.88, longitude: 147.31, placedBy: .map)
        s.setProject(inSite, site)
        s.lastUsedProject = nil
        let keep = s.addPin(latitude: -42.86, longitude: 147.30, placedBy: .map)
        let one = s.addPin(latitude: -42.87, longitude: 147.30, placedBy: .map)
        let two = s.addPin(latitude: -42.85, longitude: 147.30, placedBy: .map)
        s.delete(one)
        s.delete(two)
        s.deleteProject(site)
        s.deleteNow(one)
        #expect(s.anyPin(one.id) == nil && s.deletedPins.map(\.id) == [two.id])
        s.deleteNow(site)
        #expect(s.deletedProjects.isEmpty && s.anyPin(inSite.id) == nil)
        s.deleteAllNow()
        #expect(!s.hasDeleted && s.anyPin(two.id) == nil)
        let saved = try ModelContext(s.container).fetch(FetchDescriptor<SavedPin>())
        #expect(saved.map(\.id) == [keep.id])
        // "Delete now" never touches what isn't deleted
        s.deleteNow(keep)
        #expect(s.pin(keep.id) != nil)
    }

    @Test func storageCountsAndSize() async throws {
        #expect(PinsStorageSection.title(pins: 0, projects: 0) == "No pins yet")
        #expect(PinsStorageSection.title(pins: 1, projects: 0) == "1 pin")
        #expect(PinsStorageSection.title(pins: 12, projects: 3) == "12 pins in 3 projects")
        #expect(PinsStorageSection.size(0) == nil)
        #expect(PinsStorageSection.size(248_000) == "248\u{00A0}KB")
        #expect(await freshStore().bytesOnDisk() == 0)  // in memory
        // on disk: the store and its journal, nothing else in the folder
        let dir = FileManager.default.temporaryDirectory.appending(path: "pins-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 50_000).write(to: dir.appending(path: "Other.bin"))
        let url = dir.appending(path: "Pins.store")
        let store = PinStore(container: PinStore.makeContainer(url: url).container,
                             defaults: UserDefaults(suiteName: "izzymap-size-\(UUID().uuidString)")!)
        store.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let saves = store.saves
        store.addPin(latitude: -42.8, longitude: 147.2, placedBy: .map)
        #expect(store.saves > saves)  // Storage re-measures on this
        let bytes = await store.bytesOnDisk()
        #expect(bytes > 0 && bytes == PinStore.bytes(of: url))
        let folder = AreaStore.size(of: dir)
        #expect(folder >= Int64(bytes) + 50_000)  // Other.bin isn't counted
    }
}

/// "Show on map" and a picked pin: the camera's target.
@MainActor
@Suite(.serialized) struct PinFramingTests {
    private func map() -> MLNMapView {
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[]}"##)
        map.setCenter(CLLocationCoordinate2D(latitude: -42.0, longitude: 146.5), zoomLevel: 8, animated: false)
        return map
    }

    @Test func boxAndMargins() {
        #expect(PinFraming.box([]) == nil)
        let one = CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3)
        #expect(PinFraming.box([one]) == [147.3, -42.9, 147.3, -42.9])
        let box = PinFraming.box([one, .init(latitude: -42.8, longitude: 147.1), .init(latitude: -42.95, longitude: 147.2)])
        #expect(box == [147.1, -42.95, 147.3, -42.8])
        // chrome plus room for the mark and its label: never less than 44 pt
        let m = PinFraming.margin(framing: UIEdgeInsets(top: 60, left: 0, bottom: 300, right: 70), in: CGSize(width: 390, height: 844))
        #expect(m.top == 60 + 44 && m.left == 44 && m.right == 70 + 44 && m.bottom == 300 + 44)
        let wide = PinFraming.margin(framing: .zero, in: CGSize(width: 1366, height: 1024))
        #expect(abs(wide.left - 1366 * 0.06) < 0.01 && abs(wide.top - 1024 * 0.08) < 0.01)
    }

    @Test func aSinglePinIsFramedNoCloserThanTheMaxZoom() {
        let map = map()
        let box = PinFraming.box([CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3)])!
        let camera = MapCamera.fit(box, maxZoom: PinFraming.maxZoom, insets: PinFraming.margin(framing: .zero, in: map.bounds.size), in: map)
        let zoom = MLNZoomLevelForAltitude(camera.altitude, 0, camera.centerCoordinate.latitude, map.bounds.size)
        #expect(abs(zoom - PinFraming.maxZoom) < 0.01)
        #expect(abs(camera.centerCoordinate.latitude - -42.9) < 1e-6)
    }

    @Test func showOnMapFitsEveryPinInsideTheMargins() {
        let model = AppModel(data: .none, tables: .empty)
        let coordinator = MapCoordinator(model: model)
        let map = map()
        let a = model.pins!.addPin(latitude: -42.88, longitude: 147.25, placedBy: .map)
        let b = model.pins!.addPin(latitude: -42.95, longitude: 147.40, placedBy: .map)
        model.showOnMap([a, b])
        coordinator.apply(pinsFit: model.pinsFit, to: map, delay: 0, animated: false)
        let margin = PinFraming.margin(framing: .zero, in: map.bounds.size)
        let inner = map.bounds.inset(by: margin).insetBy(dx: -1, dy: -1)
        for pin in [a, b] {
            let p = map.convert(CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon), toPointTo: map)
            #expect(inner.contains(p), "\(p) in \(inner)")
        }
        #expect(map.zoomLevel <= PinFraming.maxZoom + 0.01)
        // the same request twice moves nothing more
        map.setCenter(CLLocationCoordinate2D(latitude: -41, longitude: 146), zoomLevel: 8, animated: false)
        coordinator.apply(pinsFit: model.pinsFit, to: map, delay: 0, animated: false)
        #expect(abs(map.centerCoordinate.latitude - -41) < 1e-6)
    }

    @Test func aPickedPinFromFarOutComesInToItsZoom() {
        let model = AppModel(data: .none, tables: .empty)
        let coordinator = MapCoordinator(model: model)
        let map = map()
        let pin = model.pins!.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        model.showPin(pin.id)
        coordinator.apply(pinsFit: model.pinsFit, to: map, delay: 0, animated: false)
        #expect(abs(map.zoomLevel - PinFraming.pinZoom) < 0.01)
        #expect(abs(map.centerCoordinate.latitude - -42.9) < 1e-4)
        // already in view at a working zoom: the camera stays
        map.setCenter(CLLocationCoordinate2D(latitude: -42.9005, longitude: 147.3005), zoomLevel: 16.5, animated: false)
        model.showPin(pin.id)
        coordinator.apply(pinsFit: model.pinsFit, to: map, delay: 0, animated: false)
        #expect(abs(map.zoomLevel - 16.5) < 0.01 && abs(map.centerCoordinate.latitude - -42.9005) < 1e-6)
    }
}

/// Layers → Also show → Pins.
@MainActor
@Suite struct PinsTileTests {
    @Test func onByDefaultAndPersisted() throws {
        #expect(LayerState.default.pins)
        // a state stored before the tile existed: on
        let old = try JSONDecoder().decode(LayerState.self, from: Data(#"{"base":"topo","trees":true}"#.utf8))
        #expect(old.pins && old.trees)
        var off = LayerState.default
        off.pins = false
        let back = try JSONDecoder().decode(LayerState.self, from: JSONEncoder().encode(off))
        #expect(!back.pins)
        // the style doesn't change (pins are runtime layers: no reload)
        #expect(StyleBuilder.json(state: off, data: .none, tables: .empty) == StyleBuilder.json(state: .default, data: .none, tables: .empty))
    }

    @Test func offMeansNotDrawnAndNotTappableAndClosesAPinCard() throws {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.88, longitude: 147.33))
        let coordinator = MapCoordinator(model: model)
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             styleJSON: ##"{"version":8,"sources":{},"layers":[{"id":"bg","type":"background"}]}"##)
        coordinator.attach(to: map)
        coordinator.mapView(map, didFinishLoading: try #require(map.style))
        func drawn() -> Int { coordinator.pinMarks.features.count }
        coordinator.apply(pins: model.pins, selectedPin: nil, to: map)
        #expect(drawn() == 1)
        model.startMovingPin()
        model.layers.pins = false
        #expect(model.selection == nil && model.movingPin == nil)
        coordinator.apply(pins: model.pins, selectedPin: nil, to: map)
        #expect(drawn() == 0)
        // the layers stay (switching back needs no style work)
        #expect(map.style?.layer(withIdentifier: StyleBuilder.LayerID.pinsMark) != nil)
        model.layers.pins = true
        coordinator.apply(pins: model.pins, selectedPin: nil, to: map)
        #expect(drawn() == 1)
    }

    @Test func addingAPinTurnsTheTileBackOn() {
        let model = AppModel(data: .none, tables: .empty)
        model.layers.pins = false
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.88, longitude: 147.33))
        #expect(model.layers.pins && model.selection?.isPin == true)

        model.layers.pins = false
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        model.wallClock = { now }
        model.authorization = .authorizedWhenInUse
        model.systemLocation = {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3), altitude: 0,
                       horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: now)
        }
        model.pinCurrentLocation()
        #expect(model.layers.pins && model.pins!.pins.count == 2)
    }
}

/// The Pins screen from the model's side: opening, Show on map, a pin row,
/// deleting a project with Undo, Escape.
@MainActor
@Suite struct PinsScreenModelTests {
    @Test func aPinRowClosesTheScreenOpensTheCardAndAsksForTheCamera() {
        let model = AppModel(data: .none, tables: .empty)
        let pin = model.pins!.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        model.layers.pins = false
        model.present(.pins)
        #expect(model.modal?.presentation == .pins)
        #expect(model.escapeStep == .dismiss(.pins))
        model.showPin(pin.id)
        #expect(model.modal == nil && model.selection?.pinID == pin.id)
        #expect(model.pinsFit?.target == .pin(latitude: -42.9, longitude: 147.3))
        #expect(model.layers.pins)  // she asked to see it
    }

    @Test func showOnMapClosesTheScreenAndLeavesTheOtherLayersAlone() {
        var state = LayerState.default
        state.base = .aerial
        state.overlay = .geology
        let model = AppModel(data: .none, tables: .empty, layers: state)
        let a = model.pins!.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let b = model.pins!.addPin(latitude: -42.8, longitude: 147.1, placedBy: .map)
        model.present(.pins)
        model.showOnMap([a, b])
        #expect(model.modal == nil)
        #expect(model.pinsFit?.target == .box([147.1, -42.9, 147.3, -42.8]))
        #expect(model.layers == state)
        // nothing on the map to show: nothing happens
        let serial = model.pinsFit?.serial
        model.showOnMap([])
        #expect(model.pinsFit?.serial == serial)
    }

    @Test func deletingAProjectOffersUndoWhichBringsItBackWithItsPins() async {
        let clock = ManualClock()
        let model = AppModel(data: .none, tables: .empty, clock: clock.clock)
        let store = model.pins!
        let site = store.addProject(name: "Knocklofty", colour: .teal)
        let pin = store.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        model.selectPin(pin.id)
        model.deleteProject(site)
        #expect(store.projects.isEmpty && store.pins.isEmpty && model.selection == nil)
        #expect(model.pinUndo?.project == site.id && model.pinUndo?.pinCount == 1 && model.pinUndo?.title == "Knocklofty")
        model.undoPinDelete()
        #expect(model.pinUndo == nil)
        #expect(store.projects.map(\.id) == [site.id] && store.pins(in: site).map(\.id) == [pin.id])
        // and the banner goes by itself
        model.deleteProject(site)
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.pinUndoDuration)
        await settle { model.pinUndo == nil }
        #expect(model.pinUndo == nil && store.deletedProjects.map(\.id) == [site.id])
    }

    @Test func escapeClosesTheProjectEditorFromTheCardFirst() {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        model.pinProjectForm = true
        #expect(model.escapeStep == .closeProjectForm)
        model.escape()
        #expect(!model.pinProjectForm && model.selection?.isPin == true)
    }
}

/// `Features.pins` off: no way into the Pins screen at all.
@MainActor
@Suite struct PinsSwitchedOffEntryTests {
    @Test func everyEntryPointIsClosed() {
        let off = AppModel(shared: AppData(location: .none, tables: .empty, pinsEnabled: false))
        #expect(!PinsEntry.available(off))
        off.present(.pins)
        #expect(off.modal == nil)
        off.showPin(UUID())
        off.showOnMap([])
        #expect(off.pinsFit == nil)
        let on = AppModel(shared: AppData(location: .none, tables: .empty))
        #expect(PinsEntry.available(on))
        on.present(.pins)
        #expect(on.modal?.presentation == .pins)
    }
}

/// Review round 1 (2026-11-24): the editor, Delete now, the Undo banner,
/// purging, the layer on every path to a card, presenting Pins safely, the
/// Storage gauge.
@MainActor
@Suite struct PinsReviewTests {
    private typealias Fields = ProjectEditor.Fields

    @Test func editingAProjectThatWentAwayNeverCreatesADuplicate() {
        let s = freshStore()
        let site = s.addProject(name: "Knocklofty", colour: .teal)
        let mode = ProjectEditor.Mode.edit(site.id)
        #expect(ProjectEditor.commit(mode, fields: Fields(name: "Knocklofty North", colour: .gold, note: "n"), in: s) == .edited)
        #expect(site.name == "Knocklofty North" && site.colour == "gold" && site.note == "n")
        s.deleteProject(site)  // e.g. in another window
        #expect(ProjectEditor.project(mode, in: s) == nil)
        #expect(ProjectEditor.commit(mode, fields: Fields(name: "Again", colour: .teal, note: ""), in: s) == .gone)
        #expect(s.projects.isEmpty)
        #expect(ProjectEditor.commit(.new, fields: Fields(name: "  ", colour: .teal, note: ""), in: s) == .invalid)
        #expect(s.projects.isEmpty)
        if case .created = ProjectEditor.commit(.new, fields: Fields(name: "Bonnet Hill", colour: .violet, note: ""), in: s) {} else {
            Issue.record("a new project is created")
        }
        #expect(s.projects.map(\.name) == ["Bonnet Hill"])
    }

    @Test func archivingKeepsWhatWasTypedFirst() {
        let s = freshStore()
        let site = s.addProject(name: "Old", colour: .brown)
        let mode = ProjectEditor.Mode.edit(site.id)
        ProjectEditor.toggleArchived(mode, fields: Fields(name: "Old Midlands", colour: .olive, note: "1998 survey"), in: s)
        #expect(site.archivedAt != nil && site.name == "Old Midlands" && site.colour == "olive" && site.note == "1998 survey")
        // an emptied name isn't saved, the switch still happens
        ProjectEditor.toggleArchived(mode, fields: Fields(name: "", colour: .olive, note: ""), in: s)
        #expect(site.archivedAt == nil && site.name == "Old Midlands")
    }

    @Test func deleteNowWorksByIdAndItsWordsAreTakenWhenItOpens() {
        let model = AppModel(data: .none, tables: .empty)
        let s = model.pins!
        let site = s.addProject(name: "Gone", colour: .gold)
        s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.addPin(latitude: -42.8, longitude: 147.3, placedBy: .map)
        s.lastUsedProject = nil
        let lone = s.addPin(latitude: -42.7, longitude: 147.3, placedBy: .map)
        s.setTitle(lone, "Wrong spot")
        s.delete(lone)
        s.deleteProject(site)

        let one = PinsDeleteNow.project(site, in: s)
        #expect(one.title == "Delete “Gone” now?" && one.message == "Its 2 pins go with it. This can’t be undone.")
        let all = PinsDeleteNow.all(in: s)
        // names everything it removes, the project's pins included
        #expect(all.message == "1 project with its 2 pins and 1 pin deleted on its own. This can’t be undone.", "\(all.message)")
        #expect(all.button == "Delete all")
        let pin = PinsDeleteNow.pin(lone)
        // the title asks; the message says it once
        #expect(pin.message == "This can’t be undone." && pin.button == "Delete")
        model.deleteNow(pin)
        #expect(s.anyPin(lone.id) == nil)
        model.deleteNow(pin)  // a second time: nothing left, nothing happens
        // the words stay readable after the delete (they're plain strings)
        #expect(pin.title == "Delete “Wrong spot” now?")
        model.deleteNow(one)
        #expect(!s.hasDeleted)
    }

    @Test func theUndoBannerGoesWithWhatItWouldBringBack() {
        let model = AppModel(data: .none, tables: .empty)
        let s = model.pins!
        let site = s.addProject(name: "Knocklofty", colour: .teal)
        s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        model.deleteProject(site)
        #expect(model.pinUndo != nil)
        model.deleteNow(.project(site, in: s))
        #expect(model.pinUndo == nil)

        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        let id = model.selection!.pinID!
        model.deletePin(id)
        #expect(model.pinUndo?.pin == id)
        model.deleteNow(.all(in: s))
        #expect(model.pinUndo == nil)
    }

    @Test func purgingAlsoHappensLaterAndClearsAStaleBanner() {
        let clock = DateBox()
        let model = AppModel(shared: AppData(location: .none, tables: .empty,
                                             pins: PinStore.inMemory(defaults: UserDefaults(suiteName: "izzymap-purge-\(UUID().uuidString)")!,
                                                                     now: { clock.now })))
        let s = model.pins!
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        let id = model.selection!.pinID!
        model.deletePin(id)
        clock.advance(days: 31)
        model.purgePins()  // the scene came back to the foreground
        #expect(s.anyPin(id) == nil && !s.hasDeleted && model.pinUndo == nil)
    }

    @Test func undoShowsThePinsLayerForTheCardItOpens() {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        let id = model.selection!.pinID!
        model.deletePin(id)
        model.layers.pins = false
        model.undoPinDelete()
        #expect(model.selection?.pinID == id && model.layers.pins)
        // and any other way a pin's card opens
        model.layers.pins = false
        model.selectPin(id)
        #expect(model.layers.pins)
    }

    @Test func pinsFromTheLayersPopoverOpenOnceThePopoverHasGone() {
        let model = AppModel(data: .none, tables: .empty)
        model.layoutChanged(to: .card)
        model.present(.layers)
        model.present(.pins)
        #expect(model.modal == nil, "the popover goes first")
        model.layersDidDisappear()
        #expect(model.modal?.presentation == .pins && model.modal?.layout == .card)
        // nothing pending: the popover going away by itself opens nothing
        model.dismissModal()
        model.present(.layers)
        model.dismissModal()
        model.layersDidDisappear()
        #expect(model.modal == nil)
        // the phone's sheet layout swaps its sheet directly
        model.layoutChanged(to: .sheet)
        model.present(.layers)
        model.present(.pins)
        #expect(model.modal?.presentation == .pins)
    }

    @Test func pinsNeverOpenOverTheCardsProjectEditor() {
        let model = AppModel(data: .none, tables: .empty)
        model.dropPin(at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.3))
        model.pinProjectForm = true
        #expect(!model.canPresentPins)
        model.present(.pins)  // ⌘P (disabled meanwhile)
        #expect(model.modal == nil && model.escapeStep == .closeProjectForm)
        model.escape()
        #expect(model.canPresentPins)
    }

    @Test func pinsCountInTheStorageGauge() {
        let g = StorageGauge(parts: [.maps: 10, .pins: 2], capacity: nil, free: 100)
        #expect(g.izzyBytes == 12)
        #expect(g.segments.map(\.title) == ["Core maps", "Pins", "Free"])
        // pins have a segment (and a key entry) of their own, named as the
        // list's Pins section; the field guide and detailed areas share one
        let shared = StorageGauge(parts: [.extras: 3, .areas: 2, .pins: 1], capacity: nil, free: nil)
        #expect(shared.segments.map(\.title) == ["Field guide & areas", "Pins"] && shared.izzyBytes == 6)
        #expect(shared.segments.map(\.kind) == [.izzy(.extras), .izzy(.pins)])
        let two = StorageGauge(parts: [.extras: 3, .areas: 2], capacity: nil, free: nil)
        #expect(two.segments.map(\.title) == ["Field guide & areas"])
    }

    /// The bar is read literally: 10 MB of pins is a sliver beside 8.66 GB
    /// of extra maps, never the same width (P-18: a 16 pt floor made all
    /// four used segments ≈ 16 pt on a 154 GB phone).
    @Test func gaugeWidthsAreProportionalWithAThinFloor() {
        let mb: Int64 = 1_000_000
        let g = StorageGauge(parts: [.maps: 3_730 * mb, .moreMaps: 8_660 * mb, .plantID: 909 * mb, .extras: 8 * mb, .pins: 10 * mb],
                             capacity: 256_000 * mb, free: 138_000 * mb)
        let w = g.widths(in: 500, minimum: StorageGaugeView.minimumSegment)
        #expect(StorageGaugeView.minimumSegment <= 3)
        #expect(w.count == 6)
        // proportional where above the floor: extra maps ≈ 2.3 × core maps
        #expect(abs(w[1] / w[0] - 8_660.0 / 3_730.0) < 0.01)
        // the slivers: shown, but no wider than the floor
        #expect(w[3] == StorageGaugeView.minimumSegment && w[4] == StorageGaugeView.minimumSegment)
        #expect(w[1] > 5 * w[4])
        #expect(abs(w.reduce(0, +) - 500) < 0.001)
    }
}

/// The Pins screen's words (rows, the status line, Recently deleted).
@Suite struct PinsScreenTextTests {
    @Test func anUntitledRowSaysSoAndNeverShowsTheNoteAsItsTitle() {
        #expect(PinsScreenText.rowTitle("  Gate ") == ("Gate", false))
        #expect(PinsScreenText.rowTitle("") == ("Untitled pin", true))
        #expect(PinsScreenText.rowTitle(" \n ") == ("Untitled pin", true))
    }

    @Test func theStatusLineNamesTheDeviceOnceAndNeverSaysZeroPins() {
        #expect(PinsScreenText.sizeLine(pins: 25, photos: 32, deleted: 0, size: "10 MB") == "25 pins · 32 photos · 10 MB")
        #expect(PinsScreenText.sizeLine(pins: 1, photos: 0, deleted: 4, size: "248 KB") == "1 pin · 248 KB")
        #expect(PinsScreenText.sizeLine(pins: 0, photos: 0, deleted: 1, size: "3.2 MB")
            == "No pins on the map · 1 in Recently deleted · 3.2 MB")
        #expect(!PinsScreenText.sizeLine(pins: 3, photos: 1, deleted: 0, size: "1 MB").contains("on this"))
    }

    @Test func aDeletedRowNamesWhereItGoesBackFirstThenTheDaysLeft() {
        #expect(PinsScreenText.deletedStatus(place: "Knocklofty Reserve", photos: 3, daysLeft: 30)
            == "Knocklofty Reserve · 3 photos\n30 days left")
        #expect(PinsScreenText.deletedStatus(place: "Unfiled", photos: 0, daysLeft: 1) == "Unfiled\n1 day left")
    }
}
