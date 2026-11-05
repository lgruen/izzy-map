import Foundation
import Testing
@testable import IzzyKit

/// The single model's Swift scorer (PlantIDModel) against the Python
/// reference `V2Ship` (pipeline/plantid/build_ship.py; fixtures from
/// `build_ship.py fixture`, numbers only — no photos).
@Suite struct PlantIDModelTests {
    struct Ladder: Decodable {
        var kind: String
        var label: Int?
        var genus: String?
        var p: Double?
        var top: [Int]?
    }

    struct Mini: Decodable {
        struct Case: Decodable {
            var embedding: [Float]
            var location: [Double]?
            var path: String
            var logp: [Double]
            var image: [Double]
            var ladder: Ladder
            var ladder_alt: Ladder
        }
        struct Alt: Decodable { var image_floor: Double; var congener_ratio: Double }
        var ladder_alt: Alt
        var cases: [Case]
    }

    struct Real: Decodable {
        struct Case: Decodable {
            var set: String
            var embedding: String
            var location: [Double]?
            var path: String
            var top: [[Double]]
            var ladder: Ladder
        }
        var files: [String: String]
        var cases: [Case]
    }

    static let miniDir = TestData.fixtures.appending(path: "plantid-mini")
    static let ship = TestData.package.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "pipeline/cache/plantid/ship")
    static var haveShip: Bool { PlantIDModel.available(in: ship) }

    static func point(_ l: [Double]?) -> GeoPoint? { l.map { GeoPoint(longitude: $0[1], latitude: $0[0]) } }

    /// The ladder's verdict, unless p sits within `margin` of a threshold
    /// (float noise could flip it either way).
    static func check(_ r: PlantIDResult, _ want: Ladder, _ i: Int) {
        switch (r.answer, want.kind) {
        case let (.species(label, p), "species"):
            #expect(label == want.label, "case \(i)")
            #expect(abs(p - want.p!) < 2e-4, "case \(i)")
        case let (.genus(name, p), "genus"):
            #expect(name == want.genus, "case \(i)")
            #expect(abs(p - want.p!) < 2e-4, "case \(i)")
            #expect(r.genusSpecies.map(\.label) == want.top, "case \(i) genus top 3")
        case (.notSure, "notSure"):
            break
        default:
            Issue.record("case \(i): ladder \(r.answer) ≠ \(want.kind) \(want.label.map(String.init) ?? want.genus ?? "")")
        }
    }

    @Test func miniModelMatchesPython() throws {
        let mini: Mini = try TestData.fixture("plantid-v2-mini.json")
        let model = try PlantIDModel(directory: Self.miniDir)
        #expect(model.labels.count == 9 && model.dimension == 8)
        #expect(model.labels[8].mergedInto == 0 && model.labels[1].common == "second alpha" && model.labels[0].ship == 3)
        for (i, c) in mini.cases.enumerated() {
            let loc = Self.point(c.location)
            let (logp, image, tas) = model.scores(embedding: c.embedding, location: model.place(loc))
            #expect(tas == (c.path == "tasmania"), "case \(i) path")
            let worst = zip(logp, c.logp).filter { $1 > -50 }.map { abs($0 - $1) }.max()!
            let worstImg = zip(image, c.image).filter { $1 > -50 }.map { abs($0 - $1) }.max()!
            #expect(worst < 1e-4 && worstImg < 1e-4, "case \(i): max |Δ log p| \(worst), image \(worstImg)")
            // the merged twin is never a candidate
            #expect(exp(logp[8]) < 1e-12)
            let r = model.identify(embedding: c.embedding, location: loc)
            #expect(r.scope == (tas ? .tasmania : .australia))
            Self.check(r, c.ladder, i)
            #expect(r.candidates.count == 5 && r.candidates.allSatisfy { $0.threshold > 0 })
        }
    }

    /// The image floor and the close-congener rule (off in the shipped
    /// ladder) read like Python's when switched on.
    @Test func ladderRulesMatchPython() throws {
        let mini: Mini = try TestData.fixture("plantid-v2-mini.json")
        let model = try PlantIDModel(directory: Self.miniDir)
        var lad = model.parameters.ladder
        lad.imageFloor = mini.ladder_alt.image_floor
        lad.congenerRatio = mini.ladder_alt.congener_ratio
        model.parameters.ladder = lad
        let alt = model
        for (i, c) in mini.cases.enumerated() {
            Self.check(alt.identify(embedding: c.embedding, location: Self.point(c.location)), c.ladder_alt, i)
        }
    }

    @Test func bucketsFollowTheEdges() {
        let l = PlantIDLadder(species: [0.6, 0.5, 0.45, 0.75], bucketEdges: [0, 10, 50], genus: 0.55)
        #expect(l.speciesThreshold(photos: 0) == 0.6)
        #expect(l.speciesThreshold(photos: 1) == 0.5 && l.speciesThreshold(photos: 9) == 0.5)
        #expect(l.speciesThreshold(photos: 10) == 0.45 && l.speciesThreshold(photos: 49) == 0.45)
        #expect(l.speciesThreshold(photos: 50) == 0.75 && l.speciesThreshold(photos: 3000) == 0.75)
        #expect(PlantIDLadder.simple.speciesThreshold(photos: 7) == 0.5)
    }

    /// A synthetic model (the DEBUG fake's kind) answers from its head and
    /// its records; a folder without the v2 files isn't a model.
    @Test func syntheticModelAndMissingFiles() throws {
        let labels = [PlantIDLabel(name: "Alpha prima", genus: "Alpha"), PlantIDLabel(name: "Alpha secunda", genus: "Alpha"),
                      PlantIDLabel(name: "Beta una", genus: "Beta")]
        var w = [Float](repeating: 0, count: 9)
        for i in 0 ..< 3 { w[i * 3 + i] = 8 }
        let prior = PlantIDDegPrior(records: [(-42.88, 147.33, 1), (-42.881, 147.331, 1)], labels: 3)
        let params = PlantIDModelParameters(temperature: 1, lam: 0.1, prior: .init(transform: .log1p, sigmaKm: 10, alpha: 8),
                                            ladder: .simple)
        let m = PlantIDModel(labels: labels, weight: w, centre: [0, 0, 0], parameters: params, prior: prior)
        let r = m.identify(embedding: [1, 0.05, 0.05], location: GeoPoint(longitude: 147.33, latitude: -42.88))
        #expect(r.answer == .species(label: 0, p: r.candidates[0].p) && r.usedLocation && r.scope == .australia)
        #expect(r.candidates.first { $0.label == 1 }?.nearbyRecords == 2)
        let g = m.identify(embedding: [1, 1, 0.9], location: nil)
        guard case let .genus(name, _) = g.answer else { Issue.record("genus expected: \(g.answer)"); return }
        #expect(name == "Alpha" && g.genusSpecies.count == 2 && !g.usedLocation)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "plantid-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(!PlantIDModel.available(in: tmp))
        #expect(throws: (any Error).self) { try PlantIDModel(directory: tmp) }
    }

    @Test func malformedHeadThrows() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "plantid-v2-bad-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.miniDir, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // a bank is not a v2 head
        try FileManager.default.removeItem(at: tmp.appending(path: "v2-head.bin"))
        try FileManager.default.copyItem(at: tmp.appending(path: "bank-int8.bin"), to: tmp.appending(path: "v2-head.bin"))
        #expect(throws: PlantIDError.self) { try PlantIDModel(directory: tmp) }
    }

    /// 50 test photos' w8 Core ML embeddings (Tasmania, mainland,
    /// eucalypts, some without a location) through the shipped v2 files:
    /// top 10 log p within 2e-3 of Python, same top-1, same ladder.
    @Test(.enabled(if: haveShip, "needs pipeline/cache/plantid/ship (build_ship.py v2)"))
    func shippedFilesMatchPython() throws {
        let real: Real = try TestData.fixture("plantid-v2-real.json")
        let start = ContinuousClock.now
        let model = try PlantIDModel(directory: Self.ship)
        let loaded = start.duration(to: .now)
        #expect(model.labels.count == 22122 && model.dimension == 1024)
        var worst = 0.0
        var times: [Duration] = []
        for (i, c) in real.cases.enumerated() {
            let e: [Float] = Data(base64Encoded: c.embedding)!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let loc = Self.point(c.location)
            let t = ContinuousClock.now
            let r = model.identify(embedding: e, location: loc)
            times.append(t.duration(to: .now))
            let (logp, _, tas) = model.scores(embedding: e, location: model.place(loc))
            #expect(tas == (c.path == "tasmania"), "case \(i) path")
            for pair in c.top where pair[1] > -12 {
                let d = abs(logp[Int(pair[0])] - pair[1])
                worst = max(worst, d)
                #expect(d < 2e-3, "case \(i) label \(Int(pair[0])): \(logp[Int(pair[0])]) vs \(pair[1])")
            }
            #expect(r.candidates.first?.label == Int(c.top[0][0]), "case \(i) top-1")
            Self.check(r, c.ladder, i)
        }
        let sorted = times.sorted()
        print("PlantID v2 real: loaded in \(loaded), per photo median \(sorted[sorted.count / 2]), max \(sorted.last!), max |Δ log p| = \(worst)")
    }
}
