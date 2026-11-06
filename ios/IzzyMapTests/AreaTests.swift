import Foundation
import ImageIO
import IzzyKit
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import IzzyMap

/// A transport answering from a closure, counting what was asked.
nonisolated final class TestTransport: AreaTransport {
    let handler: @Sendable (URL, TileID, Int) async -> AreaFetch
    private let asked = Mutex<[TileID: Int]>([:])

    init(_ handler: @escaping @Sendable (TileID, Int) async -> AreaFetch) { self.handler = { _, t, n in await handler(t, n) } }
    /// A handler that also sees the URL (which service).
    init(url handler: @escaping @Sendable (URL, TileID, Int) async -> AreaFetch) { self.handler = handler }

    /// The season year of a request's service (AerialPhoto2021 → 2021).
    static func year(_ url: URL) -> Int? {
        url.pathComponents.first { $0.hasPrefix("AerialPhoto") }.flatMap { Int($0.dropFirst(11)) }
    }

    /// Requests made so far (all tiles, all tries).
    var requests: Int { asked.withLock { $0.values.reduce(0, +) } }
    func requests(for tile: TileID) -> Int { asked.withLock { $0[tile] ?? 0 } }

    func fetch(_ url: URL) async -> AreaFetch {
        // …/AerialPhoto2021/MapServer/tile/{z}/{y}/{x}
        let parts = url.pathComponents.suffix(3).compactMap { Int($0) }
        let tile = TileID(z: parts[0], x: parts[2], y: parts[1])

        let n = asked.withLock { asked in
            asked[tile, default: 0] += 1
            return asked[tile]!
        }
        return await handler(url, tile, n)
    }

    /// A distinct JPEG-looking body per tile (the downloader checks magic only).
    static func jpeg(_ t: TileID) -> Data {
        var d = Data([0xFF, 0xD8, 0xFF, 0xE0])
        d.append(Data("\(t.z)/\(t.x)/\(t.y)".utf8))
        return d
    }

    static let clearPNG: Data = {
        let size = 256
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }()
}

@MainActor
struct AreaDownloaderTests {
    /// ~2.5 × 2.2 km over Hobart: 4 + 9 + 16 + 36 tiles at z13–16 (Good).
    static let box = AreaBox(west: 147.30, south: -42.895, east: 147.33, north: -42.875)
    static let good = 4 + 9 + 16 + 36

