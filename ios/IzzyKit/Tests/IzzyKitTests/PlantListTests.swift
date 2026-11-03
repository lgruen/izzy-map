import Foundation
import Testing
@testable import IzzyKit

/// The plant lists against the web app's fixtures (app/tests/fixtures/
/// plants_test.json + records_test.json at 04ea5d9, copied to Fixtures/),
/// with the expectations its Playwright plants tests pinned.
@Suite struct PlantListTests {
    let catalog: PlantCatalog
    /// The web test's tap point: rows 107–109 × cols 373–375 of the grid.
    static let lat = -44.0 + 1.08, lon = 143.5 + 3.74

    init() throws {
        let plants = try TestData.fixture("plants_test.json", as: PlantsFile.self)
        let records = try TestData.fixture("records_test.json", as: RecordsFile.self)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: TestData.fixtures.appending(path: "records_test.json"))) as! [String: Any]
        let cells = raw["nearbyCells"] as! [[String: Any]]
        let nlon = records.grid.nlon
        let encoded: [(UInt32, [(UInt16, UInt16)])] = cells.map { c in
            let id = UInt32((c["row"] as! Int) * nlon + (c["col"] as! Int))
            let pairs = (c["pairs"] as! [[Int]]).map { (UInt16($0[0]), UInt16($0[1])) }
            return (id, pairs)
        }.sorted { $0.0 < $1.0 }
        catalog = PlantCatalog(plants: plants, records: records, grid: try NearbyGrid(data: Self.nby1(encoded)))
    }

    /// Encodes cells as NBY1 (format in NearbyGrid).
    static func nby1(_ cells: [(UInt32, [(UInt16, UInt16)])]) -> Data {
        var words: [UInt32] = [0x4E42_5931, UInt32(cells.count)]
        words += cells.map(\.0)
        var offset: UInt32 = 0
        for c in cells { words.append(offset); offset += UInt32(c.1.count) }
        words.append(offset)
        for c in cells { for (s, n) in c.1 { words.append(UInt32(s) | UInt32(n) << 16) } }
        return words.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func summaryCountsMatchTheWebCard() {
        let lists = catalog.cardLists(code: "@code", latitude: Self.lat, longitude: Self.lon)
        // web: "<n> named · 3 in records · 3 nearby" (the nonexistent C1 species is skipped)
        #expect(lists.named.count == 9)
        #expect(lists.summary == "9 named · 3 in records · 3 nearby")
        #expect(lists.often.sites == 250)
        #expect(!lists.often.isTally)
        #expect(lists.often.entries.map(\.sites) == [40, 12, 3])
        #expect(!lists.isEmpty)
    }

    @Test func namedPicksThePhotographedProfileAndOneGroupEntry() throws {
        let named = catalog.named("@code")
        let acacia = try #require(named.first { $0.key == "Acacia dealbata" })
        #expect(acacia.plant.id == 102)  // the profile WITH photos
        #expect(acacia.plant.subline == "silver wattle · Tree, Shrub")
        let group = try #require(named.first { $0.group != nil }?.group)
        #expect(group.key == "Leptecophylla juniperina")
        #expect(group.common == "pinkberry")
        #expect(group.size == 5)
        #expect(group.members.count == 4)  // pogonocalyx has no profile
        // the face is the first member with a photo
        #expect(named.first { $0.group != nil }?.plant.name == "Leptecophylla divaricata")
    }

    @Test func nearbySumsTheThreeByThreeWindow() {
        let near = catalog.nearby(latitude: Self.lat, longitude: Self.lon)
        #expect(near.entries.map(\.key) == ["Acacia dealbata", "Leptecophylla divaricata", "Banksia marginata"])
        #expect(near.entries.map(\.sites) == [5, 2, 1])
        #expect(near.shownTotal == 8)  // "3 species, 8 site records"
        #expect(near.sites["Correa reflexa"] == nil)  // col 380 is outside the window
        #expect(near.total == 15)  // incl. the species without a profile
    }

    @Test func groupListOrdersByLocalEvidence() throws {
        let group = try #require(catalog.group("Leptecophylla juniperina"))
        let near = catalog.nearby(latitude: Self.lat, longitude: Self.lon)
        let s = catalog.groupSections(group, code: "@code", nearby: near)
        #expect(s.here.map(\.key) == ["Leptecophylla parvifolia", "Leptecophylla juniperina"])
        #expect(s.here.map(\.sites) == [3, 1])
        #expect(s.near.map(\.key) == ["Leptecophylla divaricata"])
        #expect(s.near.map(\.sites) == [2])
        #expect(s.rest.map(\.key) == ["Leptecophylla oxycedrus"])
        #expect(s.rest.allSatisfy { $0.sites == nil })
        // no community, no point: everything A–Z under "Species in the group"
        let bare = catalog.groupSections(group, code: nil, nearby: nil)
        #expect(bare.here.isEmpty && bare.near.isEmpty)
        #expect(bare.rest.map(\.key) == bare.rest.map(\.key).sorted())
    }

    @Test func noRecordsNearAndNoEntries() {
        let far = catalog.cardLists(code: "@code", latitude: -40.0, longitude: 145.0)
        #expect(far.nearby?.entries.isEmpty == true)
        #expect(far.summary == "9 named · 3 in records")
        let none = catalog.cardLists(code: "WATER", latitude: -40.0, longitude: 145.0)
        #expect(none.isEmpty)
        #expect(none.summary.isEmpty)
    }

    @Test func facesPreferPhotographedPlantsInCharacteristicOrder() {
        let lists = catalog.cardLists(code: "@code", latitude: Self.lat, longitude: Self.lon)
        let faces = lists.faces(limit: 5)
        #expect(faces.count == 5)
        // C1 order is Banksia (photo), Acacia (photo), …: photographed first
        #expect(faces.prefix(2).map(\.key) == ["Banksia marginata", "Acacia dealbata"])
        #expect(faces.prefix(3).allSatisfy { !$0.plant.photos.isEmpty })
        #expect(Set(faces.map(\.key)).count == faces.count)
    }

    @Test func distributionInvertsTheGrid() {
        let cells = catalog.distribution(of: "Acacia dealbata")
        #expect(cells.count == 2)
        #expect(cells.map(\.sites) == [2, 3])
        #expect(abs(cells[0].latitude - (-44 + 1.08)) < 1e-9)
        #expect(abs(cells[0].longitude - (143.5 + 3.73)) < 1e-9)
        #expect(catalog.distribution(of: "No such plant").isEmpty)
    }

    @Test func realDataDistributionIsInsideTasmania() throws {
        let real = try TestData.catalog()
        let cells = real.distribution(of: "Nothofagus cunninghamii")
        #expect(cells.count > 500)
        #expect(cells.allSatisfy { (-44 ... -39.2).contains($0.latitude) && (143.5 ... 149).contains($0.longitude) })
    }
}

