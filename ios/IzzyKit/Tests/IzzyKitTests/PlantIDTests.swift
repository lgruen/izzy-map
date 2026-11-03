import Foundation
import Testing
@testable import IzzyKit

/// The Swift scorer against the Python reference (`Ship` in
/// pipeline/plantid/build_ship.py; fixtures from `build_ship.py fixture`,
/// numbers only — no photos).
@Suite struct PlantIDScorerTests {
    struct Mini: Decodable {
        struct Out: Decodable {
            var logp: [Double]
            var ladder: Ladder
        }
        var embeddings: [[Float]]
        var locations: [[Double]?]
        var banks: [String: [Out]]
    }

    struct Ladder: Decodable {
        var kind: String
        var label: Int?
        var genus: String?
        var p: Double?
    }

    static let miniDir = TestData.fixtures.appending(path: "plantid-mini")

    static func check(_ answer: PlantIDResult.Answer, _ want: Ladder, labels: [PlantIDLabel]) {
        switch (answer, want.kind) {
        case let (.species(label, p), "species"):
            #expect(label == want.label)
            #expect(abs(p - want.p!) < 1e-4)
        case let (.genus(name, p), "genus"):
            #expect(name == want.genus)
            #expect(abs(p - want.p!) < 1e-4)
        case (.notSure, "notSure"):
            break
        default:
            Issue.record("ladder \(answer) ≠ \(want.kind) \(want.label.map { labels[$0].name } ?? want.genus ?? "")")
        }
    }

    @Test(arguments: ["bank-int8.bin", "bank-fp16w.bin", "bank-none.bin"])
    func miniModelMatchesPython(bank: String) throws {
        let mini: Mini = try TestData.fixture("plantid-mini.json")
        let scorer = try PlantIDScorer(directory: Self.miniDir, bank: bank)
        #expect(scorer.labels.count == 6 && scorer.dimension == 8)
        for (i, (e, loc)) in zip(mini.embeddings, mini.locations).enumerated() {
            let want = mini.banks[bank]![i]
            let location = loc.map { GeoPoint(longitude: $0[1], latitude: $0[0]) }
            let got = scorer.logProbabilities(embedding: e, location: location)
            let worst = zip(got, want.logp).map { abs($0 - $1) }.max()!
            #expect(worst < 1e-4, "case \(i): max |Δ log p| \(worst)")
            // identify() drops a location the grid doesn't reach (the third
            // point, ~160 km from the synthetic records): Ship would apply
            // the frequency-only prior there, so only compare the others
            let result = scorer.identify(embedding: e, location: location)
            let covered = location.map { scorer.usesLocation($0) } ?? false
            #expect(result.usedLocation == covered)
            if location == nil || covered { Self.check(result.answer, want.ladder, labels: scorer.labels) }
        }
    }

    @Test func resultShape() throws {
        let mini: Mini = try TestData.fixture("plantid-mini.json")
        let scorer = try PlantIDScorer(directory: Self.miniDir)
        let r = scorer.identify(embedding: mini.embeddings[0], location: GeoPoint(longitude: 147.33, latitude: -42.88))
        #expect(r.candidates.count == 5)
        #expect(zip(r.candidates, r.candidates.dropFirst()).allSatisfy { $0.p >= $1.p })
        // genus shares sum their species and stay within [0, 1]
        for g in r.genera {
            #expect(g.p <= 1 + 1e-9)
            #expect(g.species.reduce(0) { $0 + $1.p } <= g.p + 1e-9)
        }
        // the synthetic prior's records sit around Hobart; none of the last label
        #expect(r.candidates.contains { $0.nearbyRecords > 0 })
        #expect(r.candidates.first { $0.label == 5 }?.nearbyRecords ?? 0 == 0)
        // a point far beyond the grid: the location is dropped, not used as a frequency prior
        let far = scorer.identify(embedding: mini.embeddings[0], location: GeoPoint(longitude: 151.2, latitude: -33.9))
        #expect(!far.usedLocation)
        #expect(far.candidates.allSatisfy { $0.nearbyRecords == 0 })
        let none = scorer.identify(embedding: mini.embeddings[0], location: nil)
        #expect(far.candidates.map(\.label) == none.candidates.map(\.label))
    }

    @Test func topKMatchesSort() {
        var rng = SystemRandomNumberGenerator()
        let v = (0 ..< 5000).map { _ in Float.random(in: -1 ... 1, using: &rng) }
        let top = PlantIDBank.top(v, 50)
        let want = v.enumerated().sorted { $0.element > $1.element }.prefix(50)
        #expect(top.map(\.1) == want.map(\.offset))
    }