    static func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "area-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func job(_ transport: any AreaTransport, layer: AreaLayer = .aerial, detail: AreaDetail = .good,
                    folder: URL, area: AreaRecord? = nil, cap: Int = AreaPlan.maxTilesPerLayer) -> AreaLayerDownload {
        let record = area ?? AreaRecord(id: "testarea", name: "Test", box: box, detail: detail, layers: [layer])
        return AreaLayerDownload(area: record, layer: layer, folder: folder, transport: transport, backoff: .zero,
                                 reportEvery: .zero, cap: cap)
    }

    @Test func aLayerArrivesAsAPMTilesArchiveWithItsCredit() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // one z16 tile has no photo (404)
        let gap = AreaPlan.tiles(Self.box, zoom: 16)[5]
        let transport = TestTransport { t, _ in t == gap ? .absent : .body(TestTransport.jpeg(t)) }
        let job = Self.job(transport, folder: dir)
        let (record, stop) = await job.run { _ in }
        #expect(stop == nil)
        #expect(record.complete)
        #expect(record.planned == Self.good)
        #expect(record.done == Self.good)
        #expect(record.stored == Self.good - 1)
        #expect(transport.requests == Self.good)

        let reader = try PMTilesReader(url: job.archiveURL)
        #expect(reader.minZoom == 13 && reader.maxZoom == 16)
        #expect(reader.tileType == .jpeg)
        let t = AreaPlan.tiles(Self.box, zoom: 16)[0]
        #expect(try reader.tileData(z: t.z, x: t.x, y: t.y) == TestTransport.jpeg(t))   // byte for byte
        #expect(try reader.tileData(z: gap.z, x: gap.x, y: gap.y) == nil)
        // header bounds = the frame: MapLibre asks for nothing outside it
        #expect(abs(reader.bounds.west - Self.box.west) < 1e-6 && abs(reader.bounds.north - Self.box.north) < 1e-6)
        let meta = try reader.metadata()
        #expect((meta["attribution"] as? String)?.contains("CC BY-NC-ND 3.0 AU") == true)
        #expect((meta["attribution"] as? String)?.contains(Attribution.unalteredTerms) == true)
        // the work files and the absent log are gone
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(left == ["aerial.pmtiles"])
        #expect(record.bytes == Int64(try #require(job.archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)))
    }

    /// Interrupted mid-way (the network goes): what arrived stays in the
    /// journal; Resume fetches only the rest, and 404s aren't asked again.
    @Test func aStoppedLayerResumesWhereItWas() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gap = AreaPlan.tiles(Self.box, zoom: 14)[2]
        let budget = Mutex(30)
        let flaky = TestTransport { t, _ in
            let left = budget.withLock { b in
                b -= 1
                return b
            }
            if left < 0 { return .offline }
            return t == gap ? .absent : .body(TestTransport.jpeg(t))
        }
        let (first, stop) = await Self.job(flaky, folder: dir).run { _ in }
        #expect(stop == .offline)
        #expect(!first.complete)
        #expect(first.done > 0 && first.done <= 30)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "aerial.pmtiles.journal").path(percentEncoded: false)))

        let steady = TestTransport { t, _ in t == gap ? .absent : .body(TestTransport.jpeg(t)) }
        let job = Self.job(steady, folder: dir)
        let (second, again) = await job.run { _ in }
        #expect(again == nil)
        #expect(second.complete && second.done == Self.good && second.stored == Self.good - 1)
        // only the missing tiles were fetched again (the 404 was remembered)
        #expect(steady.requests == Self.good - first.done)
        #expect(steady.requests(for: gap) == 0)
        let reader = try PMTilesReader(url: job.archiveURL)
        #expect(reader.header.addressedTiles == UInt64(Self.good - 1))
    }

    /// A body that isn't a JPEG or PNG is never stored. One odd tile is
    /// skipped for the run (the rest arrive, resumable); three runs and it
    /// counts as absent, so Resume never stalls on it. Tile after tile of
    /// them is a login page: the layer stops, holding nothing against them.
    @Test func nonImagesAreSkippedAndNeverStored() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let odd = AreaPlan.tiles(Self.box, zoom: 15)[3]
        let transport = TestTransport { t, _ in
            t == odd ? .body(Data("<html><title>Oops</title></html>".utf8)) : .body(TestTransport.jpeg(t))
        }
        for run in 1 ... AreaPlan.strikesToGiveUp {
            let (record, stop) = await Self.job(transport, folder: dir).run { _ in }
            if run < AreaPlan.strikesToGiveUp {
                #expect(stop == .skipped(1), "run \(run)")
                #expect(!record.complete && record.done == Self.good - 1)
                #expect(FileManager.default.fileExists(atPath: dir.appending(path: "aerial.strikes").path(percentEncoded: false)))
            } else {
                #expect(stop == nil && record.complete && record.stored == Self.good - 1)
            }
        }
        #expect(transport.requests(for: odd) == AreaPlan.strikesToGiveUp * AreaPlan.badBodyAttempts)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "aerial.strikes").path(percentEncoded: false)))

        // a login page answering everything
        let dir2 = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let portal = TestTransport { _, _ in .body(Data("<html><title>Log in</title></html>".utf8)) }
        let (none, stop) = await Self.job(portal, folder: dir2).run { _ in }
        guard case let .failed(why) = stop else { Issue.record("expected a failure, got \(String(describing: stop))"); return }
        #expect(why.contains("not a map tile"))
        #expect(none.stored == 0 && !none.complete)
        #expect(!FileManager.default.fileExists(atPath: dir2.appending(path: "aerial.strikes").path(percentEncoded: false)))
    }

    /// LIST answers some misses with HTTP 200 and an ArcGIS error body:
    /// code 404 is absent (asked once); another code is a failure, retried.
    @Test func arcGISErrorBodiesAreMissesOrFailures() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let miss = AreaPlan.tiles(Self.box, zoom: 16)[7]
        let busy = AreaPlan.tiles(Self.box, zoom: 16)[8]
        let transport = TestTransport { t, n in
            if t == miss { return .body(Data(#"{"error":{"code":404,"message":"Tile not found","details":[]}}"#.utf8)) }
            if t == busy, n < 3 { return .body(Data(#"{"error":{"code":500,"message":"busy"}}"#.utf8)) }
            return .body(TestTransport.jpeg(t))
        }
        let (record, stop) = await Self.job(transport, folder: dir).run { _ in }
        #expect(stop == nil && record.complete)
        #expect(record.stored == Self.good - 1)
        #expect(transport.requests(for: miss) == 1)
        #expect(transport.requests(for: busy) == 3)
    }

    /// A failing tile is tried again with exponential backoff for ~30 s
    /// (here: no waiting) before the layer stops — "no connection" and an
    /// unreachable host alike.
    @Test func failuresAreRetriedBeforeTheLayerStops() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shaky = AreaPlan.tiles(Self.box, zoom: 14)[1]
        let flaky = TestTransport { t, n in
            if t == shaky, n < AreaPlan.attempts { return n.isMultiple(of: 2) ? .offline : .failed("theLIST not reachable") }
            return .body(TestTransport.jpeg(t))
        }
        let (ok, none) = await Self.job(flaky, folder: dir).run { _ in }
        #expect(none == nil && ok.complete)
        #expect(flaky.requests(for: shaky) == AreaPlan.attempts)

        let dir2 = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let down = TestTransport { t, _ in t == shaky ? .failed("HTTP 503") : .body(TestTransport.jpeg(t)) }
        let (_, stop) = await Self.job(down, folder: dir2).run { _ in }
        #expect(stop == .failed("HTTP 503"))
        #expect(down.requests(for: shaky) == AreaPlan.attempts)
        // the waits double up to ~30 s in all
        let waits = AreaPlan.retryDelays(base: .milliseconds(500))
        #expect(waits.first == .milliseconds(500) && waits.reduce(.zero, +) > .seconds(25))
        // DNS and connect failures are retried like any failure; only "not connected" reads as offline
        #expect(LiveAreaTransport.answer(to: URLError(.cannotFindHost)) == .failed("theLIST not found"))
        #expect(LiveAreaTransport.answer(to: URLError(.cannotConnectToHost)) == .failed("theLIST not reachable"))
        #expect(LiveAreaTransport.answer(to: URLError(.notConnectedToInternet)) == .offline)
        #expect(LiveAreaTransport.answer(to: URLError(.cancelled)) == .cancelled)
    }

    /// Killed after the archive was renamed into place but before the
    /// registry heard of it: the next run reads it and is done.
    @Test func aFinishedArchiveWithoutWorkFilesIsComplete() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = TestTransport { t, _ in .body(TestTransport.jpeg(t)) }
        let job = Self.job(first, folder: dir)
        let (done, _) = await job.run { _ in }
        #expect(done.complete)
        // the registry still says "not started"
        let again = TestTransport { t, _ in .body(TestTransport.jpeg(t)) }
        try Data().write(to: dir.appending(path: "aerial.absent"))
        let (record, stop) = await Self.job(again, folder: dir).run { _ in }
        #expect(stop == nil && record.complete)
        #expect(record.stored == Self.good && record.bytes == done.bytes)
        #expect(again.requests == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) == ["aerial.pmtiles"])
    }

    /// Writing the archive reports progress too (the system bar keeps moving).
    @Test func savingReportsProgress() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = TestTransport { t, _ in .body(TestTransport.jpeg(t)) }
        let saving = Mutex<[Double]>([])
        let (record, _) = await Self.job(transport, folder: dir).run { p in
            if let f = p.saving { saving.withLock { $0.append(f) } }
        }
        #expect(record.complete)
        let steps = saving.withLock { $0 }
        #expect(!steps.isEmpty && steps.last == 1 && steps == steps.sorted())
    }

    /// Seasons: z13–15 are all asked for; LIST's transparent "no photo"
    /// PNGs count as absent and nothing below them is fetched.
    @Test func seasonsFetchDeeperOnlyUnderFlownTiles() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let z15 = AreaPlan.tiles(Self.box, zoom: 15)
        let flown = Set(z15.prefix(4))
        let transport = TestTransport { t, _ in
            if t.z == 15 { return flown.contains(t) ? .body(TestTransport.jpeg(t)) : .body(TestTransport.clearPNG) }
            if t.z > 15 { return .body(TestTransport.jpeg(t)) }
            return .absent
        }
        let job = Self.job(transport, layer: .season(2024), detail: .fine, folder: dir)
        let (record, stop) = await job.run { _ in }
        #expect(stop == nil && record.complete)
        let deep = AreaPlan.candidates(Self.box, layer: .season(2024), detail: .fine, flown: { flown.contains($0) })
        #expect(transport.requests == deep.count)
        for t in AreaPlan.tiles(Self.box, zoom: 16) where !flown.contains(AreaPlan.packParent(t)) {
            #expect(transport.requests(for: t) == 0)
        }
        let reader = try PMTilesReader(url: job.archiveURL)
        // blank z15 tiles are not stored
        let blank = try #require(z15.first { !flown.contains($0) })
        #expect(try reader.tileData(z: blank.z, x: blank.x, y: blank.y) == nil)
        #expect(record.stored == deep.filter { $0.z >= 15 }.count - (z15.count - flown.count))
    }

    /// A season not flown inside the frame finishes with no archive at all.
    @Test func anUnflownSeasonLeavesNoArchive() async {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = TestTransport { _, _ in .absent }
        let job = Self.job(transport, layer: .season(2021), detail: .finest, folder: dir)
        let (record, stop) = await job.run { _ in }
        #expect(stop == nil && record.complete && record.stored == 0)
        #expect(transport.requests == AreaPlan.count(Self.box, zooms: 13 ... 15))
        #expect(!FileManager.default.fileExists(atPath: job.archiveURL.path(percentEncoded: false)))
    }

    /// Over the cap the layer keeps the deepest level that fits (and says
    /// so); only when even z13–15 don't fit is nothing fetched.
    @Test func overTheCapTheLayerKeepsWhatFits() async {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = TestTransport { t, _ in .body(TestTransport.jpeg(t)) }
        // z13–15: 29 tiles; Good adds 36
        let (record, stop) = await Self.job(transport, folder: dir, cap: 40).run { _ in }
        #expect(stop == nil && record.complete)
        #expect(record.cappedAt == 15 && record.planned == 29 && transport.requests == 29)

        let dir2 = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let none = TestTransport { t, _ in .body(TestTransport.jpeg(t)) }
        let (_, tooLarge) = await Self.job(none, folder: dir2, cap: 20).run { _ in }
        guard case .tooLarge = tooLarge else { Issue.record("expected tooLarge"); return }
        #expect(none.requests == 0)
    }

    /// A season flown everywhere in the frame is over the cap only once its
    /// z15 answers are in: it finishes at what fits, and the newer seasons
    /// after it still download (they used to be blocked for ever).
    @Test func anOversizeSeasonDoesntBlockTheNextOnes() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let z15 = AreaPlan.tiles(Self.box, zoom: 15)
        let transport = TestTransport(url: { url, t, _ in
            if t.z < 15 { return .absent }
            if t.z == 15 {
                // 2021: flown everywhere; 2024: one z15 tile
                if t == z15[0] || TestTransport.year(url) == 2021 { return .body(TestTransport.jpeg(t)) }
                return .body(TestTransport.clearPNG)
            }
            return .body(TestTransport.jpeg(t))
        })
        let store = AreaStore(directory: dir, transport: transport, backgroundTask: false)
        store.backoff = .zero
        store.cap = 40
        let area = store.add(name: "Seasons", box: Self.box, detail: .good, layers: [.season(2021), .season(2024)])
        await Self.wait("complete") { store.status(area.id) == .complete }
        let done = try #require(store.area(area.id))
        #expect(done[.season(2021)]?.cappedAt == 15)
        let under = AreaPlan.tiles(Self.box, zoom: 16).count { AreaPlan.packParent($0) == z15[0] }
        #expect(done[.season(2024)]?.cappedAt == nil && done[.season(2024)]?.stored == 1 + under)
        #expect(AreaText.notes(done, .complete).contains { $0.contains("kept to statewide detail") })
        #expect(!store.run.failed)
        // the style knows the capped archive stops at z15
        #expect(store.styleSources.first { $0.layer == .season(2021) }?.maxZoom == 15)
    }

    // MARK: Store

    static func slowStore(_ dir: URL) -> (AreaStore, TestTransport) {
        let transport = TestTransport { t, _ in
            try? await Task.sleep(for: .milliseconds(40))
            return Task.isCancelled ? .cancelled : .body(TestTransport.jpeg(t))
        }
        let store = AreaStore(directory: dir, transport: transport, backgroundTask: false)
        store.backoff = .zero
        return (store, transport)
    }

    static func wait(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
        let start = ContinuousClock.now
        while !condition() {
            if start.duration(to: .now) > timeout { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func theStoreDownloadsSavesAndDrawsFinishedLayers() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = Self.slowStore(dir)
        let area = store.add(name: "  ", box: Self.box, detail: .good, layers: [.aerial, .topo])
        #expect(area.name == "Area 1")
        #expect(store.status(area.id) != .complete)
        await Self.wait("complete") { store.status(area.id) == .complete }
        #expect(store.styleSources.map(\.layer) == [.topo, .aerial])
        #expect(store.styleSources.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) })
        // the registry survives a relaunch
        let again = AreaStore(directory: dir, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        #expect(again.areas.map(\.id) == [area.id])
        #expect(again.area(area.id)?.isComplete == true)
        #expect(again.styleSources.count == 2)
        #expect(again.defaultName == "Area 2")
    }

    /// Delete stops the running download first, waits, then removes the
    /// files; the map loses the area at once.
    @Test func deleteStopsTheDownloadFirst() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, transport) = Self.slowStore(dir)
        let area = store.add(name: "Doomed", box: Self.box, detail: .fine, layers: [.aerial])
        await Self.wait("progress") { (store.area(area.id)?.done ?? 0) > 6 }
        await store.delete(area.id)
        #expect(store.areas.isEmpty)
        #expect(store.running == nil)
        #expect(!FileManager.default.fileExists(atPath: store.folder(area.id).path(percentEncoded: false)))
        let asked = transport.requests
        try await Task.sleep(for: .milliseconds(300))
        #expect(transport.requests == asked, "no request after Delete")
        #expect(try AreaRegistry.load(from: try #require(store.registryURL)).areas.isEmpty)
    }

    /// Pause keeps what arrived; Resume carries on to the end.
    @Test func pauseAndResume() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, transport) = Self.slowStore(dir)
        let area = store.add(name: "Mt Wellington", box: Self.box, detail: .good, layers: [.aerial])
        await Self.wait("progress") { (store.area(area.id)?.done ?? 0) > 10 }
        await store.pause(area.id)
        guard case .incomplete = store.status(area.id) else { Issue.record("expected incomplete"); return }
        let done = try #require(store.area(area.id)).done
        #expect(done > 10 && done < Self.good)
        store.start(area.id)
        await Self.wait("complete") { store.status(area.id) == .complete }
        // at most the requests in flight when it paused were asked twice
        #expect(transport.requests <= Self.good + AreaPlan.concurrency)
    }

    @Test func spaceShortfallCountsTheRemainingLayers() {
        let store = AreaStore(directory: nil, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        let area = AreaRecord(name: "A", box: Self.box, detail: .good, layers: [.aerial])
        #expect(store.shortfall(for: area, free: 10_000_000_000) == nil)
        #expect(store.shortfall(for: area, free: 1_000_000) != nil)
    }

    /// Resume needs room for what is LEFT: 900 of 1,000 tiles answered,
    /// mostly sea — the rest is small, whatever the full estimate says.
    @Test func resumeShortfallCountsWhatIsLeft() {
        let store = AreaStore(directory: nil, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        let wide = AreaBox(west: 147.28, south: -42.92, east: 147.34, north: -42.86)
        var area = AreaRecord(name: "Coast", box: wide, detail: .finest, layers: [.aerial])
        let full = AreaPlan.estimate(wide, layer: .aerial, detail: .finest)
        let free = AreaPlan.spaceMargin + full.bytes / 2
        #expect(store.shortfall(for: area, free: free) != nil)   // fresh: the whole estimate
        area[.aerial]?.planned = full.tiles
        area[.aerial]?.done = full.tiles - 100
        area[.aerial]?.stored = (full.tiles - 100) / 10
        area[.aerial]?.bytes = Int64((full.tiles - 100) / 10) * 20_000
        #expect(store.shortfall(for: area, free: free) == nil)
    }

    /// The system's banner says whether everything asked for in THIS run
    /// arrived: an old paused area doesn't make a later run a failure, and
    /// a Pause isn't one either.
    @Test func theRunReportsItsOwnOutcome() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = Self.slowStore(dir)
        let old = store.add(name: "Old", box: Self.box, detail: .good, layers: [.aerial])
        await Self.wait("progress") { (store.area(old.id)?.done ?? 0) > 4 }
        await store.pause(old.id)
        #expect(!store.run.failed)
        let fresh = store.add(name: "New", box: Self.box, detail: .good, layers: [.topo])
        await Self.wait("complete") { store.status(fresh.id) == .complete }
        #expect(!store.run.failed && store.run.areaIDs == [fresh.id])
        if case .incomplete = store.status(old.id) {} else { Issue.record("the old area stays paused") }
        // a stop for want of a connection is one
        store.transport = TestTransport { _, _ in .offline }
        store.start(old.id)
        await Self.wait("stopped") { !store.isQueued(old.id) }
        #expect(store.run.failed)
    }

    /// Resume tapped while a stopped job is still winding down: the new
    /// entry is the new job's — the old job's ending can't take it along.
    @Test func resumeWhileStoppingIsKept() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // requests that ignore cancellation for a while (a slow socket)
        let transport = TestTransport { t, _ in
            let deadline = ContinuousClock.now + .milliseconds(150)
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return .body(TestTransport.jpeg(t))
        }
        let store = AreaStore(directory: dir, transport: transport, backgroundTask: false)
        store.backoff = .zero
        let area = store.add(name: "Twice", box: Self.box, detail: .good, layers: [.aerial])
        await Self.wait("progress") { (store.area(area.id)?.done ?? 0) > 6 }
        let pausing = Task { await store.pause(area.id) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!store.isQueued(area.id))
        store.start(area.id)
        #expect(store.isQueued(area.id))
        await pausing.value
        #expect(store.isQueued(area.id))
        await Self.wait("complete") { store.status(area.id) == .complete }
    }

    /// Delete after the background task expired (stopAll): it still waits
    /// for the winding-down job before the folder goes.
    @Test func deleteAfterStopAllWaitsForTheJob() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = TestTransport { t, _ in
            let deadline = ContinuousClock.now + .milliseconds(150)
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return .body(TestTransport.jpeg(t))
        }
        let store = AreaStore(directory: dir, transport: transport, backgroundTask: false)
        store.backoff = .zero
        let area = store.add(name: "Expired", box: Self.box, detail: .fine, layers: [.aerial])
        await Self.wait("progress") { (store.area(area.id)?.done ?? 0) > 6 }
        store.stopAll(note: "iOS stopped the download")
        await store.delete(area.id)
        #expect(store.running == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!FileManager.default.fileExists(atPath: store.folder(area.id).path(percentEncoded: false)), "nothing written after Delete")
    }

    /// One area stopping for want of a connection drops the ones waiting
    /// behind it — each says why.
    @Test func droppedAreasSayWhy() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AreaStore(directory: dir, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        store.backoff = .zero
        let first = store.add(name: "A", box: Self.box, detail: .good, layers: [.aerial])
        let second = store.add(name: "B", box: Self.box, detail: .good, layers: [.topo])
        await Self.wait("stopped") { store.queue.isEmpty && store.running == nil }
        #expect(store.status(first.id) == .incomplete(AreaStop.offline.note))
        #expect(store.status(second.id) == .incomplete(AreaStop.offline.queuedNote))
    }

    /// The system bar: every layer of the run planned up front, so it never
    /// runs back and never reads 100 % between layers.
    @Test func runProgressIsMonotonicAcrossLayers() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = Self.slowStore(dir)
        let area = store.add(name: "Two", box: Self.box, detail: .good, layers: [.aerial, .topo])
        var seen: [Double] = []
        let start = ContinuousClock.now
        while store.status(area.id) != .complete, start.duration(to: .now) < .seconds(20) {
            seen.append(store.run.fraction)
            // topo paints first, so it downloads first
            if let a = store.area(area.id), a[.topo]?.complete == true, a[.aerial]?.done == 0 {
                #expect(store.run.fraction < 0.7, "one of two layers done")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen == seen.sorted())
        #expect(seen.allSatisfy { $0 < 1 })
        #expect(seen.contains { $0 > 0.3 && $0 < 0.7 })
    }

    /// Launch: folders no area owns and stray files go; an unreadable
    /// registry touches nothing, counts the bytes, and can be cleared.
    @Test func launchSweepsOrphans() throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        var area = AreaRecord(id: "0000aaaa", name: "Kept", box: Self.box, detail: .good, layers: [.aerial, .topo])
        area[.aerial]?.complete = true
        area[.aerial]?.stored = 3
        try AreaRegistry(areas: [area]).save(to: dir.appending(path: "areas.json"))
        let folder = dir.appending(path: "0000aaaa")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["aerial.pmtiles", "aerial.pmtiles.journal", "topo.pmtiles.tiles", "topo.pmtiles.journal",
                     "topo.pmtiles.partial", "season-2021.pmtiles", "notes.txt"] {
            try Data([1, 2, 3]).write(to: folder.appending(path: name))
        }
        try fm.createDirectory(at: dir.appending(path: "deadbeef"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: dir.appending(path: "deadbeef/aerial.pmtiles"))

        _ = AreaStore(directory: dir, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        #expect(!fm.fileExists(atPath: dir.appending(path: "deadbeef").path(percentEncoded: false)))
        let left = Set(try fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
        #expect(left == ["aerial.pmtiles", "topo.pmtiles.tiles", "topo.pmtiles.journal"])

        // a registry that can't be read: nothing is removed, the bytes count
        try Data("{garbage".utf8).write(to: dir.appending(path: "areas.json"))
        let broken = AreaStore(directory: dir, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        #expect(broken.loadError != nil && broken.orphanBytes > 0 && broken.bytes == broken.orphanBytes)
        #expect(fm.fileExists(atPath: folder.appending(path: "aerial.pmtiles").path(percentEncoded: false)))
    }

    @Test func removeEverythingClearsAnUnreadableRegistry() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appending(path: "0000bbbb"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: dir.appending(path: "0000bbbb/aerial.pmtiles"))
        try Data("{garbage".utf8).write(to: dir.appending(path: "areas.json"))
        let store = AreaStore(directory: dir, transport: TestTransport { _, _ in .offline }, backgroundTask: false)
        #expect(store.loadError != nil)
        await store.removeEverything()
        #expect(store.loadError == nil && store.orphanBytes == 0 && store.areas.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) == ["areas.json"])
        #expect(try AreaRegistry.load(from: dir.appending(path: "areas.json")).areas.isEmpty)
    }
}

@MainActor
struct AreaStyleTests {
    static let box = AreaDownloaderTests.box

    private func ids(_ style: [String: Any]) -> [String] {
        (style["layers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    static func source(_ id: String, _ layer: AreaLayer) -> AreaStyleSource {
        AreaStyleSource(areaID: id, layer: layer, url: URL(filePath: "/areas/\(id)/\(layer.rawValue).pmtiles"), box: box)
    }

    static let areas = [source("aaaa0001", .aerial), source("aaaa0001", .topo), source("aaaa0001", .season(2021)),
                        source("aaaa0001", .season(2024)), source("aaaa0002", .aerial), source("aaaa0001", .tasmap)]

    @Test func areasSitRightAboveTheirPackAndLiveSource() throws {
        var state = LayerState.default
        state.base = .aerial
        let s = StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: Self.areas)
        let order = ids(s)
        #expect(Array(order.prefix(5)) == ["bg", "aerial", "aerial-live", "area-aaaa0001-aerial", "area-aaaa0002-aerial"])
        // below every overlay layer
        #expect(order.firstIndex(of: "area-aaaa0002-aerial")! < order.firstIndex(of: "tasveg-fill")!)
        // layers of other bases are left out with their base
        #expect(!order.contains("area-aaaa0001-tasmap") && !order.contains("area-aaaa0001-season-2024"))
        let src = try #require((s["sources"] as? [String: Any])?["area-aaaa0001-aerial"] as? [String: Any])
        #expect(src["url"] as? String == "pmtiles://file:///areas/aaaa0001/aerial.pmtiles")
        #expect(src["tiles"] == nil)
        // topo areas ride with the topo underlay (here: none, the aerial pack is local)
        #expect(!order.contains("area-aaaa0001-topo"))
        let noPack = StyleBuilder.style(state: state, data: StyleBuilderTests.both, tables: .empty, areas: Self.areas)
        #expect(Array(ids(noPack).prefix(6)) == ["bg", "topo", "topo-live", "area-aaaa0001-topo", "aerial-live",
                                                 "area-aaaa0001-aerial"])
        // offline: the areas stay (local), the live sources go
        let offline = StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, online: false, areas: Self.areas)
        #expect(Array(ids(offline).prefix(4)) == ["bg", "aerial", "area-aaaa0001-aerial", "area-aaaa0002-aerial"])
    }

    /// A season's area sits between its own season and the next newer one
    /// (the newest flown photo still paints on top); the newest season's
    /// above its live source.
    @Test func seasonAreasKeepTheStackChronological() {
        var state = LayerState.default
        state.base = .seasons
        state.season = 4   // up to 2023–24
        let order = ids(StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: Self.areas))
        #expect(Array(order.prefix(11)) == ["bg", "topo", "topo-live", "area-aaaa0001-topo", "season-2020", "season-2021",
                                            "area-aaaa0001-season-2021", "season-2022", "season-2023", "season-2024",
                                            "season-live"])
        #expect(order[11] == "area-aaaa0001-season-2024")
        for id in ["area-aaaa0001-season-2021", "area-aaaa0001-season-2024"] {
            let layer = (StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: Self.areas)["layers"]
                as? [[String: Any]])?.first { $0["id"] as? String == id }
            #expect((layer?["paint"] as? [String: Any])?["raster-fade-duration"] as? Int == 0)
        }
    }

    /// Online, an area hands over to the sharper live source where it would
    /// only stretch (its layer stops at its deepest level − 0.5 in map
    /// zoom), with a copy under the live source for while live tiles load or
    /// fail; offline it stretches on its own.
    @Test func areasHandOverToSharperLiveTiles() throws {
        var state = LayerState.default
        state.base = .aerial
        var fine = Self.source("aaaa0003", .aerial)
        fine = AreaStyleSource(areaID: fine.areaID, layer: .aerial, url: fine.url, box: fine.box, maxZoom: 17)
        let online = StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: [fine])
        #expect(Array(ids(online).prefix(5)) == ["bg", "aerial", "area-aaaa0003-aerial-under", "aerial-live", "area-aaaa0003-aerial"])
        let layers = online["layers"] as? [[String: Any]] ?? []
        #expect(layers.first { $0["id"] as? String == "area-aaaa0003-aerial" }?["maxzoom"] as? Double == StyleBuilder.levelEndZoom(17, tileSize: StyleBuilder.defaultTileSize))
        #expect(layers.first { $0["id"] as? String == "area-aaaa0003-aerial-under" }?["maxzoom"] == nil)
        let offline = StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, online: false, areas: [fine])
        let offLayers = offline["layers"] as? [[String: Any]] ?? []
        #expect(Array(ids(offline).prefix(3)) == ["bg", "aerial", "area-aaaa0003-aerial"])
        #expect(offLayers.first { $0["id"] as? String == "area-aaaa0003-aerial" }?["maxzoom"] == nil)
        // where detail ends: the frame, dashed, from the pack level 15 end zoom
        let outline = try #require(layers.first { $0["id"] as? String == StyleBuilder.LayerID.areaOutlines })
        #expect(outline["minzoom"] as? Double == StyleBuilder.levelEndZoom(15, tileSize: StyleBuilder.defaultTileSize))
        #expect(ids(online).firstIndex(of: StyleBuilder.LayerID.areaOutlines)! > ids(online).firstIndex(of: "tasveg-fill")!)
        // an area of a base not shown: no outline
        state.base = .topo
        #expect(!ids(StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: [fine]))
            .contains(StyleBuilder.LayerID.areaOutlines))
    }

    @Test func tasmapAreasAndTheLayerOrderTestsStillHold() {
        var state = LayerState.default
        state.base = .tasmap
        let order = ids(StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: Self.areas))
        #expect(Array(order.prefix(4)) == ["bg", "tasmap", "tasmap-live", "area-aaaa0001-tasmap"])
        // selection still last
        #expect(Array(order.suffix(3)) == StyleBuilder.LayerID.selection)
    }

    @Test func areaSourcesAreCreditedAsTheirLayer() {
        #expect(Attribution.credit(forSource: "area-aaaa0001-aerial") == Attribution.aerial)
        #expect(Attribution.credit(forSource: "area-aaaa0001-season-2021") == Attribution.seasons)
        #expect(Attribution.credit(forSource: "area-aaaa0001-tasmap") == Attribution.tasmap)
        #expect(Attribution.credit(forSource: "area-aaaa0001-topo") == Attribution.topo)
        #expect(Attribution.credit(forSource: "area-aaaa0001-relief") == nil)
        #expect(Attribution.credits(forSources: ["area-aaaa0001-aerial"]).first?.licence == .ccByNcNd3AU)
        #expect(AreaStyleSource.layer(ofSource: "aerial") == nil)
        // every source of a style with areas has a credit
        for base in BaseMap.allCases {
            var state = LayerState.default
            state.base = base
            state.season = 6
            let s = StyleBuilder.style(state: state, data: StyleBuilderTests.all, tables: .empty, areas: Self.areas)
            for id in (s["sources"] as? [String: Any] ?? [:]).keys {
                #expect(Attribution.credit(forSource: id) != nil || Attribution.uncreditedSources.contains(id), "\(id)")
            }
        }
    }
}

