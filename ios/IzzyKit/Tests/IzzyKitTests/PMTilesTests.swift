import Foundation
import Synchronization
import Testing
@testable import IzzyKit

/// The real packs in the repo's data/ (gitignored; absent in CI and worktrees —
/// `IZZY_DATA` points elsewhere) and the `pmtiles` CLI (brew) as the reference.
enum PMTilesFixtures {
    static let dataDir: URL = ProcessInfo.processInfo.environment["IZZY_DATA"].map { URL(filePath: $0) }
        ?? TestData.package.deletingLastPathComponent().deletingLastPathComponent().appending(path: "data")
    static func archive(_ name: String) -> URL { dataDir.appending(path: name) }
    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: archive(name).path(percentEncoded: false)) }

    static let cli: String? = ["/opt/homebrew/bin/pmtiles", "/usr/local/bin/pmtiles"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// `pmtiles tile <file> z x y` — empty output = no such tile.
    static func cliTile(_ file: URL, _ z: Int, _ x: Int, _ y: Int) throws -> Data {
        try run([ "tile", file.path(percentEncoded: false), "\(z)", "\(x)", "\(y)"]).out
    }

    static func run(_ args: [String]) throws -> (out: Data, status: Int32) {
        let p = Process()
        p.executableURL = URL(filePath: cli!)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (out, p.terminationStatus)
    }

    static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "izzykit-pmtiles-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic tiles inside an archive's bounds (± a margin, so some miss).
    static func sampleTiles(_ r: PMTilesReader, count: Int, seed: UInt64) -> [(Int, Int, Int)] {
        var rng = SplitMix(seed)
        let b = r.bounds
        return (0 ..< count).map { _ in
            let z = r.minZoom + Int(rng.next() % UInt64(r.maxZoom - r.minZoom + 1))
            let lon = b.west - 0.3 + (b.east - b.west + 0.6) * rng.unit()
            let lat = b.south - 0.3 + (b.north - b.south + 0.6) * rng.unit()
            return tile(z: z, lon: lon, lat: lat)
        }
    }

    static func tile(z: Int, lon: Double, lat: Double) -> (Int, Int, Int) {
        let n = Double(1 << z)
        let x = Int((lon + 180) / 360 * n)
        let rad = lat * .pi / 180
        let y = Int((1 - asinh(tan(rad)) / .pi) / 2 * n)
        return (z, min(max(x, 0), (1 << z) - 1), min(max(y, 0), (1 << z) - 1))
    }
}

struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

@Suite struct PMTilesTileIDTests {
    /// Vectors from go-pmtiles tile_id_test.go (the reference implementation).
    @Test func referenceVectors() {
        #expect(PMTiles.tileID(z: 0, x: 0, y: 0) == 0)
        #expect(PMTiles.tileID(z: 1, x: 0, y: 0) == 1)
        #expect(PMTiles.tileID(z: 1, x: 0, y: 1) == 2)
        #expect(PMTiles.tileID(z: 1, x: 1, y: 1) == 3)
        #expect(PMTiles.tileID(z: 1, x: 1, y: 0) == 4)
        #expect(PMTiles.tileID(z: 2, x: 0, y: 0) == 5)
        #expect(PMTiles.zxy(tileID: 0) == (0, 0, 0))
        #expect(PMTiles.zxy(tileID: 1) == (1, 0, 0))
        #expect(PMTiles.zxy(tileID: 19_078_479) == (12, 3423, 1763))
        #expect(PMTiles.tileID(z: 12, x: 3423, y: 1763) == 19_078_479)
    }

    @Test func roundTripsEveryTileUpToZoom8() {
        var bad = 0
        for z in 0 ... 8 {
            for x in 0 ..< (1 << z) {
                for y in 0 ..< (1 << z) where PMTiles.zxy(tileID: PMTiles.tileID(z: z, x: x, y: y)) != (z, x, y) {
                    bad += 1
                }
            }
        }
        #expect(bad == 0)
    }

    /// Ids are dense: zoom z starts right after the last id of zoom z − 1.
    @Test func idsAreDensePerZoom() {
        for z in 1 ... 20 {
            let first = PMTiles.tileID(z: z, x: 0, y: 0)
            #expect(first == ((1 << (2 * UInt64(z))) - 1) / 3)
            #expect(PMTiles.zxy(tileID: first - 1).z == z - 1)
        }
    }

