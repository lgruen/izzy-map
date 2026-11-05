import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

/// The Storage screen's rules: row states from pack states, the gauge's
/// maths, the space preflight, sizes as written, the footprints, and the
/// DEBUG fake store that UI tests and screenshots drive.
@MainActor
struct StorageTests {
    // MARK: Row states

    @Test func packStatesMapToRows() {
        #expect(PackRowStatus.of(.installed, pack: .aerial, canFetch: true) == .onDevice)
        #expect(PackRowStatus.of(.notInstalled, pack: .aerial, canFetch: true) == .get)
        // a core pack that hasn't arrived is the system's job, not a Get
        #expect(PackRowStatus.of(.notInstalled, pack: .topo, canFetch: true) == .arriving)
        #expect(PackRowStatus.of(.downloading(0.4), pack: .tasmap, canFetch: true) == .downloading(0.4))
        #expect(PackRowStatus.of(.paused, pack: .tasmap, canFetch: true) == .paused(.system))
        #expect(PackRowStatus.of(.paused, pack: .tasmap, canFetch: true, online: false) == .paused(.offline))
        // a new version arriving for an installed pack is an update, not a download
        #expect(PackRowStatus.of(.installed, pack: .topo, canFetch: true, update: 0.4) == .updating(0.4))
        #expect(!PackRowStatus.updating(0.4).isBusy && PackRowStatus.updating(0.4).progress == 0.4)
        // not offered by the App Store: no Get, an honest line
        #expect(PackRowStatus.of(.unpublished, pack: .plantid, canFetch: true) == .unpublished)
        #expect(!PackRowStatus.unpublished.offersGet)
        #expect(PackRowStatus.of(.failed("x"), pack: .tasmap, canFetch: true) == .failed)
        // a developer folder can't fetch anything
        #expect(PackRowStatus.of(.notInstalled, pack: .aerial, canFetch: false) == .unavailable)
        #expect(PackRowStatus.of(.failed("x"), pack: .aerial, canFetch: false) == .unavailable)
        // before the store has looked, nothing is "missing"
        #expect(PackRowStatus.of(.notInstalled, pack: .aerial, canFetch: true, resolved: false) == .checking)
        #expect(PackRowStatus.of(.installed, pack: .aerial, canFetch: true, resolved: false) == .onDevice)
    }