@MainActor
struct AreaSetupTests {
    static let box = AreaDownloaderTests.box

    @Test func seasonsAreOnlyThoseFlownInsideTheFrame() {
        let z15 = AreaPlan.tiles(Self.box, zoom: 15)
        // three packs on the device: one flown here, two not; the rest unknown
        let flown: [Int: Set<TileID>] = [2021: Set(z15.prefix(2)), 2022: [], 2023: []]
        let plan = AreaSetupPlan(box: Self.box, choices: [.seasons, .aerial], detail: .fine, flown: flown, free: nil)
        #expect(plan.layers == [.aerial, .season(2020), .season(2021), .season(2024), .season(2025), .season(2026)])
        #expect(plan.line(for: .seasons).hasPrefix("up to"))
        #expect(plan.totalLine.hasPrefix("Up to"))
        let all = Dictionary(uniqueKeysWithValues: Season.all.map { ($0.year, Set<TileID>()) })
            .merging([2024: Set(z15.prefix(1))]) { $1 }
        let known = AreaSetupPlan(box: Self.box, choices: [.seasons], detail: .fine, flown: all, free: nil)
        // the newest season (still being flown) is offered even where its pack has no photo yet
        #expect(known.layers == [.season(2024), .season(2026)])
        #expect(known.line(for: .seasons).contains("2 of 7 seasons flown here"))
        #expect(known.line(for: .seasons).contains("2025–26 may add newly flown places"))
        #expect(known.totalLine.hasPrefix("Up to"))
        var settled = known
        settled.incompleteSeason = nil
        #expect(settled.layers == [.season(2024)])
        #expect(!settled.totalLine.hasPrefix("Up to"))
        let empty = Dictionary(uniqueKeysWithValues: Season.all.map { ($0.year, Set<TileID>()) })
        var none = AreaSetupPlan(box: Self.box, choices: [.seasons], detail: .fine, flown: empty, free: nil)
        none.incompleteSeason = nil
        #expect(!none.isAvailable(.seasons) && !none.canDownload)
        #expect(none.line(for: .seasons) == "Not flown inside the frame")
    }