    @Test func extremesUpToZoom31() {
        for z in 0 ... 31 {
            let d = (1 << z) - 1
            for (x, y) in [(0, 0), (d, 0), (0, d), (d, d)] {
                #expect(PMTiles.zxy(tileID: PMTiles.tileID(z: z, x: x, y: y)) == (z, x, y), "z\(z) \(x)/\(y)")
            }
        }
    }
}

@Suite struct PMTilesDirectoryTests {
    @Test func encodesAndDecodesWithContiguousAndDedupedOffsets() throws {
        let entries: [PMTiles.Entry] = [
            .init(tileID: 0, offset: 0, length: 10, runLength: 1),
            .init(tileID: 1, offset: 10, length: 5, runLength: 3),   // contiguous → encoded 0
            .init(tileID: 7, offset: 0, length: 10, runLength: 1),   // dedup back-reference
            .init(tileID: 300, offset: 15, length: 1, runLength: 0), // leaf pointer
            .init(tileID: 1 << 40, offset: 1 << 33, length: .max, runLength: .max),
        ]
        let raw = PMTiles.encodeDirectory(entries)
        #expect(try PMTiles.decodeDirectory(raw) == entries)
        let gz = try PMTiles.gzip(raw)
        #expect(gz.prefix(2) == Data([0x1F, 0x8B]))
        #expect(try PMTiles.decodeDirectory(PMTiles.gunzip(gz)) == entries)
    }

    @Test func rejectsTruncatedDirectories() throws {
        let raw = PMTiles.encodeDirectory([.init(tileID: 5, offset: 0, length: 300, runLength: 1)])
        #expect(throws: PMTilesError.self) { try PMTiles.decodeDirectory(raw.dropLast()) }
        let gz = try PMTiles.gzip(raw)
        #expect(throws: PMTilesError.self) { try PMTiles.gunzip(gz.dropLast(4)) }
    }

    @Test func findCoversRunsAndLeaves() {
        let dir: [PMTiles.Entry] = [
            .init(tileID: 10, offset: 0, length: 1, runLength: 3),
            .init(tileID: 20, offset: 1, length: 1, runLength: 0),
        ]
        #expect(PMTiles.find(9, in: dir) == nil)
        #expect(PMTiles.find(12, in: dir)?.tileID == 10)
        #expect(PMTiles.find(13, in: dir) == nil)
        #expect(PMTiles.find(25, in: dir)?.tileID == 20) // inside the leaf's range
    }
}

