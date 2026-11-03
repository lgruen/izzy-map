import Foundation
import Testing
@testable import IzzyKit

struct LegendTests {
    /// The curated short names must cover exactly the groups the bundled
    /// tables have — a renamed group would otherwise fall back to truncation
    /// silently (web chips.ts test, carried over).
    @Test func shortNameKeysMatchTheGeneratedGroups() throws {
        let geo = Set(try TestData.data.geologyUnits().values.map(\.group))
        #expect(Set(Legend.geologyShortNames.keys) == geo)
        let pre = Set(try TestData.data.pre1750Units().values.map(\.group))
        #expect(Set(Legend.pre1750ShortNames.keys) == pre)
        // an index label is a short, unique handle
        for table in [Legend.geologyShortNames, Legend.pre1750ShortNames] {
            #expect(Set(table.values).count == table.count, "short names must be unique")
            #expect(table.values.allSatisfy { $0.count <= 11 }, "the section index is a narrow column")
        }
    }

    @Test func vegetationKeyIsElevenGroupsAToZWithSharedFillsBracketed() throws {
        let table = try TestData.data.communities()
        let sections = Legend.vegetation(table)
        #expect(sections.count == 11)
        // every group's codes share one initial: the index letter, unique, A–Z
        let letters = sections.map(\.shortTitle)
        #expect(letters == ["A", "D", "F", "G", "H", "M", "N", "O", "R", "S", "W"])
        for s in sections { #expect(s.runs.flatMap(\.rows).allSatisfy { $0.code.hasPrefix(s.shortTitle) }) }
        #expect(sections.reduce(0) { $0 + $1.count } == table.count)
        // every run is one colour; no colour appears in two runs of a section
        for section in sections {
            #expect(Set(section.runs.map(\.color)).count == section.runs.count)
            for run in section.runs { #expect(run.rows.allSatisfy { $0.color == run.color }) }
        }
        // names lose their "(XXX) " prefix
        let dry = try #require(sections.first { $0.title == "Dry eucalypt forest and woodland" })
        let dob = try #require(dry.runs.flatMap(\.rows).first { $0.code == "DOB" })
        #expect(dob.name == "Eucalyptus obliqua dry forest")
        // DESIGN.md: nine dry-forest codes share #98FE00 → one box
        #expect(dry.runs.contains { $0.rows.count >= 2 })
    }

    @Test func geologyRunsOldestToYoungestWithOtherUnitsLast() throws {
        let table = try TestData.data.geologyUnits()
        let sections = Legend.geology(table)
        #expect(sections.last?.title == Legend.otherGeologyGroup)
        #expect(sections.first?.shortTitle == "Proterozoic")
        let ages = sections.dropLast().map { s in s.runs.flatMap(\.rows).compactMap { table[$0.code]?.maxMa }.max() ?? 0 }
        #expect(ages == ages.sorted(by: >))
        #expect(sections.reduce(0) { $0 + $1.count } == table.count)
    }

    @Test func pre1750FollowsTheNVISOrder() throws {
        let table = try TestData.data.pre1750Units()
        let sections = Legend.pre1750(table)
        #expect(sections.first?.title == "Rainforests and Vine Thickets")
        let groupOrders = sections.map { table[$0.runs[0].rows[0].code]!.groupOrder }
        #expect(groupOrders == groupOrders.sorted())
        for s in sections {
            let orders = s.runs.flatMap(\.rows).map { table[$0.code]!.order }
            #expect(orders == orders.sorted())
        }
    }

    @Test func keyBoxColourIsTheFillAsTheMapShowsIt() throws {
        // DESIGN.md: RPW #3232FE at 0.55 → #8E8EFE
        let c = try #require(MapColour.overWhite("#3232FE", alpha: 0.55))
        #expect(MapColour.hex(c) == "#8E8EFE")
        #expect(MapColour.hex(try #require(MapColour.overWhite("#000000", alpha: 0))) == "#FFFFFF")
        #expect(MapColour.overWhite("nope", alpha: 1) == nil)
    }
}

struct BotanicalNameTests {
    @Test func genusAndEpithetAreItalicTheRestUpright() {
        #expect(BotanicalNames.italicWords("Eucalyptus obliqua dry forest") == ["Eucalyptus", "obliqua"])
        #expect(BotanicalNames.italicWords("Lowland Poa labillardierei grassland") == ["Poa", "labillardierei"])
        #expect(BotanicalNames.italicWords("Highland Poa grassland") == ["Poa"])
        #expect(BotanicalNames.italicWords("Leptospermum forest") == ["Leptospermum"])
        #expect(BotanicalNames.italicWords("Eucalyptus viminalis Furneaux forest and woodland") == ["Eucalyptus", "viminalis"])
        #expect(BotanicalNames.italicWords("Other Acacia forests and woodlands") == ["Acacia"])
        #expect(BotanicalNames.italicWords("Coastal scrub") == [])
        #expect(BotanicalNames.italicWords("Eucalyptus (+/- tall) open forest") == ["Eucalyptus"])
    }

    @Test func punctuationAroundAGenusDoesNotHideIt() {
        // NVIS: "…(including Acacia, Melaleuca and Banksia)"
        let name = "Low closed forest or tall closed shrublands (including Acacia, Melaleuca and Banksia)"
        #expect(BotanicalNames.italicWords(name) == ["Acacia", "Melaleuca", "Banksia"])
        // the brackets and comma stay upright, the text unchanged
        #expect(String(BotanicalNames.attributed(name).characters) == name)
        #expect(BotanicalNames.italicWords("Eucalyptus, Acacia") == ["Eucalyptus", "Acacia"])
        // an epithet never jumps a comma
        #expect(BotanicalNames.italicWords("Acacia, dealbata") == ["Acacia"])
    }

    /// Real register / Understorey Network names (trees.json, plants.json).
    @Test func speciesNamesSetTheRightWordsUpright() {
        func italic(_ name: String) -> [String] { BotanicalNames.italicRuns(BotanicalNames.species(name)) }
        #expect(italic("Eucalyptus globulus subsp. globulus") == ["Eucalyptus", "globulus", "globulus"])
        // informal phrase names after a rank word are upright
        #expect(italic("Acacia sp. Sugarloaf") == ["Acacia"])
        #expect(italic("Astelia sp. Quartzite") == ["Astelia"])
        #expect(italic("Euphrasia gibbsiae subsp. Mt Anne") == ["Euphrasia", "gibbsiae"])
        #expect(italic("Euphrasia collina subsp. Dukes Marshes") == ["Euphrasia", "collina"])
        #expect(italic("Tetratheca sp. Flinders Is.") == ["Tetratheca"])
        #expect(italic("Geranium sp. Pale Pink Flowers") == ["Geranium"])
        // … but an upstream capital on a Latin epithet is still the epithet
        #expect(italic("Epilobium billardiereanum subsp. Intermedium") == ["Epilobium", "billardiereanum", "Intermedium"])
        #expect(italic("Abies pinsapo var Glauca") == ["Abies", "pinsapo", "Glauca"])
        // cultivars upright, in quotes or after cv.
        #expect(italic("Fraxinus angustifolia subsp. Oxycarpa 'Raywood'") == ["Fraxinus", "angustifolia", "Oxycarpa"])
        #expect(italic("Ulmus × hollandica 'Vegeta'") == ["Ulmus", "hollandica"])
        #expect(italic("Prunus serrulata cv. Kanzan") == ["Prunus", "serrulata"])
        // joiners and commas upright between names
        #expect(italic("Cedrus deodara, Cedrus atlantica glauca, Cedrus libani and Cupressus sempervirens")
            == ["Cedrus", "deodara", "Cedrus", "atlantica", "glauca", "Cedrus", "libani", "Cupressus", "sempervirens"])
        let joined = BotanicalNames.species("Cedrus libani and Cupressus sempervirens")
        #expect(String(joined.characters) == "Cedrus libani and Cupressus sempervirens")
        #expect(italic("Quercus robur & Quercus rubra") == ["Quercus", "robur", "Quercus", "rubra"])
        #expect(italic("Pinus radiata (Monterey pine)") == ["Pinus", "radiata"])
    }

    /// Every real name typesets without losing a character.
    @Test func speciesKeepsEveryCharacter() throws {
        for plant in try TestData.data.plants().plants {
            #expect(String(BotanicalNames.species(plant.name).characters) == plant.name.split(separator: " ").joined(separator: " "))
        }
    }

    @Test func aDashBetweenTaxaClosesUpOtherwiseSpaced() {
        let rmt = BotanicalNames.attributed("Nothofagus - Atherosperma rainforest")
        #expect(String(rmt.characters) == "Nothofagus–Atherosperma rainforest")
        let fph = BotanicalNames.attributed("Plantations for silviculture - hardwood")
        #expect(String(fph.characters) == "Plantations for silviculture – hardwood")
        let dvc = BotanicalNames.attributed("Eucalyptus viminalis - Eucalyptus globulus coastal forest")
        #expect(String(dvc.characters) == "Eucalyptus viminalis–Eucalyptus globulus coastal forest")
    }

    /// The genus list is pinned to the data: every capitalised word of a
    /// community/class name that plants.json knows as a genus is listed,
    /// and every listed genus occurs in some name.
    @Test func mapGeneraMatchTheBundledNames() throws {
        let names = try TestData.data.communities().values.map(\.displayName)
            + TestData.data.pre1750Units().values.map(\.name)
        let words = Set(names.flatMap { $0.split(separator: " ").map(String.init) })
        let plantGenera = Set(try TestData.data.plants().plants.compactMap { $0.name.split(separator: " ").first.map(String.init) })
        let expected = words.intersection(plantGenera).filter { $0.first?.isUppercase == true }
        #expect(expected.isSubset(of: BotanicalNames.mapGenera), "missing: \(expected.subtracting(BotanicalNames.mapGenera).sorted())")
        #expect(BotanicalNames.mapGenera.isSubset(of: words), "unused: \(BotanicalNames.mapGenera.subtracting(words).sorted())")
    }
}

/// A fake local pack: holds exactly the listed tiles.
struct FakeProbe: TileExistenceProbe {
    var tiles: Set<TileID>
    func hasTile(_ tile: TileID) async -> Bool? { tiles.contains(tile) }
}

struct SeasonCoverageTests {
    static let labels = ["2019–20", "2020–21", "2021–22", "2022–23", "2023–24", "2024–25", "2025–26"]
    // Hobart CBD
    static let lon = 147.33, lat = -42.88

