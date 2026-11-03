import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IzzyKit

struct AreaPlanTests {
    /// ~2.5 × 2.2 km over Hobart's CBD and the Domain.
    static let hobart = AreaBox(west: 147.30, south: -42.895, east: 147.33, north: -42.875)
    static let hobartWide = AreaBox(west: 147.28, south: -42.92, east: 147.34, north: -42.86)
    /// ~25 × 33 km in the south-west.
    static let big = AreaBox(west: 146.0, south: -43.0, east: 146.3, north: -42.7)

    /// Per-zoom counts from the web app's `tilesAt` (git 04ea5d9 areas.ts,
    /// run in node on these boxes, 2026-11-03).
    @Test(arguments: [
        (hobart, [4, 9, 16, 36, 132, 460]),
        (hobartWide, [6, 16, 56, 180, 660, 2640]),
        (big, [80, 285, 1064, 4200, 16650, 65780]),
    ])
    func pyramidCountsMatchTheWebApp(box: AreaBox, counts: [Int]) {
        #expect((13 ... 18).map { AreaPlan.count(box, zoom: $0) } == counts)
        for (z, n) in zip(13 ... 18, counts) { #expect(AreaPlan.tiles(box, zoom: z).count == n) }
    }

    @Test func layersStopAtTheirServicesDeepestLevel() {
        #expect(AreaPlan.zooms(.aerial, detail: .finest) == 13 ... 18)
        #expect(AreaPlan.zooms(.tasmap, detail: .finest) == 13 ... 16)
        #expect(AreaPlan.zooms(.topo, detail: .good) == 13 ... 16)
        #expect(AreaPlan.zooms(.season(2024), detail: .fine) == 13 ... 17)
    }

    @Test func estimatesUseTheMeasuredMeanTileSizes() {
        let e = AreaPlan.estimate(Self.hobart, layer: .aerial, detail: .fine)
        #expect(e.tiles == 4 + 9 + 16 + 36 + 132)
        #expect(e.bytes == Int64(e.tiles) * 18_000)
        #expect(e.exact)
        let topo = AreaPlan.estimate(Self.hobart, layer: .topo, detail: .finest)
        #expect(topo.bytes == Int64(topo.tiles) * 12_000)
        let tasmap = AreaPlan.estimate(Self.hobart, layer: .tasmap, detail: .finest)
        #expect(tasmap.tiles == 4 + 9 + 16 + 36)
        // a season without known coverage is an upper bound
        #expect(!AreaPlan.estimate(Self.hobart, layer: .season(2021), detail: .fine).exact)
    }

    @Test func theCapIsSixtyThousandTilesPerLayer() {
        // the south-west box: 22,279 tiles at Fine fits, 88,059 at Finest doesn't
        #expect(!AreaPlan.estimate(Self.big, layer: .aerial, detail: .fine).overCap)
        #expect(AreaPlan.estimate(Self.big, layer: .aerial, detail: .finest).overCap)
        #expect(AreaPlan.fitsFraming(Self.big))
        let huge = AreaBox(west: 145.5, south: -43.2, east: 146.5, north: -42.4)
        #expect(!AreaPlan.fitsFraming(huge))
        #expect(AreaPlan.framingFill(huge) > 1)
        #expect(AreaPlan.framingFill(Self.hobart) < 0.01)
    }

    @Test func spaceNeedsTheLargestLayerTwiceAndAMargin() {
        let a = AreaPlan.estimate(Self.hobart, layer: .aerial, detail: .fine)
        let t = AreaPlan.estimate(Self.hobart, layer: .topo, detail: .fine)
        #expect(AreaPlan.spaceNeeded([a, t]) == a.bytes + t.bytes + a.bytes + AreaPlan.spaceMargin)
    }

    /// About 30 s of waiting in all before a tile stops its layer.
    @Test func retriesBackOffExponentiallyForAboutThirtySeconds() {
        let delays = AreaPlan.retryDelays(base: .milliseconds(500))
        #expect(delays.count == AreaPlan.attempts - 1)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
        let total = delays.reduce(Duration.zero, +)
        #expect(total >= .seconds(28) && total <= .seconds(35))
        #expect(AreaPlan.retryDelays(base: .zero).allSatisfy { $0 == .zero })
    }

    /// Over the cap, a layer keeps the deepest level that fits (never
    /// shallower than the packs' z15); nil only when z13–15 alone don't.
    @Test func theDepthThatFitsTheCap() {
        let counts = [13: 4, 14: 9, 15: 16, 16: 36, 17: 132]
        #expect(AreaPlan.depth(requested: 17, cap: 1000) { counts[$0]! } == 17)
        #expect(AreaPlan.depth(requested: 17, cap: 100) { counts[$0]! } == 16)
        #expect(AreaPlan.depth(requested: 17, cap: 30) { counts[$0]! } == 15)
        #expect(AreaPlan.depth(requested: 17, cap: 20) { counts[$0]! } == nil)
        let real = AreaPlan.depth(requested: 18) { AreaPlan.count(Self.big, zoom: $0) }
        #expect(real == 17)   // the south-west box at Finest stops at Fine
    }

    /// Resume needs room for what's left, not the whole layer again: the
    /// answers so far (absents, sea) stand for the rest.
    @Test func whatIsLeftOfAPartlyFetchedLayer() {
        let e = AreaPlan.estimate(Self.hobart, layer: .aerial, detail: .fine)
        // 197 planned, 100 answered, 50 of them images of 20 kB
        let r = AreaPlan.remaining(estimate: e, planned: 197, done: 100, stored: 50, bytes: 1_000_000)
        #expect(r.estimate.tiles == 97)
        #expect(r.estimate.bytes == Int64((97.0 * 0.5 * 20_000).rounded(.up)))
        #expect(r.finalBytes == 1_000_000 + r.estimate.bytes)
        // not started: the estimate itself
        #expect(AreaPlan.remaining(estimate: e, planned: 0, done: 0, stored: 0, bytes: 0).estimate == e)
        // done: nothing more
        #expect(AreaPlan.remaining(estimate: e, planned: 197, done: 197, stored: 197, bytes: 4_000_000).estimate.bytes == 0)
        let need = AreaPlan.spaceNeeded(remaining: [r])
        #expect(need == r.estimate.bytes + r.finalBytes + AreaPlan.spaceMargin)
    }

    /// The size range: ×1.6 until finished areas measured the real mean,
    /// then narrower around it.
    @Test func sizeRangesNarrowWithCalibration() {
        let nominal: Int64 = 1_000_000
        var c = AreaCalibration()
        #expect(c.range(nominal: nominal, nominalMean: 18_000) == 1_000_000 ... 1_600_000)
        c.add(tiles: 50, bytes: 1_500_000)
        #expect(!c.isCalibrated)   // too few tiles yet
        c.add(tiles: 150, bytes: 4_500_000)   // 200 tiles of 30 kB
        #expect(c.isCalibrated && c.layers == 2)
        let r = c.range(nominal: nominal, nominalMean: 18_000)
        let centre = 1_000_000.0 * 30_000 / 18_000
        #expect(r.contains(Int64(centre)))
        #expect(Double(r.upperBound - r.lowerBound) / centre < 0.65)
        for _ in 0 ..< 20 { c.add(tiles: 100, bytes: 3_000_000) }
        let tight = c.range(nominal: nominal, nominalMean: 18_000)
        #expect(Double(tight.upperBound - tight.lowerBound) / centre < 0.31)
        #expect(AreaLayer.season(2021).calibrationKey == AreaLayer.season(2024).calibrationKey)
    }

    @Test func seasonsGoDeeperOnlyUnderFlownTiles() {
        let box = Self.hobartWide
        let z15 = AreaPlan.tiles(box, zoom: 15)
        let flown = Set(z15.prefix(10))
        let tiles = AreaPlan.candidates(box, layer: .season(2024), detail: .finest, flown: { flown.contains($0) })
        // every z ≤ 15 tile is asked for; deeper ones only under the flown ten
        #expect(tiles.filter { $0.z <= 15 }.count == 6 + 16 + 56)
        #expect(tiles.filter { $0.z > 15 }.allSatisfy { flown.contains(AreaPlan.packParent($0)) })
        #expect(tiles.filter { $0.z > 15 }.count > 0)
        // shallowest level first: the z15 coverage is known before its children
        #expect(tiles.map(\.z) == tiles.map(\.z).sorted())
        let e = AreaPlan.estimate(box, layer: .season(2024), detail: .finest, flownParents: flown)
        #expect(e.tiles == tiles.count)
        #expect(e.exact)
        // the pyramid without coverage: every tile
        #expect(AreaPlan.candidates(box, layer: .aerial, detail: .finest).count
            == AreaPlan.count(box, zooms: 13 ... 18))
    }

