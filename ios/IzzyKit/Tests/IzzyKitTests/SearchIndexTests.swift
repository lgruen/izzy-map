import Foundation
import Testing
@testable import IzzyKit

/// The real bundled search files (ios/IzzyMap/Resources/Data/search/), built once per test process.
enum SearchFixture {
    static let dir = TestData.root.appending(path: SearchIndex.File.directory)
    static let gazetteer = Result { try Data(contentsOf: dir.appending(path: SearchIndex.File.gazetteer)) }
    static let addresses = Result { try Data(contentsOf: dir.appending(path: SearchIndex.File.addresses)) }
    private static let built = Result { try SearchIndex(gazetteer: gazetteer.get(), addresses: addresses.get()) }
    static func index() throws -> SearchIndex { try built.get() }

    /// The web tests' map centre: Playwright's fake GPS fix (kunanyi summit area).
    static let gps = GeoPoint(longitude: 147.235, latitude: -42.92)
    static let hobart = GeoPoint(longitude: 147.33, latitude: -42.88)
    static let launceston = GeoPoint(longitude: 147.14, latitude: -41.44)
}

@Suite struct SearchIndexTests {
    @Test func loadsTheBundledFilesOffTheMainThread() async throws {
        let t = ContinuousClock.now
        let idx = try await TestData.data.searchIndex()
        let ms = (ContinuousClock.now - t) / .milliseconds(1)
        print("search index cold load: \(String(format: "%.0f", ms)) ms (\(idx.placeCount) names, \(idx.streetCount) streets)")
        #expect(idx.placeCount > 30_000) // the gazetteer build's tripwires: > 30k rows…
        #expect(idx.streetCount > 13_000) // …and > 13k streets
        #expect(idx.attributions.allSatisfy { $0.contains("theLIST © State of Tasmania (CC BY 3.0 AU)") })
        #expect(idx.built.count == 2)
        #expect(ms < 5_000) // release builds take ~60–80 ms on a Mac; this is the debug-build ceiling
    }

    @Test func aNewerFileVersionIsReportedAsSuch() throws {
        func gaz(_ v: Int) -> Data {
            Data(#"{"version": \#(v), "types": [], "groups": [], "typeGroup": [], "places": [], "munis": [], "rows": []}"#.utf8)
        }
        let addr = Data(#"{"version": 1, "streets": []}"#.utf8)
        #expect(throws: DataError.unsupportedVersion(file: "gazetteer.json", found: 2, supported: 1)) {
            try SearchIndex(gazetteer: gaz(2), addresses: addr)
        }
        // a version-2 file whose shape no longer parses still says "version"
        #expect(throws: DataError.unsupportedVersion(file: "addresses.json", found: 2, supported: 1)) {
            try SearchIndex(gazetteer: gaz(1), addresses: Data(#"{"version": 2, "streets": {"new": "shape"}}"#.utf8))
        }
        #expect(throws: DataError.unsupportedVersion(file: "addresses.json", found: nil, supported: 1)) {
            try SearchIndex(gazetteer: gaz(1), addresses: Data(#"{"streets": []}"#.utf8))
        }
        do {
            _ = try SearchIndex(gazetteer: gaz(3), addresses: addr)
            Issue.record("expected a version error")
        } catch {
            #expect(SearchIndex.failureMessage(for: error) == "Update the app to search")
        }
        let empty = try SearchIndex(gazetteer: gaz(1), addresses: addr)
        #expect(empty.search(query: "hobart").isEmpty)
    }

    @Test func aDamagedFileIsMalformedNotAVersionProblem() throws {
        let bad = Data(#"{"version": 1, "types": ["Road"], "groups": ["Transport"], "typeGroup": [0], "places": [""], "munis": [""], "rows": [["X", 0, 0]]}"#.utf8)
        do {
            _ = try SearchIndex(gazetteer: bad, addresses: nil)
            Issue.record("expected a malformed error")
        } catch let DataError.malformed(file, _) {
            #expect(file == "gazetteer.json")
            #expect(SearchIndex.failureMessage(for: DataError.malformed(file: file, reason: "")).hasPrefix("Place names aren’t available"))
        }
        #expect(throws: DataError.self) { try SearchIndex(gazetteer: Data("{\"version\": 1,".utf8), addresses: nil) }
    }

    @Test func readerHandlesEscapesAndSkipsUnknownKeys() throws {
        let g = Data(#"""
        {"future": {"a": [1, 2.5e3, true, null, "x\"y"]}, "version": 1, "built": "2026-09-12",
         "attribution": "A © B", "types": ["Hill"], "groups": ["Natural Feature"], "typeGroup": [0],
         "places": ["Café Town"], "munis": ["Hobart"], "rows": [["Mount \"Quoted\" 🌲", 0, 0, 0, -4290000, 14730000, [0, 0, 1, 1], "later"]]}
        """#.utf8)
        let idx = try SearchIndex(gazetteer: g, addresses: nil)
        #expect(idx.attributions == ["A © B"])
        let r = try #require(idx.search(query: "quoted").first)
        #expect(r.name == "Mount \"Quoted\" 🌲")
        #expect(r.meta == "Hill · Café Town, Hobart")
        #expect(idx.search(query: "cafe").count == 1) // the place is a context word
        #expect(r.bbox == SearchBBox(west: 147.3, south: -42.9, east: 147.30001, north: -42.89999))
    }

    @Test func keystrokeQueriesAreFast() throws {
        let idx = try SearchFixture.index()
        // what typing "12 elizabeth st hobart" and "kunanyi" sends, keystroke by keystroke
        let typed = ["12 elizabeth st hobart", "kunanyi", "sandy bay rd", "st helens"]
            .flatMap { q in (2...q.count).map { String(q.prefix($0)) } }
        let t = ContinuousClock.now
        var worst = Duration.zero
        for q in typed {
            let s = ContinuousClock.now
            _ = idx.search(query: q, near: SearchFixture.gps)
            worst = max(worst, ContinuousClock.now - s)
        }
        let mean = (ContinuousClock.now - t) / typed.count / .milliseconds(1)
        print("search per keystroke: mean \(String(format: "%.2f", mean)) ms, worst \(worst) over \(typed.count) queries")
        #expect(mean < 250) // release builds: well under 1 ms; this is the debug-build ceiling
    }
}