    @Test func tileMathMatchesKnownTiles() {
        // z0 is one tile; Hobart at z15 (slippy-map formula)
        #expect(TileID(longitude: 0, latitude: 0, zoom: 0) == TileID(z: 0, x: 0, y: 0))
        let t = TileID(longitude: Self.lon, latitude: Self.lat, zoom: 15)
        #expect(t.x == 29794 && t.y == 20712)
    }

    @Test func probeZoomIsTheDrawnLevelCappedAtThePacks() {
        #expect(SeasonCoverage.probeZoom(mapZoom: 8.4) == 9)
        #expect(SeasonCoverage.probeZoom(mapZoom: 12.6) == 14)
        #expect(SeasonCoverage.probeZoom(mapZoom: 17) == 15)
        #expect(SeasonCoverage.probeZoom(mapZoom: -3) == 0)
    }

    @Test func theNewestLocalSeasonWithATileWins() async {
        let z = SeasonCoverage.probeZoom(mapZoom: 13)
        let here = TileID(longitude: Self.lon, latitude: Self.lat, zoom: z)
        let has = FakeProbe(tiles: [here]), lacks = FakeProbe(tiles: [])
        let probes: [(any TileExistenceProbe)?] = [has, lacks, has, lacks, lacks, lacks, lacks]
        let c = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 13)
        #expect(c == .showing(season: 2, newerMayStream: false))
        #expect(SeasonCoverage.text(c, labels: Self.labels, device: "iPhone") == "Showing 2021–22 photos here")
        // the cutoff hides newer seasons
        let older = await SeasonCoverage.caption(cutoff: 1, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 13)
        #expect(older == .showing(season: 0, newerMayStream: false))
    }

