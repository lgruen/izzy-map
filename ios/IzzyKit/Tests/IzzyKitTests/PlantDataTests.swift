import Foundation
import Testing
@testable import IzzyKit

@Suite struct PlantDataTests {
    let catalog: PlantCatalog
    init() throws { catalog = try TestData.catalog() }

    @Test func shapesAndTripwires() {
        let c = catalog
        #expect(c.plants.count >= 1_800)
        #expect(c.plants.filter { !$0.photos.isEmpty }.count >= 650)
        #expect(c.records.species.count >= 1_600 && c.records.species.count <= 1_900)
        #expect(c.records.grid == RecordsFile.Grid(step: 0.01, lat0: -44, lon0: 143.5, nlon: 551))
        #expect(c.grid.cellCount == DataTableTests.web.nearbyCells)
        #expect(c.records.sources?.records ?? 0 > 750_000)
        #expect(c.plants.allSatisfy { $0.flowering.allSatisfy { (1 ... 12).contains($0) } })
    }

    // A lat/lon or CRS slip in build_records scrambles this first (CLAUDE.md tripwire).
    @Test func myrtleBeechTopsRainforest() {
        let top5 = catalog.often("RMT").entries.prefix(5).map(\.key)
        #expect(top5.contains("Nothofagus cunninghamii"))
        #expect(!catalog.often("RMT").isTally)
    }

    @Test func sparseCommunitiesAreTallies() {
        let tallies = catalog.records.communities.keys.filter { catalog.often($0).isTally }
        #expect(tallies.count == 15)  // 2026-10-25 build: "15 of them plain tallies"
        for code in tallies {
            let rows = catalog.records.communities[code]!
            #expect(rows.allSatisfy { $0.score == nil })
        }
        #expect(catalog.often("NOPE") == PlantCatalog.Often(entries: [], isTally: false, sites: nil))
    }

    @Test func namedListsAndTheSplitGroup() throws {
        let aap = catalog.named("AAP")
        #expect(!aap.isEmpty)
        #expect(aap.first?.key == "Drosera arcturi")
        // every entry resolves to a profile; group entries carry their members
        let codes = Set(catalog.records.communities.keys)
        var sawGroup = false
        for code in codes {
            for e in catalog.named(code) {
                if let g = e.group {
                    sawGroup = true
                    #expect(g.key == "Leptecophylla juniperina")
                    #expect(g.common == "pinkberry")
                    #expect(g.size == 6)
                    #expect(!g.members.isEmpty)
                    // the face is the first member with a photo, else the first member
                    let face = g.members.first { !$0.plant.photos.isEmpty } ?? g.members[0]
                    #expect(e.plant == face.plant)
                } else {
                    #expect(e.plant.species == e.key)
                }
            }
        }
        #expect(sawGroup)
    }

    @Test func profilePickPrefersPhotosThenOwnName() {
        var bySpecies: [String: [Plant]] = [:]
        for p in catalog.plants { if let s = p.species { bySpecies[s, default: []].append(p) } }
        for (key, list) in bySpecies where list.count > 1 {
            let picked = catalog.plant(for: key)!
            if list.contains(where: { !$0.photos.isEmpty }) { #expect(!picked.photos.isEmpty, "\(key)") }
        }
    }

    @Test func communitySitesIncludesUncappedMembers() {
        guard let (code, rows) = catalog.records.members?.first(where: { !$0.value.isEmpty }) else { return }
        let sites = catalog.communitySites(code)
        for r in rows { #expect(sites[catalog.records.species[r.species]] == r.sites) }
    }

    @Test(arguments: DataTableTests.web.nearby.map(\.name))
    func nearbyMatchesWebSitesAround(_ name: String) throws {
        let f = try #require(DataTableTests.web.nearby.first { $0.name == name })
        let got = catalog.grid.sitesAround(latitude: f.lat, longitude: f.lon, grid: catalog.records.grid)
        let want = Dictionary(uniqueKeysWithValues: f.sites.map { (Int($0.key)!, $0.value) })
        #expect(got == want)
        // and the list built on it
        let near = catalog.nearby(latitude: f.lat, longitude: f.lon)
        #expect(near.total == want.values.reduce(0, +))
        #expect(near.shownTotal == near.entries.compactMap(\.sites).reduce(0, +))
        #expect(near.entries.allSatisfy { catalog.plant(for: $0.key) != nil })
        for (a, b) in zip(near.entries, near.entries.dropFirst()) {
            #expect(a.sites! > b.sites! || (a.sites == b.sites && a.key < b.key))
        }
    }

    @Test func sitesAroundTreatsNonFinitePointsAsOffTheGrid() {
        let g = catalog.records.grid
        for (lat, lon) in [(Double.nan, 147.0), (-42.0, .nan), (.infinity, 147.0), (-42.0, -.infinity),
                           (1e300, 147.0), (-42.0, -1e300), (-1e18, 1e18)] {
            #expect(catalog.grid.sitesAround(latitude: lat, longitude: lon, grid: g).isEmpty, "\(lat), \(lon)")
        }
    }

    @Test func versionAndMagicAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "izzykit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = BundledData(root: dir)
        // same shape, newer version
        var plants = try JSONSerialization.jsonObject(with: Data(contentsOf: TestData.root.appending(path: "plants.json"))) as! [String: Any]
        plants["version"] = 2
        try JSONSerialization.data(withJSONObject: plants).write(to: dir.appending(path: "plants.json"))
        #expect(throws: DataError.unsupportedVersion(file: "plants.json", found: 2, supported: 1)) { try bad.plants() }
        // a v2 with a different shape still says "version", not "malformed"
        try Data(#"{"version":2,"species":{}}"#.utf8).write(to: dir.appending(path: "records.json"))
        #expect(throws: DataError.unsupportedVersion(file: "records.json", found: 2, supported: 1)) { try bad.records() }
        // v1 but broken -> malformed
        try Data(#"{"version":1}"#.utf8).write(to: dir.appending(path: "records.json"))
        #expect { try bad.records() } throws: { e in
            if case .malformed("records.json", _) = e as? DataError { true } else { false }
        }
        // nearby.bin: magic and truncation
        try Data([0x31, 0x59, 0x42, 0x4F, 0, 0, 0, 0]).write(to: dir.appending(path: "nearby.bin"))
        #expect(throws: DataError.malformed(file: "nearby.bin", reason: "bad magic")) { try bad.nearbyGrid() }
        let real = try Data(contentsOf: TestData.root.appending(path: "nearby.bin"))
        try real.prefix(real.count - 4).write(to: dir.appending(path: "nearby.bin"))
        #expect(throws: DataError.malformed(file: "nearby.bin", reason: "truncated")) { try bad.nearbyGrid() }
    }

    @Test func decodePerformance() throws {
        let clock = ContinuousClock()
        var c: PlantCatalog?
        let t = try clock.measure { c = try TestData.data.plantCatalog() }
        print("plants.json + records.json + nearby.bin → PlantCatalog: \(t)")
        #expect(c != nil)
        #expect(t < .seconds(3))  // generous: debug build; target < 0.5 s in release
    }
}