    /// Without season packs on the device, the bundled coverage grid says
    /// which seasons were flown near the frame (an upper bound, never 7 ×
    /// the whole pyramid), and an over-cap season never blocks Download.
    @Test func seasonsWithoutPacksUseTheCoverageGrid() {
        let touches = Dictionary(uniqueKeysWithValues: Season.all.map { ($0.year, $0.year == 2021 || $0.year == 2024) })
        let plan = AreaSetupPlan(box: Self.box, choices: [.seasons], detail: .fine, flown: [:], free: nil, touches: touches)
        #expect(plan.layers == [.season(2021), .season(2024), .season(2026)])
        #expect(plan.line(for: .seasons).contains("3 of 7 seasons flown here"))
        let big = AreaBox(west: 146.0, south: -43.0, east: 146.3, north: -42.7)
        let wide = AreaSetupPlan(box: big, choices: [.seasons], detail: .finest, flown: [:], free: nil, touches: touches)
        #expect(wide.canDownload)
        #expect(wide.line(for: .seasons).contains("less detail where too large"))
        // the bundled grid itself, over Hobart
        let grid = Footprint.Grid(zoom: 11, x0: 1860, y0: 1270, cols: 40, rows: 40)
        let cell = TileID(longitude: Self.box.centre.longitude, latitude: Self.box.centre.latitude, zoom: 11)
        var bits = Data(count: 200)
        let i = (cell.y - 1270) * 40 + (cell.x - 1860)
        bits[i >> 3] |= 1 << UInt8(i & 7)
        #expect(Footprint(grid: grid, bits: bits).touches(Self.box))
        #expect(!Footprint(grid: grid, bits: Data(count: 200)).touches(Self.box))
    }