@Suite struct PMTilesWriterTests {
    /// Tiles with sparse zooms (no z1–z4, gaps), duplicates and a replacement,
    /// added in shuffled order → read back byte-for-byte.
    @Test func roundTripIsByteIdentical() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "area.pmtiles")
        var rng = SplitMix(42)
        var expected: [String: Data] = [:]
        var adds: [(Int, Int, Int, Data)] = [(0, 0, 0, Data("root".utf8))]
        let sea = Data(repeating: 0xAB, count: 1652)
        for z in [5, 9, 12, 15] {
            let n = 1 << z
            for _ in 0 ..< 60 {
                let x = Int(rng.next() % UInt64(n)), y = Int(rng.next() % UInt64(n))
                let isSea = rng.next() % 3 == 0
                let bytes = isSea ? sea : Data((0 ..< (1 + Int(rng.next() % 900))).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                adds.append((z, x, y, bytes))
            }
        }
        // a contiguous run of identical tiles (run-length encoded)
        for x in 100 ..< 132 { adds.append((15, x, 200, sea)) }
        var order = adds
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        let w = try PMTilesWriter(destination: url, tileType: .jpeg)
        for (z, x, y, d) in order {
            try w.add(z: z, x: x, y: y, data: d)
            expected["\(z)/\(x)/\(y)"] = d
        }
        try w.add(z: 0, x: 0, y: 0, data: Data("replaced".utf8))
        expected["0/0/0"] = Data("replaced".utf8)

        let h = try w.finish(name: "Test area", attribution: "© test", metadata: ["layer": "aerial"])
        #expect(!FileManager.default.fileExists(atPath: w.dataURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: w.journalURL.path(percentEncoded: false)))
        #expect(h.addressedTiles == UInt64(expected.count))
        #expect(h.tileEntries < h.addressedTiles) // the sea run collapsed
        #expect(h.clustered && h.internalCompression == .gzip)

        let r = try PMTilesReader(url: url)
        #expect(r.header == h)
        #expect(r.minZoom == 0 && r.maxZoom == 15 && r.tileType == .jpeg)
        for (key, bytes) in expected {
            let p = key.split(separator: "/").map { Int($0)! }
            #expect(try r.tileData(z: p[0], x: p[1], y: p[2]) == bytes, "\(key)")
        }
        #expect(try r.tileData(z: 3, x: 1, y: 1) == nil)
        #expect(try r.tileExists(z: 15, x: 132, y: 200) == false)
        #expect(try r.tileExists(z: 40, x: 0, y: 0) == false)
        let meta = try r.metadata()
        #expect(meta["name"] as? String == "Test area")
        #expect(meta["attribution"] as? String == "© test")
        #expect(meta["layer"] as? String == "aerial")
        // the sea bytes are stored once
        let distinct = Set(expected.values).count
        #expect(h.tileContents == UInt64(distinct))
        #expect(h.tileDataLength == UInt64(Set(expected.values).reduce(0) { $0 + $1.count }))

        if PMTilesFixtures.cli != nil {
            #expect(try PMTilesFixtures.run(["verify", url.path(percentEncoded: false)]).status == 0)
            #expect(try PMTilesFixtures.cliTile(url, 15, 110, 200) == sea)
        }
    }

    /// 20,000 entries cannot sit in the root: leaves, still byte-identical.
    @Test func splitsIntoLeafDirectories() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "big.pmtiles")
        let w = try PMTilesWriter(destination: url, tileType: .png)
        func bytes(_ x: Int, _ y: Int) -> Data { withUnsafeBytes(of: UInt32(x << 16 | y)) { Data($0) } }
        for x in 0 ..< 200 { for y in 0 ..< 100 { try w.add(z: 14, x: 14_800 + x, y: 9_700 + y, data: bytes(x, y)) } }
        let h = try w.finish(name: "big", attribution: "test")
        #expect(h.leafDirectoryLength > 0)
        #expect(h.rootOffset + h.rootLength <= UInt64(PMTiles.rootLimit))
        let r = try PMTilesReader(url: url)
        var mismatches = 0
        for x in stride(from: 0, to: 200, by: 7) {
            for y in stride(from: 0, to: 100, by: 3) where try r.tileData(z: 14, x: 14_800 + x, y: 9_700 + y) != bytes(x, y) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
        #expect(try r.tileExists(z: 14, x: 14_799, y: 9_700) == false)
        let b = r.bounds
        #expect(b.west < b.east && b.south < b.north)
        if PMTilesFixtures.cli != nil {
            #expect(try PMTilesFixtures.run(["verify", url.path(percentEncoded: false)]).status == 0)
            #expect(try PMTilesFixtures.cliTile(url, 14, 14_999, 9_799) == bytes(199, 99))
        }
    }

    /// A download killed mid-way continues from the journal.
    @Test func resumesFromTheJournal() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "resume.pmtiles")
        do {
            let w = try PMTilesWriter(destination: url, tileType: .png)
            for x in 0 ..< 10 { try w.add(z: 10, x: x, y: 0, data: Data([UInt8(x), 1, 2])) }
        } // dropped without finish (process killed)
        // a torn record at the end of the journal is ignored
        let journal = url.appendingPathExtension("journal")
        let fh = try FileHandle(forWritingTo: journal)
        try fh.seekToEnd(); try fh.write(contentsOf: Data([1, 2, 3])); try fh.close()

        let w = try PMTilesWriter(destination: url, tileType: .png, resume: true)
        #expect(w.tileCount == 10)
        #expect(w.contains(z: 10, x: 9, y: 0) && !w.contains(z: 10, x: 10, y: 0))
        for x in 10 ..< 20 { try w.add(z: 10, x: x, y: 0, data: Data([UInt8(x), 1, 2])) }
        try w.finish(name: "r", attribution: "a")
        let r = try PMTilesReader(url: url)
        for x in 0 ..< 20 { #expect(try r.tileData(z: 10, x: x, y: 0) == Data([UInt8(x), 1, 2])) }

        // another tile type never resumes someone else's work files
        let other = try PMTilesWriter(destination: dir.appending(path: "x.pmtiles"), tileType: .png)
        try other.add(z: 1, x: 0, y: 0, data: Data([1]))
        let fresh = try PMTilesWriter(destination: dir.appending(path: "x.pmtiles"), tileType: .jpeg, resume: true)
        #expect(fresh.tileCount == 0)
        fresh.cancel()
    }

    @Test func refusesBadInput() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = try PMTilesWriter(destination: dir.appending(path: "bad.pmtiles"), tileType: .png)
        #expect(throws: PMTilesError.self) { try w.add(z: 2, x: 4, y: 0, data: Data([1])) }
        #expect(throws: PMTilesError.self) { try w.add(z: 2, x: 0, y: 0, data: Data()) }
        #expect(throws: PMTilesError.self) { try w.finish(name: "n", attribution: "a") } // no tiles
        let mvt = try PMTilesWriter(destination: dir.appending(path: "v.pmtiles"), tileType: .mvt)
        try mvt.add(z: 0, x: 0, y: 0, data: Data([1]))
        #expect(throws: PMTilesError.self) { try mvt.finish(name: "n", attribution: "a") } // no vector_layers
        mvt.cancel()
    }

    @Test func readerRejectsNonArchives() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appending(path: "junk.pmtiles")
        try Data(repeating: 0, count: 200).write(to: f)
        #expect(throws: PMTilesError.notPMTiles) { try PMTilesReader(url: f) }
        var v2 = Data("PMTiles".utf8); v2.append(2); v2.append(Data(count: 200))
        try v2.write(to: f)
        #expect(throws: PMTilesError.unsupportedVersion(2)) { try PMTilesReader(url: f) }
        #expect(throws: PMTilesError.self) { try PMTilesReader(url: dir.appending(path: "missing.pmtiles")) }
    }
}