    @Test func malformedFilesThrow() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "plantid-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["head.bin", "bank-int8.bin", "prior.bin", "labels.json"] {
            try FileManager.default.copyItem(at: Self.miniDir.appending(path: f), to: dir.appending(path: f))
        }
        _ = try PlantIDScorer(directory: dir)
        // truncate the bank: its arrays no longer fit
        let bank = dir.appending(path: "bank-int8.bin")
        let data = try Data(contentsOf: bank)
        try data.prefix(data.count - 200).write(to: bank)
        #expect(throws: PlantIDError.self) { try PlantIDScorer(directory: dir) }
        try Data("nope".utf8).write(to: bank)
        #expect(throws: PlantIDError.self) { try PlantIDScorer(directory: dir) }
    }

    // MARK: The shipped files (local only: pipeline/cache is gitignored)

    struct Real: Decodable {
        struct Case: Decodable {
            var embedding: String
            var location: [Double]?
            var top: [[Double]]
            var ladder: Ladder
        }
        var files: [String: String]
        var cases: [Case]
    }

    static let ship = TestData.package.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "pipeline/cache/plantid/ship")
    static var haveShip: Bool {
        FileManager.default.fileExists(atPath: ship.appending(path: "bank-int8.bin").path(percentEncoded: false))
    }

    /// 50 test photos' w8 Core ML embeddings through the shipped head,
    /// int8 bank and prior: top 10 log p within 1e-4 of Python, same ladder.
    @Test(.enabled(if: haveShip, "needs pipeline/cache/plantid/ship (build_ship.py data)"))
    func shippedFilesMatchPython() throws {
        let real: Real = try TestData.fixture("plantid-real.json")
        let start = ContinuousClock.now
        let scorer = try PlantIDScorer(directory: Self.ship)
        let loaded = start.duration(to: .now)
        #expect(scorer.labels.count == 2675 && scorer.dimension == 1024)
        var worst = 0.0
        let t0 = ContinuousClock.now
        for (i, c) in real.cases.enumerated() {
            let e: [Float] = Data(base64Encoded: c.embedding)!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let loc = c.location.map { GeoPoint(longitude: $0[1], latitude: $0[0]) }
            let got = scorer.logProbabilities(embedding: e, location: loc)
            for pair in c.top {
                let d = abs(got[Int(pair[0])] - pair[1])
                worst = max(worst, d)
                #expect(d < 1e-4, "case \(i) label \(Int(pair[0])): \(got[Int(pair[0])]) vs \(pair[1])")
            }
            let order = got.indices.sorted { got[$0] > got[$1] }
            #expect(order[0] == Int(c.top[0][0]), "case \(i) top-1")
            Self.check(scorer.identify(embedding: e, location: loc).answer, c.ladder, labels: scorer.labels)
        }
        print("PlantID real: loaded in \(loaded), \(real.cases.count) photos scored in \(t0.duration(to: .now)), max |Δ log p| = \(worst)")
    }
}

@Suite struct PlantIDPreprocessTests {
    struct Fixture: Decodable {
        struct Case: Decodable { var crop: [Int]? }
        var source: [Int]
        var cases: [Case]
        var tensor_samples: [[Double]]
    }

    /// build_ship.synthetic_rgb: the same bytes, no photo.
    static func synthetic(_ w: Int, _ h: Int) -> RGBImage {
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 3
                px[i] = UInt8((x * 7 + y * 3) & 255)
                px[i + 1] = UInt8((x * y + 5 * x) & 255)
                px[i + 2] = UInt8((((x ^ y) * 9) + 40) & 255)
            }
        }
        return RGBImage(width: w, height: h, pixels: px)
    }

    /// Pillow's bicubic resize + centre crop, byte for byte.
    @Test func resizeCropMatchesPillow() throws {
        let f: Fixture = try TestData.fixture("plantid-preprocess.json")
        let want = try Data(contentsOf: TestData.fixtures.appending(path: "plantid-preprocess.bin"))
        let src = Self.synthetic(f.source[0], f.source[1])
        let n = 224 * 224 * 3
        for (i, c) in f.cases.enumerated() {
            let img = c.crop.map { src.cropped(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) } ?? src
            let got = PlantIDPreprocess.resizeCrop(img)
            #expect(got.width == 224 && got.height == 224)
            let expected = [UInt8](want[i * n ..< (i + 1) * n])
            let diff = zip(got.pixels, expected).filter { $0 != $1 }.count
            #expect(diff == 0, "case \(i): \(diff) of \(n) bytes differ from Pillow")
        }
        // normalisation: channels first, CLIP mean/std
        let t = PlantIDPreprocess.tensor(src)
        #expect(t.count == 3 * 224 * 224)
        for s in f.tensor_samples {
            let (c, y, x) = (Int(s[0]), Int(s[1]), Int(s[2]))
            #expect(abs(Double(t[c * 224 * 224 + y * 224 + x]) - s[3]) < 1e-6)
        }
    }

    @Test func squareInputPassesThrough() {
        let img = Self.synthetic(224, 224)
        #expect(PlantIDPreprocess.resizeCrop(img) == img)
    }
}