@Suite struct PlantFactTests {
    @Test func heightsParse() {
        #expect(HeightRange("5 – 20") == HeightRange(min: 5, max: 20))
        #expect(HeightRange("0.04 – 0.25")?.max == 0.25)
        #expect(HeightRange("3")?.text == "3\u{00A0}m")
        #expect(HeightRange("0.3 – 1")?.text == "0.3–1\u{00A0}m")
        #expect(HeightRange("2-4") == HeightRange(min: 2, max: 4))
        for bad in [nil, "", "tall", "0 – 2", "1 – 2 – 3"] as [String?] { #expect(HeightRange(bad) == nil, "\(bad ?? "nil")") }
    }

    @Test func everyRealHeightAndFormParses() throws {
        let plants = try TestData.catalog().plants
        for p in plants {
            if p.height != nil { #expect(p.heightRange != nil, "\(p.name): \(p.height!)") }
            #expect(p.growthForms.count == p.forms.count, "\(p.name): \(p.forms)")
            if let s = p.status { #expect(PlantStatus(rawValue: s) != nil, "\(s)") }
        }
    }

    @Test func floweringStartsInJanuaryAndWraps() {
        // decided by the user, 2026-11-03 (DESIGN.md §7 q2)
        #expect(Flowering.startMonth == 1)
        #expect(Flowering.order() == Array(1 ... 12))
        #expect(Flowering.order(start: 9) == [9, 10, 11, 12, 1, 2, 3, 4, 5, 6, 7, 8])
        // a spring-first chart still joins a run across its seam
        #expect(Flowering.runs([8, 9, 10], start: 9) == [[8, 9, 10]])
        #expect(Flowering.runs([12, 1, 2, 5], start: 9) == [[12, 1, 2], [5]])
        #expect(Flowering.runs([9, 10, 11]) == [[9, 10, 11]])
        // August → October runs across the chart's seam
        #expect(Flowering.runs([8, 9, 10]) == [[8, 9, 10]])
        #expect(Flowering.runs([12, 1, 2, 5]) == [[12, 1, 2], [5]])
        #expect(Flowering.spoken([7, 8, 9], now: 8) == "Flowers July to September, in flower now")
        #expect(Flowering.spoken([12, 1, 2, 5]) == "Flowers December to February and May")
        #expect(Flowering.spoken(Array(1 ... 12)) == "Flowers all year")
    }

    @Test func photoURLsAndStoredNames() throws {
        let p = PlantPhoto(path: "2024/03/Acacia_dealbata-flower", ext: "jpe", thumb: "-150x150", large: "-rotated",
                           bytes: 1200, credit: nil)
        #expect(p.thumbURL?.absoluteString == "https://database.understorey-network.org.au/wp-content/uploads/2024/03/Acacia_dealbata-flower-150x150.jpe")
        #expect(p.largeURL?.absoluteString == "https://database.understorey-network.org.au/wp-content/uploads/2024/03/Acacia_dealbata-flower-rotated.jpe")
        #expect(p.storedName == "2024-03-Acacia_dealbata-flower.jpe")
        #expect(p.caption == "Photo: Understorey Network")
        var credited = p
        credited.credit = "Test Photographer – with permission"
        #expect(credited.caption == "Photo: Test Photographer – with permission · Understorey Network")
    }

    @Test func headlineAndProfileURL() throws {
        let plants = try TestData.fixture("plants_test.json", as: PlantsFile.self).plants
        let a = try #require(plants.first { $0.id == 102 })
        #expect(a.headlineCommon == "Silver wattle")
        #expect(a.profileURL?.absoluteString == "https://database.understorey-network.org.au/plant/acacia-dealbata-subsp-dealbata")
    }

    @Test func botanicalNameKeepsRanksUpright() {
        #expect(BotanicalNames.italicRuns(BotanicalNames.species("Acacia dealbata subsp. dealbata")) == ["Acacia", "dealbata", "dealbata"])
    }
}