/// The real packs, against the `pmtiles` CLI. Skipped without data/ or the CLI.
@Suite struct PMTilesRealArchiveTests {
    static let ready = PMTilesFixtures.cli != nil

    @Test(.enabled(if: ready && PMTilesFixtures.has("tasveg.pmtiles")))
    func tasvegVectorGzip() throws {
        let r = try PMTilesReader(url: PMTilesFixtures.archive("tasveg.pmtiles"))
        #expect(r.tileType == .mvt && r.header.tileCompression == .gzip && r.header.internalCompression == .gzip)
        #expect(r.minZoom == 0 && r.maxZoom == 14)
        #expect(r.header.addressedTiles == 30_240)
        let meta = try r.metadata()
        #expect(meta["name"] as? String == "TASVEG 5.0")
        #expect(meta["vector_layers"] != nil)
        try compareWithCLI(r, count: 40, seed: 1)
        // a gzipped MVT comes back as stored
        #expect(try r.tileData(z: 0, x: 0, y: 0)?.prefix(2) == Data([0x1F, 0x8B]))
    }

    @Test(.enabled(if: ready && PMTilesFixtures.has("topo_tas.pmtiles")))
    func topoPNG() throws {
        let r = try PMTilesReader(url: PMTilesFixtures.archive("topo_tas.pmtiles"))
        #expect(r.tileType == .png && r.header.tileCompression == .none)
        #expect(r.minZoom == 0 && r.maxZoom == 15)
        #expect(r.header.leafDirectoryLength > 0) // 300k entries: leaves
        #expect((try r.metadata())["attribution"] as? String != nil)
        try compareWithCLI(r, count: 40, seed: 2)
    }

    @Test(.enabled(if: ready && PMTilesFixtures.has("aerial_2024.pmtiles")))
    func sparseSeason() throws {
        let r = try PMTilesReader(url: PMTilesFixtures.archive("aerial_2024.pmtiles"))
        #expect(r.tileType == .jpeg && r.maxZoom == 15)
        #expect((try r.metadata())["season"] as? String == "2023–24")
        try compareWithCLI(r, count: 60, seed: 3, minPresent: 3)
    }

