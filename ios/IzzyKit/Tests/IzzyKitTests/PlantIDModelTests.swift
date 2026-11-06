import Foundation
import Testing
@testable import IzzyKit

/// The final configuration's Swift scorer (PlantIDModel: two
/// multi-prototype heads, the adaptive prior, the Tasmania-box bank)
/// against the Python reference `V3Ship` (pipeline/plantid/build_ship.py;
/// fixtures from `build_ship.py fixture`, numbers only — no photos).
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
            /// No location, scored with the no_location switch at "tasmania".
            var logp_as_tasmania: [Double]?
        }
        struct Alt: Decodable { var image_floor: Double; var congener_ratio: Double }
        var ladder_alt: Alt
        /// V3Ship.head_logits of each case's embedding (the heads' pooled mean).
        var head_logits: [[Double]]
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
        let mini: Mini = try TestData.fixture("plantid-v3-mini.json")
        let model = try PlantIDModel(directory: Self.miniDir)
        #expect(model.labels.count == 9 && model.dimension == 8)
        #expect(model.labels[8].mergedInto == 0 && model.labels[1].common == "second alpha" && model.labels[0].ship == 3)
        #expect(model.heads.count == 2 && model.heads.map(\.poolTemperature) == [2.0, 3.5])
        #expect(model.prior.isAdaptive && !model.parameters.noLocationAsTasmania)
        for (i, c) in mini.cases.enumerated() {
            // the pooled multi-prototype heads alone (K 1–4, two pool temperatures)
            func unit(_ v: [Float]) -> [Float] {
                let n = Float(sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) }))
                return v.map { $0 / n }
            }
            let q = unit(zip(unit(c.embedding), model.centre).map { $0 - $1 })
            let hl = model.headLogits(q)
            let worstHead = zip(hl, mini.head_logits[i]).filter { $1 > -1e3 }.map { abs($0 - $1) }.max()!
            #expect(worstHead < 1e-4, "case \(i): max |Δ head logit| \(worstHead)")
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
            // the σ the prior used is the point's cell's (the mini raster's stripes), none without a place
            let want = loc.flatMap { model.place($0) }.flatMap { model.prior.kernel(latitude: $0.latitude, longitude: $0.longitude, fixed: nil)?.sigmaKm }
            #expect(r.priorSigmaKm == want && (loc == nil) == (want == nil), "case \(i) σ")
        }
    }

    /// The image floor and the close-congener rule (off in the shipped
    /// ladder) read like Python's when switched on.
    /// The no_location switch: "tasmania" puts a photo without a location
    /// on the Tasmania-box path (bank term on, prior = the frequency).
    @Test func noLocationSwitchMatchesPython() throws {
        let mini: Mini = try TestData.fixture("plantid-v3-mini.json")
        let model = try PlantIDModel(directory: Self.miniDir)
        model.parameters.noLocationAsTasmania = true
        var n = 0
        for (i, c) in mini.cases.enumerated() {
            guard let want = c.logp_as_tasmania else { continue }
            let (logp, _, tas) = model.scores(embedding: c.embedding, location: nil)
            #expect(tas, "case \(i)")
            let worst = zip(logp, want).filter { $1 > -50 }.map { abs($0 - $1) }.max()!
            #expect(worst < 1e-4, "case \(i): max |Δ log p| \(worst)")
            #expect(model.identify(embedding: c.embedding, location: nil).scope == .tasmania)
            n += 1
        }
        #expect(n >= 2)
        // a location far from the grid isn't "no location": no bank
        #expect(model.identify(embedding: mini.cases[0].embedding, location: GeoPoint(longitude: 10, latitude: 50)).scope == .australia)
    }

    @Test func ladderRulesMatchPython() throws {
        let mini: Mini = try TestData.fixture("plantid-v3-mini.json")
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
    /// its records; a folder without the v3 files isn't a model.
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
        #expect(r.nearbySpecies == 1 && r.priorSigmaKm == 10)
        // no records around the place: nothing "recorded nearby"
        let far = m.identify(embedding: [1, 0.05, 0.05], location: GeoPoint(longitude: 147.33, latitude: -42.6))
        #expect(far.nearbySpecies == 0, "usedLocation \(far.usedLocation)")
        let g = m.identify(embedding: [1, 1, 0.9], location: nil)
        guard case let .genus(name, _) = g.answer else { Issue.record("genus expected: \(g.answer)"); return }
        #expect(name == "Alpha" && g.genusSpecies.count == 2 && !g.usedLocation && g.nearbySpecies == 0)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "plantid-v3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(!PlantIDModel.available(in: tmp))
        #expect(throws: (any Error).self) { try PlantIDModel(directory: tmp) }
    }

    @Test func malformedHeadThrows() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "plantid-v3-bad-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.miniDir, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // a bank is not a v3 head
        try FileManager.default.removeItem(at: tmp.appending(path: "v3-head.bin"))
        try FileManager.default.copyItem(at: tmp.appending(path: "bank-int8.bin"), to: tmp.appending(path: "v3-head.bin"))
        #expect(throws: PlantIDError.self) { try PlantIDModel(directory: tmp) }
        // nor is a prior without its σ raster (a v3 head over a bank file)
        try FileManager.default.removeItem(at: tmp.appending(path: "v3-head.bin"))
        try FileManager.default.copyItem(at: Self.miniDir.appending(path: "v3-head.bin"), to: tmp.appending(path: "v3-head.bin"))
        try FileManager.default.removeItem(at: tmp.appending(path: "v3-prior.bin"))
        try FileManager.default.copyItem(at: tmp.appending(path: "bank-int8.bin"), to: tmp.appending(path: "v3-prior.bin"))
        #expect(throws: PlantIDError.self) { try PlantIDModel(directory: tmp) }
    }

    /// 50 test photos' w8 Core ML embeddings (Tasmania, mainland,
    /// eucalypts, some without a location) through the shipped v3 files:
    /// top 10 log p within 2e-3 of Python, same top-1, same ladder.
    @Test(.enabled(if: haveShip, "needs pipeline/cache/plantid/ship (build_ship.py v3)"))
    func shippedFilesMatchPython() throws {
        let real: Real = try TestData.fixture("plantid-v3-real.json")
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
        print("PlantID v3 real: loaded in \(loaded), per photo median \(sorted[sorted.count / 2]), max \(sorted.last!), max |Δ log p| = \(worst)")
    }
}