    @Test func listURLsPutTheRowBeforeTheColumn() {
        let url = AreaLayer.season(2024).tileURL(TileID(z: 17, x: 118_100, y: 95_600))
        #expect(url.absoluteString
            == "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/AerialPhoto2024/MapServer/tile/17/95600/118100")
        #expect(AreaLayer.tasmap.service == "TasmapRaster")
    }

    @Test func layerKeysRoundTrip() throws {
        for layer in [AreaLayer.aerial, .season(2020), .season(2026), .tasmap, .topo] {
            #expect(AreaLayer(rawValue: layer.rawValue) == layer)
            let data = try JSONEncoder().encode([layer])
            #expect(try JSONDecoder().decode([AreaLayer].self, from: data) == [layer])
        }
        #expect(AreaLayer(rawValue: "relief") == nil)
        #expect(AreaLayer(rawValue: "season-x") == nil)
        // paint order: topo, Tasmap, aerial, seasons oldest first
        #expect([AreaLayer.season(2026), .aerial, .topo, .season(2021), .tasmap].sorted()
            == [.topo, .tasmap, .aerial, .season(2021), .season(2026)])
    }

    @Test func detailLevelsAreTheProductsMetres() {
        // at Hobart's latitude: 1.7 / 0.9 / 0.4 m
        #expect(abs(AreaDetail.good.metresPerPixel(latitude: -42.9) - 1.75) < 0.05)
        #expect(abs(AreaDetail.fine.metresPerPixel(latitude: -42.9) - 0.87) < 0.03)
        #expect(abs(AreaDetail.finest.metresPerPixel(latitude: -42.9) - 0.44) < 0.02)
    }

    @Test func boxSizeInKilometres() {
        let (w, h) = Self.hobart.sizeMetres
        #expect(abs(w - 2_450) < 50)
        #expect(abs(h - 2_226) < 50)
    }

    // MARK: Real season pack

    static let seasonPack = URL(filePath: "/Users/leo/izzy-map/data/aerial_2021.pmtiles")

    /// Season pruning against a real pack: the deeper levels only under the
    /// z15 tiles the pack holds. Skipped where the developer's data isn't.
    @Test(.enabled(if: FileManager.default.isReadableFile(atPath: seasonPack.path(percentEncoded: false))))
    func seasonPruningAgainstARealPack() throws {
        let reader = try PMTilesReader(url: Self.seasonPack)
        let box = Self.big
        let z15 = AreaPlan.tiles(box, zoom: 15)
        let flown = Set(try z15.filter { try reader.tileExists(z: $0.z, x: $0.x, y: $0.y) })
        let candidates = AreaPlan.candidates(box, layer: .season(2021), detail: .good, flown: { flown.contains($0) })
        let full = AreaPlan.count(box, zooms: 13 ... 16)
        #expect(candidates.count <= full)
        #expect(candidates.filter { $0.z == 16 }.count <= 4 * flown.count)
        #expect(candidates.filter { $0.z == 16 }.allSatisfy { flown.contains(AreaPlan.packParent($0)) })
        let e = AreaPlan.estimate(box, layer: .season(2021), detail: .good, flownParents: flown)
        #expect(e.tiles == candidates.count)
        // a patchwork: the 2020–21 season covers part of this box at most
        #expect(flown.count < z15.count)
    }
}