    /// The season caption's workload: 10,000 random existence probes, warm.
    @Test(.enabled(if: PMTilesFixtures.has("aerial_2024.pmtiles")))
    func existenceLookupsAreFast() throws {
        let r = try PMTilesReader(url: PMTilesFixtures.archive("aerial_2024.pmtiles"))
        var rng = SplitMix(7)
        let b = r.bounds
        let probes = (0 ..< 10_000).map { _ in
            PMTilesFixtures.tile(z: 8 + Int(rng.next() % 8),
                                 lon: b.west + (b.east - b.west) * rng.unit(),
                                 lat: b.south + (b.north - b.south) * rng.unit())
        }
        var hits = 0
        for (z, x, y) in probes where try r.tileExists(z: z, x: x, y: y) { hits += 1 } // warm the leaf cache
        let clock = ContinuousClock()
        var again = 0
        let elapsed = try clock.measure {
            for (z, x, y) in probes where try r.tileExists(z: z, x: x, y: y) { again += 1 }
        }
        #expect(again == hits)
        #expect(hits > 0 && hits < probes.count)
        print("PMTiles: 10,000 existence lookups on aerial_2024 in \(elapsed) (\(hits) present)")
        #expect(elapsed < .milliseconds(500))
    }

    /// One reader shared by 8 threads (the caption probes and tile loads race):
    /// same answers as a serial pass, leaf cache squeezed to force evictions.
    @Test(.enabled(if: PMTilesFixtures.has("topo_tas.pmtiles")))
    func concurrentLookupsAgree() throws {
        let r = try PMTilesReader(url: PMTilesFixtures.archive("topo_tas.pmtiles"), leafCacheSize: 4)
        let probes = PMTilesFixtures.sampleTiles(r, count: 800, seed: 11)
        let serial = try probes.map { try r.tileExists(z: $0.0, x: $0.1, y: $0.2) }
        let results = Mutex([Bool?](repeating: nil, count: probes.count))
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in stride(from: worker, to: probes.count, by: 8) {
                let (z, x, y) = probes[i]
                let v = try? r.tileExists(z: z, x: x, y: y)
                results.withLock { $0[i] = v }
            }
        }
        #expect(results.withLock { $0 } == serial.map { $0 })
    }

    /// Existence and bytes for sampled tiles (plus a few known-present ones) agree with the CLI.
    private func compareWithCLI(_ r: PMTilesReader, count: Int, seed: UInt64, minPresent: Int = 10) throws {
        var tiles = PMTilesFixtures.sampleTiles(r, count: count, seed: seed)
        tiles.append((0, 0, 0))
        let c = (r.bounds.west + r.bounds.east) / 2, m = (r.bounds.south + r.bounds.north) / 2
        for z in r.minZoom ... r.maxZoom { tiles.append(PMTilesFixtures.tile(z: z, lon: c, lat: m)) }
        var present = 0
        for (z, x, y) in tiles {
            let ref = try PMTilesFixtures.cliTile(r.url, z, x, y)
            let ours = try r.tileData(z: z, x: x, y: y)
            #expect(try r.tileExists(z: z, x: x, y: y) == !ref.isEmpty, "\(z)/\(x)/\(y)")
            #expect((ours ?? Data()) == ref, "\(z)/\(x)/\(y): \(ours?.count ?? -1) vs \(ref.count) bytes")
            if !ref.isEmpty { present += 1 }
        }
        #expect(present >= minPresent, "only \(present) of \(tiles.count) sampled tiles present")
    }
}

/// Corrupt archives (a torn download, a bad disk, a hostile file) must fail
/// with a `PMTilesError`, never trap on arithmetic or allocate gigabytes.
@Suite struct PMTilesFuzzTests {
    /// A small archive with leaf directories, so every section is exercised.
    static func sample(in dir: URL) throws -> (url: URL, data: Data, header: PMTiles.Header) {
        let url = dir.appending(path: "fuzz.pmtiles")
        let w = try PMTilesWriter(destination: url, tileType: .png)
        for x in 0 ..< 200 { for y in 0 ..< 100 {
            try w.add(z: 14, x: 14_800 + x, y: 9_700 + y, data: Data([UInt8(x), UInt8(y), 7]))
        } }
        let h = try w.finish(name: "fuzz", attribution: "test")
        return (url, try Data(contentsOf: url), h)
    }