    @Test func nothingHereSaysTheTopoShows() async {
        let lacks = FakeProbe(tiles: [])
        let c = await SeasonCoverage.caption(cutoff: 4, probes: Array(repeating: lacks, count: 7),
                                             longitude: Self.lon, latitude: Self.lat, mapZoom: 10)
        #expect(c == .noneHere(cutoff: 4))
        #expect(SeasonCoverage.text(c, labels: Self.labels, device: "iPad")
            == "No photos up to 2023–24 here — the topo map shows instead")
    }

    @Test func seasonsNotOnTheDeviceAreNeverProbedAndSaySo() async {
        let here = TileID(longitude: Self.lon, latitude: Self.lat, zoom: 11)
        let has = FakeProbe(tiles: [here])
        var probes: [(any TileExistenceProbe)?] = Array(repeating: nil, count: 7)
        let none = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 10)
        #expect(none == .noneOnDevice(cutoff: 6))
        #expect(SeasonCoverage.text(none, labels: Self.labels, device: "iPhone").contains("isn't on this iPhone and may stream"))
        probes[3] = has
        let some = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 10)
        #expect(some == .showing(season: 3, newerMayStream: true))
    }

    /// Only the top season streams (one live season source): a missing
    /// OLDER pack never promises streaming.
    @Test func onlyAMissingTopSeasonMayStream() async {
        let here = TileID(longitude: Self.lon, latitude: Self.lat, zoom: 11)
        let has = FakeProbe(tiles: [here]), lacks = FakeProbe(tiles: [])
        // top (6) on the device without a photo here, 5 missing, 3 has one
        var probes: [(any TileExistenceProbe)?] = [lacks, lacks, lacks, has, lacks, nil, lacks]
        let c = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 10)
        #expect(c == .showing(season: 3, newerMayStream: false))
        #expect(!SeasonCoverage.text(c, labels: Self.labels, device: "iPhone").contains("stream"))
        // nothing local here, an older pack missing: no streaming promise
        probes[3] = lacks
        let none = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 10)
        #expect(none == .noneHere(cutoff: 6, partial: true))
        #expect(SeasonCoverage.text(none, labels: Self.labels, device: "iPhone")
            == "No downloaded photos up to 2025–26 here — the topo map shows instead")
        // the top pack missing: it may stream over the older photo
        probes[3] = has; probes[6] = nil
        let top = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 10)
        #expect(top == .showing(season: 3, newerMayStream: true))
        // … but not at statewide zooms, where the live season doesn't stream
        let wide = TileID(longitude: Self.lon, latitude: Self.lat, zoom: SeasonCoverage.probeZoom(mapZoom: 8))
        probes[3] = FakeProbe(tiles: [wide])
        let far = await SeasonCoverage.caption(cutoff: 6, probes: probes, longitude: Self.lon, latitude: Self.lat, mapZoom: 8)
        #expect(far == .showing(season: 3, newerMayStream: false))
    }
}

struct SpeciesNameTests {
    @Test func cultivarsAndRanksStayUpright() {
        func italic(_ s: String) -> [String] {
            let a = BotanicalNames.species(s)
            return a.runs.compactMap { $0.inlinePresentationIntent == .emphasized ? String(a[$0.range].characters) : nil }
        }
        #expect(italic("Quercus robur") == ["Quercus", "robur"])
        #expect(italic("Ulmus × hollandica 'Vegeta'") == ["Ulmus", "hollandica"])
        #expect(italic("Eucalyptus globulus subsp. globulus") == ["Eucalyptus", "globulus", "globulus"])
        #expect(italic("Pinus (unknown)") == ["Pinus"])
    }
}