struct AreaRegistryTests {
    static func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "areas-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripsAndNamesAreasInTurn() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "areas.json")
        var registry = try AreaRegistry.load(from: url)
        #expect(registry.areas.isEmpty)
        #expect(registry.defaultName() == "Area 1")
        var a = AreaRecord(name: registry.defaultName(), box: AreaPlanTests.hobart, detail: .fine,
                           layers: [.season(2024), .aerial, .topo])
        #expect(a.layers.map(\.layer) == [.topo, .aerial, .season(2024)])
        a[.aerial]?.done = 12
        a[.aerial]?.complete = true
        registry.areas.append(a)
        #expect(registry.defaultName() == "Area 2")
        try registry.save(to: url)
        let back = try AreaRegistry.load(from: url)
        #expect(back.areas.count == 1)
        #expect(back.areas[0].id == a.id)
        #expect(back.areas[0][.aerial]?.done == 12)
        #expect(back.areas[0][.aerial]?.complete == true)
        #expect(!back.areas[0].isComplete)
        #expect(abs(back.areas[0].created.timeIntervalSince(a.created)) < 1)
    }

    /// Fields added after version 1 shipped (`cappedAt`, `calibration`) are
    /// optional: an older file still reads.
    @Test func olderRegistriesStillRead() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "areas.json")
        let old = #"{"version":1,"areas":[{"id":"0000abcd","name":"A","box":{"west":147.3,"south":-42.9,"east":147.33,"north":-42.88},"detail":17,"created":"2026-11-03T10:00:00Z","layers":[{"layer":"aerial","complete":true,"planned":10,"done":10,"stored":10,"bytes":1000}]}]}"#
        try Data(old.utf8).write(to: url)
        var registry = try AreaRegistry.load(from: url)
        #expect(registry.areas.first?[.aerial]?.cappedAt == nil)
        #expect(registry.calibration == nil)
        registry.areas[0][.aerial]?.cappedAt = 15
        registry.calibration = ["aerial": AreaCalibration(layers: 1, tiles: 200, bytes: 5_000_000)]
        try registry.save(to: url)
        let back = try AreaRegistry.load(from: url)
        #expect(back.areas[0][.aerial]?.cappedAt == 15)
        #expect(back.areas[0][.aerial]?.maxZoom(detail: .fine) == 15)
        #expect(back.calibration?["aerial"]?.tiles == 200)
    }

    @Test func namesAreTrimmedToFortyCharacters() {
        #expect(AreaRecord.cleanName("  Mount\nField  ") == "Mount Field")
        #expect(AreaRecord.cleanName(String(repeating: "x", count: 60)).count == 40)
    }

    @Test func anotherVersionIsNotReadAsEmpty() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "areas.json")
        try Data(#"{"version": 2, "areas": []}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try AreaRegistry.load(from: url) }
    }

    @Test func absentLogSurvivesATornRecord() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "aerial.absent")
        let log = try TileIDLog(url: url)
        try log.append(TileID(z: 17, x: 1, y: 2))
        try log.append(TileID(z: 17, x: 1, y: 2))
        try log.append(TileID(z: 16, x: 3, y: 4))
        log.close()
        // a write torn mid-record
        let h = try FileHandle(forWritingTo: url)
        _ = try h.seekToEnd()
        try h.write(contentsOf: Data([1, 2, 3]))
        try h.close()
        let again = try TileIDLog(url: url)
        #expect(again.count == 2)
        #expect(again.contains(TileID(z: 16, x: 3, y: 4)))
        try again.append(TileID(z: 18, x: 5, y: 6))
        again.close()
        #expect(try TileIDLog(url: url).count == 3)
        #expect(try Data(contentsOf: url).count == 24)
    }

    // MARK: Tile bodies

    static func png(alpha: UInt8, size: Int = 256) -> Data {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 30; pixels[i + 3] = alpha }
        let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func arcGISErrorBodiesAreRecognised() {
        let missing = Data(#"{"error":{"code":404,"message":"Tile not found","details":[]}}"#.utf8)
        #expect(TileImage.arcGISErrorCode(missing) == 404)
        #expect(TileImage.arcGISErrorCode(Data(#" {"error":{"code":"500","message":"x"}}"#.utf8)) == 500)
        #expect(TileImage.arcGISErrorCode(Data("<html>login</html>".utf8)) == nil)
        #expect(TileImage.arcGISErrorCode(Data(#"{"ok":true}"#.utf8)) == nil)
        #expect(TileImage.arcGISErrorCode(Data([0xFF, 0xD8, 0xFF])) == nil)
    }

    @Test func onlyImagesPassAndTransparentPNGsAreBlank() {
        #expect(!TileImage.isImage(Data("<html>login</html>".utf8)))
        #expect(!TileImage.isImage(Data()))
        #expect(TileImage.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])))
        let clear = Self.png(alpha: 0)
        #expect(TileImage.isImage(clear))
        #expect(clear.count <= TileImage.blankCheckLimit)
        #expect(TileImage.isBlank(clear))
        #expect(!TileImage.isBlank(Self.png(alpha: 255)))
        #expect(!TileImage.isBlank(Data([0xFF, 0xD8, 0xFF, 0xE0])))
    }
}