    @Test func downloadNeedsALayerAndToFitTheCap() {
        let fits = AreaSetupPlan(box: Self.box, choices: [.aerial], detail: .finest, flown: [:], free: 50_000_000_000)
        #expect(fits.canDownload && fits.problem == nil)
        #expect(fits.downloadLabel.hasPrefix("Download · ~"))
        #expect(!AreaSetupPlan(box: Self.box, choices: [], detail: .fine, flown: [:], free: nil).canDownload)
        // short of room: still possible (Try Anyway), but said
        let tight = AreaSetupPlan(box: Self.box, choices: [.aerial], detail: .finest, flown: [:], free: 10_000_000)
        #expect(tight.canDownload && tight.shortfall != nil)
        #expect(tight.problem?.contains("free while it arrives") == true)
        let big = AreaBox(west: 146.0, south: -43.0, east: 146.3, north: -42.7)
        let over = AreaSetupPlan(box: big, choices: [.aerial], detail: .finest, flown: [:], free: nil)
        #expect(!over.canDownload)
        #expect(over.line(for: .aerial).hasPrefix("Too large at Finest"))
        #expect(over.levelLines[.finest] == "too big")
        #expect(AreaSetupPlan(box: big, choices: [.aerial], detail: .fine, flown: [:], free: nil).canDownload)
    }