    /// Opens `bytes` and pokes every entry point; returns whether it opened.
    @discardableResult
    static func exercise(_ bytes: Data, at url: URL, seed: UInt64) -> Bool {
        try? bytes.write(to: url)
        guard let r = try? PMTilesReader(url: url, leafCacheSize: 2) else { return false }
        var rng = SplitMix(seed)
        for _ in 0 ..< 40 {
            let x = 14_790 + Int(rng.next() % 220), y = 9_690 + Int(rng.next() % 120)
            _ = try? r.tileExists(z: 14, x: x, y: y)
            _ = try? r.tileData(z: 14, x: x, y: y)
        }
        _ = try? r.tileExists(z: 31, x: Int(Int32.max), y: 5)
        _ = try? r.metadata()
        return true
    }

    @Test func truncatedFilesNeverCrash() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, data, h) = try Self.sample(in: dir)
        let target = dir.appending(path: "t.pmtiles")
        #expect(Self.exercise(data, at: target, seed: 1))
        // every length through the header, strides through root, metadata, leaves and tiles
        let root = Int(h.rootOffset + h.rootLength)
        let lengths = Array(0 ..< 160) + Array(stride(from: 160, to: root + 8, by: 37))
            + Array(stride(from: root + 8, to: data.count, by: 1_009))
        for n in lengths { Self.exercise(data.prefix(n), at: target, seed: UInt64(n)) }
        // a file cut inside the leaf section fails on lookup, not on open
        #expect(h.leafDirectoryLength > 0, "the sample has leaves")
        let cut = data.prefix(Int(h.leafDirectoryOffset) + 1)
        try cut.write(to: target)
        let r = try PMTilesReader(url: target)
        #expect(throws: PMTilesError.self) {
            for x in 0 ..< 200 { for y in 0 ..< 100 { _ = try r.tileExists(z: 14, x: 14_800 + x, y: 9_700 + y) } }
        }
        _ = url
    }

    @Test func garbledBytesNeverCrash() throws {
        let dir = PMTilesFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, data, h) = try Self.sample(in: dir)
        let target = dir.appending(path: "g.pmtiles")
        var rng = SplitMix(42)
        let structural = Int(h.tileDataOffset)  // header, root, metadata, leaves
        for round in 0 ..< 300 {
            var bytes = data
            for _ in 0 ..< 1 + Int(rng.next() % 6) {
                // mostly the structures; sometimes the header's 64-bit fields to extremes
                let at = Int(rng.next() % UInt64(round % 5 == 0 ? PMTiles.headerLength : structural))
                bytes[at] = round % 7 == 0 ? 0xFF : UInt8(truncatingIfNeeded: rng.next())
            }
            Self.exercise(bytes, at: target, seed: UInt64(round))
        }
        // header fields at UInt64.max: offsets, lengths, everything
        for field in 0 ..< 8 {
            var bytes = data
            bytes.replaceSubrange((8 + 8 * field) ..< (16 + 8 * field), with: Data(repeating: 0xFF, count: 8))
            Self.exercise(bytes, at: target, seed: UInt64(field))
        }
        // pure garbage behind a valid magic
        for n in [127, 128, 1000, 20_000] {
            var bytes = Data("PMTiles".utf8); bytes.append(3)
            bytes.append(Data((0 ..< n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }))
            Self.exercise(bytes, at: target, seed: UInt64(n))
        }
    }

    @Test func directoryOffsetOverflowIsMalformed() {
        // two entries, the second "right after" one at UInt64.max - 1
        var d = Data()
        d.appendVarint(2)
        d.appendVarint(1); d.appendVarint(1)          // tile ids 1, 2
        d.appendVarint(1); d.appendVarint(1)          // run lengths
        d.appendVarint(10); d.appendVarint(10)        // lengths
        d.appendVarint(UInt64.max - 1); d.appendVarint(0) // offset max-2, then relative
        #expect(throws: PMTilesError.self) { try PMTiles.decodeDirectory(d) }
    }
}