    @Test func rowTextSaysWhatTheRowShows() {
        let gb = 1_929_244_001
        #expect(PackRowStatus.onDevice.text(bytes: gb, device: "iPhone") == "On this iPhone · 1.93\u{00A0}GB")
        #expect(PackRowStatus.get.text(bytes: gb, device: "iPhone") == "1.93\u{00A0}GB")
        // the line says what is happening, in words; figures never break inside
        #expect(PackRowStatus.downloading(0.62).text(bytes: gb, device: "iPhone")
            == "Downloading\u{00A0}62\u{00A0}% · 1.20\u{00A0}of\u{00A0}1.93\u{00A0}GB")
        #expect(PackRowStatus.downloading(nil).text(bytes: gb, device: "iPad").hasPrefix("Waiting"))
        #expect(PackRowStatus.updating(0.4).text(bytes: gb, device: "iPhone") == "On this iPhone · updating\u{00A0}40\u{00A0}%")
        #expect(PackRowStatus.unpublished.text(bytes: gb, device: "iPhone").hasPrefix("Not published yet"))
        // the pause says why, never "continues by itself" beside a button
        #expect(PackRowStatus.paused(.offline).text(bytes: gb, device: "iPhone").hasPrefix("Waiting for a connection"))
        #expect(PackRowStatus.paused(.system).text(bytes: gb, device: "iPhone").hasPrefix("Paused by iOS"))
        // a progress bar ONLY while bytes arrive — never a size, never "done"
        #expect(PackRowStatus.downloading(0.5).progress == 0.5)
        #expect(PackRowStatus.downloading(nil).progress == nil)
        #expect(PackRowStatus.onDevice.progress == nil && PackRowStatus.get.progress == nil)
        #expect(PackRowStatus.paused(.system).progress == nil && PackRowStatus.failed.progress == nil)
        // the state glyph: the app's icon language, in the line
        #expect(PackRowStatus.onDevice.symbol == StateSymbol.onDevice && PackRowStatus.failed.symbol == StateSymbol.failed)
        #expect(PackRowStatus.get.symbol == nil && PackRowStatus.downloading(0.3).symbol == nil)
        #expect(PackRowStatus.get.offersGet && PackRowStatus.failed.offersGet && PackRowStatus.arriving.offersGet)
        #expect(!PackRowStatus.onDevice.offersGet && PackRowStatus.paused(.system).isBusy)
    }

    @Test func sizesAreWrittenLikeTheSystemDoes() {
        #expect(StorageText.size(398_147_443) == "398\u{00A0}MB")
        #expect(StorageText.size(3_242_875_247) == "3.24\u{00A0}GB")
        #expect(StorageText.size(41_400_000_000) == "41\u{00A0}GB")
        #expect(StorageText.size(128_000_000_000) == "128\u{00A0}GB")
        #expect(StorageText.size(-5) == "0.0\u{00A0}MB")
        #expect(StorageText.about(1_929_244_001) == "2.0\u{00A0}GB")
        #expect(StorageText.fraction(6_600_000, of: 30_447_114) == "6.6\u{00A0}of\u{00A0}30\u{00A0}MB")
        #expect(StorageText.fraction(120_000_000, of: 152_000_000) == "120\u{00A0}of\u{00A0}152\u{00A0}MB")
        #expect(StorageText.fraction(600_000, of: 6_000_000) == "0.6\u{00A0}of\u{00A0}6.0\u{00A0}MB")
        #expect(StorageText.fraction(1_200_000_000, of: 1_929_244_001) == "1.20\u{00A0}of\u{00A0}1.93\u{00A0}GB")
        #expect(StorageText.about(282_812_458) == "283\u{00A0}MB")
        #expect(StorageText.percent(0.999) == "99\u{00A0}%" && StorageText.percent(1.2) == "100\u{00A0}%")
    }

    @Test func everyPackHasASizeTitleAndSection() {
        for pack in Pack.allCases {
            #expect((PackSizes.nominal[pack] ?? 0) > 0, "\(pack)")
            #expect(!pack.storageTitle.isEmpty)
        }
        #expect(Pack.vector.storageSection == .maps && Pack.aerial.storageSection == .moreMaps)
        #expect(Season.all.allSatisfy { $0.archive.pack.storageSection == .seasons && $0.archive.pack.season == $0 })
        #expect(Pack.season2024.storageTitle == "2023–24 photos")
        // only the season still being flown carries the note
        #expect(Pack.allCases.filter { $0.storageNote != nil } == [.season2026])
    }

    /// Every pack has exactly one row on the screen (plant ID was missing
    /// until 2026-11-04: it opened Storage and wasn't there).
    @Test func everyPackIsListedOnce() {
        let listed = Pack.StorageSection.all.flatMap(\.packs)
        #expect(listed.count == Pack.allCases.count)
        #expect(Set(listed) == Set(Pack.allCases))
        #expect(Pack.StorageSection.maps.packs.contains(.plantid))
        #expect(Pack.StorageSection.all.allSatisfy { section in section.packs.allSatisfy { $0.storageSection == section } })
        // seasons newest first
        #expect(Pack.StorageSection.seasons.packs.first == .season2026)
        #expect(StorageTarget.pack(StorageTarget.row(.plantid)) == .plantid && StorageTarget.pack(StorageTarget.areas) == nil)
    }

    // MARK: Gauge

    /// Four categories, four fills: plant ID its own; field guide and
    /// detailed areas share one segment, named for what's in it.
    @Test func gaugeCategoriesFollowThePacks() {
        #expect(Pack.vector.gaugeCategory == .maps && Pack.relief.gaugeCategory == .maps)
        #expect(Pack.plantid.gaugeCategory == .plantID)
        #expect(Pack.tasmap.gaugeCategory == .moreMaps && Pack.season2021.gaugeCategory == .moreMaps)
        let both = StorageGauge(parts: [.maps: 10, .plantID: 5, .extras: 3, .areas: 2], capacity: nil, free: 100)
        #expect(both.segments.map(\.kind) == [.izzy(.maps), .izzy(.plantID), .izzy(.extras), .free])
        #expect(both.segments.map(\.title) == ["Core maps", "Plant identification", "Field guide & areas", "Free"])
        #expect(both.segments[2].bytes == 5)
        let areasOnly = StorageGauge(parts: [.areas: 2], capacity: nil, free: nil)
        #expect(areasOnly.segments.map(\.title) == ["Detailed areas"])
    }

    @Test func gaugeIsIzzyMapThenFree() {
        let gauge = StorageGauge(parts: [.maps: 3_000, .moreMaps: 2_000, .extras: 0], capacity: 100_000, free: 15_000)
        // empty categories leave no segment; everything else on the device stays out
        #expect(gauge.segments.map(\.kind) == [.izzy(.maps), .izzy(.moreMaps), .free])
        #expect(gauge.izzyBytes == 5_000)
        #expect(gauge.totalBytes == 20_000)
        #expect(gauge.izzyShare == 0.25)
        #expect(gauge.widths(in: 200, minimum: 0) == [30, 20, 150])
        #expect(gauge.capacityBytes == 100_000)
    }

    @Test func gaugeCopesWithMissingNumbers() {
        // free space unknown: the bar is IzzyMap alone
        let noFree = StorageGauge(parts: [.maps: 1_000, .extras: 1_000], capacity: nil, free: nil)
        #expect(noFree.segments.map(\.kind) == [.izzy(.maps), .izzy(.extras)])
        #expect(noFree.widths(in: 100, minimum: 0) == [50, 50])
        #expect(noFree.summary() == "IzzyMap 0.0\u{00A0}MB")
        // nothing at all: no segments, no widths, no division by zero
        let nothing = StorageGauge(parts: [:], capacity: nil, free: nil)
        #expect(nothing.segments.isEmpty && nothing.widths(in: 100).isEmpty && nothing.izzyShare == 0)
        // negative inputs are clamped
        let odd = StorageGauge(parts: [.maps: -5], capacity: 10, free: -3)
        #expect(odd.segments.isEmpty && odd.izzyBytes == 0)
    }

    @Test func tinySegmentsStayVisible() {
        // 30 MB of chapters on a 128 GB phone: still a mark on the bar
        let gauge = StorageGauge(parts: [.maps: 4_000_000_000, .extras: 30_000_000], capacity: 128_000_000_000,
                                 free: 40_000_000_000)
        let w = gauge.widths(in: 300, minimum: 3)
        #expect(w.count == 3)
        #expect(w[1] == 3)
        #expect(w.allSatisfy { $0 >= 3 })
        // the widest pays for it: the total stays the bar's width
        #expect(abs(w.reduce(0, +) - 300) < 0.001)
    }

    // MARK: Preflight

    @Test func preflightKeepsAMargin() {
        let gb: Int64 = 1_000_000_000
        #expect(SpacePreflight.shortfall(need: 2 * gb, free: 10 * gb) == nil)
        #expect(SpacePreflight.shortfall(need: 2 * gb, free: 2 * gb) == 2 * gb)
        #expect(SpacePreflight.shortfall(need: 2 * gb, free: 2 * gb + SpacePreflight.margin) == nil)
        // unknown free space: the system decides
        #expect(SpacePreflight.shortfall(need: 2 * gb, free: nil) == nil)
        #expect(SpacePreflight.shortfall(need: 0, free: 0) == nil)
        // a pack is unpacked beside its download: both count
        let tasmap = Int64(PackSizes.nominal[.tasmap]!)
        #expect(SpacePreflight.need([.tasmap], downloadSizes: [:]) == 2 * tasmap)
        #expect(SpacePreflight.need([.tasmap], downloadSizes: [.tasmap: 3_000_000_000]) == tasmap + 3_000_000_000)
        #expect(SpacePreflight.need([], downloadSizes: [:]) == 0)
    }

    @Test func spaceRequestCountsDownloadAndUnpacked() {
        // 3.24 GB fits 4 GB free on its own, but not beside its download
        let store = PackStore(fake: FakePacks(spec: "vector"))
        #expect(SpacePreflight.shortfall(need: SpacePreflight.need([.tasmap], downloadSizes: store.downloadSizes),
                                         free: 4_000_000_000) != nil)
    }

    // MARK: Footprints

    @Test func bundledFootprintsDecodeOnTheirGrid() throws {
        let table = try #require(BundledFootprints.load(BundledData(root: Self.dataRoot)))
        #expect(table.zoom == 11 && table.cols * table.rows > 500)
        for pack in Pack.allCases where pack.storageSection != .maps {
            let footprint = try #require(table.footprint(pack), "\(pack)")
            #expect(footprint.count > 50, "\(pack)")
        }
        // the patchwork seasons cover far less than the statewide mosaic
        let aerial = try #require(table.footprint(.aerial)).count
        #expect(Season.all.allSatisfy { (table.footprint($0.archive.pack)?.count ?? .max) < aerial / 2 })
        // the grid's cells land on Tasmania (Hobart's z11 tile: x 1862, y 1294)
        let g = table.grid
        let hobart = g.bounds(col: 1862 - g.x0, row: 1294 - g.y0)
        #expect(hobart.west < 147.33 && 147.33 < hobart.east && hobart.south < -42.88 && -42.88 < hobart.north)
    }

    @Test func footprintUnionIsEveryCell() {
        let grid = Footprint.Grid(zoom: 11, x0: 0, y0: 0, cols: 4, rows: 2)
        let a = Footprint(grid: grid, bits: Data([0b0000_0001])), b = Footprint(grid: grid, bits: Data([0b1000_0000]))
        let u = try? #require(Footprint.union([a, b]))
        #expect(u?.count == 2 && u?.contains(col: 0, row: 0) == true && u?.contains(col: 3, row: 1) == true)
        #expect(Footprint.union([]) == nil)
    }

    @Test func footprintsReadFromAnArchive() throws {
        // a two-tile archive: exactly those two cells
        let grid = Footprint.Grid(zoom: 11, x0: 1840, y0: 1300, cols: 4, rows: 3)
        let url = FileManager.default.temporaryDirectory.appending(path: "footprint-\(UUID().uuidString).pmtiles")
        let writer = try PMTilesWriter(destination: url, tileType: .png)
        try writer.add(z: 11, x: 1841, y: 1300, data: Data([1]))
        try writer.add(z: 11, x: 1843, y: 1302, data: Data([2]))
        try writer.finish(name: "test", attribution: "test")
        defer { try? FileManager.default.removeItem(at: url) }
        let footprint = try #require(Footprint.read(url, grid: grid))
        #expect(footprint.count == 2)
        #expect(footprint.contains(col: 1, row: 0) && footprint.contains(col: 3, row: 2))
        #expect(!footprint.contains(col: 0, row: 0) && !footprint.contains(col: 9, row: 9))
    }

    // MARK: The fake store (UI tests, screenshots)

    @Test func fakeSpecSetsStates() {
        let fake = FakePacks(spec: "vector,topo=downloading:0.3,tasmap=failed,season-2026=paused,nonsense")
        #expect(fake.states[.vector] == .installed)
        #expect(fake.states[.topo] == .downloading(0.3))
        #expect(fake.states[.tasmap] == .failed("The download didn't finish."))
        #expect(fake.states[.season2026] == .paused)
        #expect(fake.states[.aerial] == .notInstalled)
        let mixed = FakePacks(spec: "mixed")
        #expect(mixed.states[.aerial] == .installed && mixed.states[.season2025] == .downloading(0.62))
        #expect(mixed.states[.plantid] == .downloading(0.83))
        #expect(FakePacks(spec: "plantid=unpublished").states[.plantid] == .unpublished)
        // an update keeps the pack installed
        #expect(mixed.states[.topo] == .installed && mixed.updates[.topo] == 0.4)
    }

    @Test func fakeStoreFetchesAndRemoves() async throws {
        let store = PackStore(fake: FakePacks(spec: "vector", seconds: 0.2))
        let model = StorageModel(packs: store, trees: nil)
        #expect(store.canFetch)
        #expect(model.status(.aerial) == .get)
        #expect(model.status(.vector) == .onDevice)
        store.fetch(.aerial)
        #expect(model.status(.aerial).isBusy)
        for _ in 0 ..< 100 where !store.state(.aerial).isInstalled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.status(.aerial) == .onDevice)
        model.refreshPacks()
        // no directory: sizes are the nominal ones, and they reach the gauge
        #expect(model.bytes(.aerial) == PackSizes.nominal[.aerial])
        #expect(model.gauge.segments.first { $0.kind == .izzy(.moreMaps) }?.bytes == Int64(PackSizes.nominal[.aerial]!))
        #expect(!model.coreAllHere)
        await store.remove(.aerial)
        #expect(model.status(.aerial) == .get)
        // core packs aren't removable
        await store.remove(.vector)
        #expect(model.status(.vector) == .onDevice)
    }

    /// The core section folds into one row only while all four are simply
    /// here; plant ID's bytes are its own gauge segment.
    @Test func coreFoldsOnlyWhenSettled() {
        let settled = StorageModel(packs: PackStore(fake: FakePacks(spec: "vector,topo,relief,plantid,refphotos")), trees: nil)
        settled.refreshPacks()
        #expect(settled.coreAllHere)
        #expect(settled.coreBytes == [Pack.vector, .topo, .relief, .plantid, .refphotos].reduce(0) { $0 + PackSizes.nominal[$1]! })
        #expect(settled.gauge.segments.first { $0.kind == .izzy(.plantID) }?.bytes
            == Int64(PackSizes.nominal[.plantid]! + PackSizes.nominal[.refphotos]!))
        let mixed = StorageModel(packs: PackStore(fake: FakePacks(spec: "mixed")), trees: nil)
        #expect(!mixed.coreAllHere)
        #expect(mixed.status(.plantid) == .downloading(0.83))
        // an update unfolds it too
        #expect(!StorageModel(packs: PackStore(fake: FakePacks(spec: "vector,topo=updating:0.2,relief,plantid,refphotos")), trees: nil).coreAllHere)
    }

    @Test func stopDuringADownloadStaysStopped() async throws {
        let store = PackStore(fake: FakePacks(spec: "vector", seconds: 0.4))
        store.fetch(.tasmap)
        try await Task.sleep(for: .milliseconds(100))
        await store.remove(.tasmap)
        #expect(store.state(.tasmap) == .notInstalled)
        // the stopped download's remaining steps don't bring it back
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.state(.tasmap) == .notInstalled)
    }

    /// The pack in flight, paused by the system: Resume moves the row at
    /// once (the old store set "Downloading" too) and it then arrives.
    @Test func resumeCarriesOnAPausedDownload() async throws {
        let system = FakePackSystem(installed: [.vector], seconds: 0.05)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: UserDefaults(suiteName: "resume-\(UUID().uuidString)")!,
                                            tuning: PackQueueTests.tuning)
        defer { store.shutdown() }
        store.fetch(.season2026)
        for _ in 0 ..< 100 where system.inFlight == 0 { try await Task.sleep(for: .milliseconds(10)) }
        system.pause(.season2026)
        for _ in 0 ..< 100 where store.state(.season2026) != .paused { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.current == .season2026)
        #expect(StorageModel(packs: store, trees: nil).status(.season2026).isPaused)
        store.resume(.season2026)
        #expect(store.state(.season2026) != .paused)
        system.finish(.season2026)
        for _ in 0 ..< 100 where !store.state(.season2026).isInstalled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.state(.season2026) == .installed)
    }

    @Test func fakeStoreWithADirectoryRestylesTheMap() async throws {
        // the archives come from the folder, so the location (what the style
        // reads) follows a fake install, and the packs-changed hook fires
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for archive in [Archive.tasveg, .geology, .pre1750, .season2021] {
            try Data([0]).write(to: dir.appending(path: archive.fileName))
        }
        let store = PackStore(fake: FakePacks(spec: "vector", directory: dir, seconds: 0.1))
        #expect(store.location.url(for: .tasveg) != nil)
        #expect(store.location.url(for: .season2021) == nil)
        var fired = 0
        let token = store.observe { fired += 1 }
        store.fetch(.season2021)
        for _ in 0 ..< 100 where !store.state(.season2021).isInstalled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.location.url(for: .season2021) != nil)
        #expect(fired == 1)
        await store.remove(.season2021)
        #expect(store.location.url(for: .season2021) == nil)
        #expect(fired == 2)
        _ = token
    }

    private static let dataRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "IzzyMap/Resources/Data", directoryHint: .isDirectory)
}