    /// Sizes are ranges (×1.6 until finished areas measured the real
    /// mean), each detail level with its own, and the base map she is
    /// looking at is the one checked.
    @Test func sizesAreHonestRanges() {
        let plan = AreaSetupPlan(box: Self.box, choices: [.aerial], detail: .fine, flown: [:], free: nil)
        let nominal = AreaPlan.estimate(Self.box, layer: .aerial, detail: .fine).bytes
        #expect(plan.totalRange == nominal ... Int64((Double(nominal) * 1.6).rounded(.up)))
        #expect(plan.totalLine == AreaFramingMetrics.range(plan.totalRange!))
        #expect(plan.levelLines.count == 3)
        var calibrated = plan
        calibrated.calibration = ["aerial": AreaCalibration(layers: 4, tiles: 4000, bytes: 4000 * 27_000)]
        let r = calibrated.totalRange!
        #expect(r.lowerBound > nominal && r.upperBound < Int64(Double(nominal) * 1.6 * 1.2))
        #expect(AreaFramingMetrics.range(500_000 ... 800_000) == "0.5–0.8\u{00A0}MB")
        #expect(AreaFramingMetrics.range(12_000_000 ... 19_400_000) == "12–19\u{00A0}MB")
        #expect(AreaFramingMetrics.range(900_000_000 ... 1_400_000_000) == "0.9–1.4\u{00A0}GB")
        #expect(AreaFramingMetrics.roughly(500_000 ... 800_000) == "~1\u{00A0}MB")
        #expect(AreaFramingMetrics.roughly(1_000_000 ... 3_300_000) == "~4\u{00A0}MB")
        #expect(AreaFramingMetrics.roughly(10_000_000 ... 41_000_000) == "~45\u{00A0}MB")
        #expect(AreaChoice.defaults(base: .topo) == [.topo])
        #expect(AreaChoice.defaults(base: .aerial) == [.aerial])
        #expect(AreaChoice.defaults(base: .seasons) == [.seasons])
        #expect(AreaSetupPlan(box: Self.box, choices: [.topo], detail: .fine, flown: [:], free: nil).previewLayer == .topo)
        #expect(AreaSetupPlan(box: Self.box, choices: [.topo, .seasons], detail: .fine, flown: [:], free: nil).previewLayer == .aerial)
    }

    /// The detail plates cut the same ground from each level's tile.
    @Test func detailCropsShowTheSameGround() {
        let c = Self.box.centre
        let w = DetailCrops.window(longitude: c.longitude, latitude: c.latitude)
        let z18 = DetailCrops.rect(w, zoom: 18), z16 = DetailCrops.rect(w, zoom: 16)
        #expect(z18.rect.width == 64 && z16.rect.width == 16)
        #expect(z18.tile == TileID(longitude: c.longitude, latitude: c.latitude, zoom: 18))
        #expect(z16.tile == TileID(z: 16, x: z18.tile.x >> 2, y: z18.tile.y >> 2))
        for z in 16 ... 18 {
            let r = DetailCrops.rect(w, zoom: z).rect
            #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= 256 && r.maxY <= 256)
        }
    }

    @Test func framingSaysTheSizeOnTheGround() {
        #expect(AreaFramingMetrics.size(Self.box) == "2.4\u{00A0}×\u{00A0}2.2\u{00A0}km")
        let small = AreaBox(west: 147.30, south: -42.885, east: 147.305, north: -42.875)
        #expect(AreaFramingMetrics.size(small) == "410\u{00A0}m\u{00A0}×\u{00A0}1.1\u{00A0}km")
        let tiny = AreaBox(west: 147.30, south: -42.880, east: 147.307, north: -42.875)
        #expect(AreaFramingMetrics.size(tiny) == "570\u{00A0}×\u{00A0}560\u{00A0}m")
        let frame = AreaFramingMetrics.frame(in: CGRect(x: 0, y: 100, width: 400, height: 600))
        #expect(frame == CGRect(x: 32, y: 160, width: 336, height: 480))
        #expect(AreaFramingMetrics.frame(in: CGRect(x: 0, y: 0, width: 50, height: 50)) == nil)
    }

    @Test func rowsSayWhatTheyHold() {
        var area = AreaRecord(name: "Mt Field", box: Self.box, detail: .fine, layers: [.aerial, .season(2021), .season(2024), .topo])
        #expect(AreaText.contents(area) == "Topographic map, Aerial photos, 2 seasons · Fine (0.9\u{00A0}m)")
        #expect(AreaText.status(area, .incomplete(nil), running: nil, device: "iPhone") == "Not started")
        area[.aerial]?.done = 50
        area[.aerial]?.planned = 200
        area[.aerial]?.bytes = 900_000
        #expect(AreaText.status(area, .incomplete(nil), running: nil, device: "iPhone") == "Incomplete · 25\u{00A0}% · 0.9\u{00A0}MB")
        #expect(AreaText.status(area, .complete, running: nil, device: "iPad").hasPrefix("On this iPad"))
    }

    @Test func framingFlowAndEscape() {
        let model = AppModel(data: .none, tables: .empty)
        model.present(.layers)
        model.trackingMode = .followWithHeading
        model.startFraming()
        #expect(model.isFraming && model.modal == nil)
        // the frame is the box: following (and heading) ends
        #expect(model.trackingMode == .off)
        #expect(model.escapeStep == .cancelFraming)
        // too large: Next does nothing
        model.map.framedBox = AreaBox(west: 145.5, south: -43.2, east: 146.5, north: -42.4)
        model.framingNext()
        #expect(model.modal == nil)
        model.map.framedBox = Self.box
        model.framingNext()
        #expect(model.modal?.presentation == .areaSetup && model.areaDraft == Self.box)
        // Escape: the setup sheet, then the frame
        model.escape()
        #expect(model.modal == nil && model.isFraming)
        model.escape()
        #expect(!model.isFraming && model.escapeStep == nil)
        // Download: framing ends, Storage opens
        model.startFraming()
        model.map.framedBox = Self.box
        model.framingNext()
        model.areaStarted()
        #expect(!model.isFraming && model.opensStorage && model.modal?.presentation == .layers)
    }
}
