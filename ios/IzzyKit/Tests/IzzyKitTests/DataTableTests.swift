import Foundation
import Testing
@testable import IzzyKit

struct WebFixture: Decodable {
    struct Near: Decodable { var name: String; var lat: Double; var lon: Double; var sites: [String: Int] }
    var nearbyCells: Int
    var nearby: [Near]
    var age: [String: String]
    var extent: [String: String]
    var names: [String: String]
}

@Suite struct DataTableTests {
    static let web: WebFixture = try! TestData.fixture("web.json")

    @Test func communities() throws {
        let t = try TestData.data.communities()
        #expect(t.count == 156)
        #expect(t["AAP"]?.name == "(AAP) Alkaline pans")
        #expect(t["AAP"]?.displayName == "Alkaline pans")
        for (code, name) in Self.web.names { #expect(t[code]?.displayName == name, "\(code)") }
        #expect(Community.stripCodePrefix("(DOB) Eucalyptus obliqua forest") == "Eucalyptus obliqua forest")
        #expect(Community.stripCodePrefix("Unknown community") == "Unknown community")
        #expect(Community.stripCodePrefix("(ab) x") == "(ab) x")  // three CAPITALS only
    }

    @Test func geologyAgesMatchWebApp() throws {
        let t = try TestData.data.geologyUnits()
        let au = Locale(identifier: "en_AU")
        #expect(t.count == Self.web.age.count)
        // The web wording, with one intended native change: ages of 1,000 Ma
        // and more get the locale's digit grouping ("1,450–545", as the same
        // sentences already write "12,000 years"); the web printed "1450".
        for (symb, web) in Self.web.age {
            let want = web.replacing(/\b(\d)(\d{3})\b/) { "\($0.output.1),\($0.output.2)" }
            #expect(t[symb]?.ageText(locale: au) == want, "\(symb): web \(web)")
        }
        // the lay-reader wording itself
        #expect(GeologyUnit.formatAge(maxMa: 180, minMa: 180, locale: au) == "About 180 million years old")
        #expect(GeologyUnit.formatAge(maxMa: 0.0117, minMa: 0, locale: au) == "Geologically recent (roughly the last 12,000 years)")
        #expect(GeologyUnit.formatAge(maxMa: 2.58, minMa: 0.0117, locale: au) == "About 2.6 million years ago – recent")
        #expect(GeologyUnit.formatAge(maxMa: 500.5, minMa: 458.4, locale: au) == "About 501–458 million years old")
        #expect(GeologyUnit.formatAge(maxMa: 5.333, minMa: 2.58, locale: au) == "About 5.3–2.6 million years old")
        #expect(GeologyUnit.formatAge(maxMa: 23.03, minMa: 22.9, locale: au) == "About 23 million years old")
        #expect(GeologyUnit.formatAge(maxMa: nil, minMa: nil, locale: au) == "")
        #expect(GeologyUnit.formatAge(maxMa: 66, minMa: nil, locale: au) == "About 66 million years old")
        // native rules (not the web's toFixed): halves away from zero on the
        // number as written; grouping and decimal mark from the locale
        #expect(GeologyUnit.formatAge(maxMa: 2.25, minMa: 0.35, locale: au) == "About 2.3–0.4 million years old")
        #expect(GeologyUnit.formatAge(maxMa: 1400.4, minMa: nil, locale: au) == "About 1,400 million years old")
        let de = Locale(identifier: "de_DE")
        #expect(GeologyUnit.formatAge(maxMa: 5.333, minMa: 2.58, locale: de) == "About 5,3–2,6 million years old")
    }

    @Test func pre1750ExtentMatchesWebApp() throws {
        let t = try TestData.data.pre1750Units()
        let au = Locale(identifier: "en_AU")
        #expect(t.count == Self.web.extent.count)
        for (mvs, text) in Self.web.extent { #expect(t[mvs]?.extentText(locale: au) == text, "MVS \(mvs)") }
        #expect(Pre1750Unit.formatExtent(hectares: 25, locale: au) == "25 ha statewide")
        #expect(Pre1750Unit.formatExtent(hectares: 99, locale: au) == "99 ha statewide")
        #expect(Pre1750Unit.formatExtent(hectares: 100, locale: au) == "~1 km² statewide")
        #expect(Pre1750Unit.formatExtent(hectares: 149, locale: au) == "~1 km² statewide")
        #expect(Pre1750Unit.formatExtent(hectares: 150, locale: au) == "~2 km² statewide")
        #expect(Pre1750Unit.formatExtent(hectares: 768_371, locale: au) == "~7,684 km² statewide")
        #expect(Pre1750Unit.formatExtent(hectares: 768_371, locale: Locale(identifier: "de_DE")) == "~7.684 km² statewide")
        for u in t.values { #expect(!u.extentText(locale: au).contains("~0 km²")) }
    }

    @Test func f2fIndex() throws {
        let f = try TestData.data.f2fIndex()
        let loc = try #require(f.location(for: "AAP"))
        #expect(loc.url.absoluteString == "https://nre.tas.gov.au/Documents/f2f_saltmarsh.pdf")
        #expect(loc.page == 6)
        #expect(f.chapterFiles.count == 11)  // chapters map 1:1 to the 11 VEG_GROUPs
        #expect(f.location(for: "ZZZ") == nil)
        // every indexed community exists in the TASVEG table
        let communities = try TestData.data.communities()
        for code in f.index.keys { #expect(communities[code] != nil, "\(code)") }
    }

    // mirrors app.spec.ts "trees: data sanity …"
    @Test func treesSanity() throws {
        let t = try TestData.data.trees()
        #expect(t.points.count == t.meta.points)
        #expect(t.areas.count == t.meta.areas)
        for tag in t.points.map(\.tag) + t.areas.map(\.tag) {
            #expect(t.refs[tag.ref] != nil, "ref \(tag.ref)")
            #expect(t.sheets[tag.sheet] != nil, "sheet \(tag.sheet)")
            #expect(t.accuracyLabel(for: tag.acc) != nil, "accuracy \(tag.acc)")
            #expect(t.sheetID(for: tag) == tag.sheet)
        }
        for (ref, r) in t.refs {
            #expect(MapText.isLatin1(r.label), "label of \(ref) is Latin-1")
            #expect(!r.label.isEmpty)
            #expect(!r.sheets.isEmpty)
            for id in r.sheets { #expect(t.sheets[id] != nil) }
        }
        #expect(t.sheetsTotalBytes > 300_000_000)
        // only botanical names may fall outside (2 refs today, curly quotes)
        #expect(t.refs.values.contains { !MapText.isLatin1($0.name) })
        #expect(t.accuracyLabel(for: "sk") == "Sketch")
        #expect(t.accuracyLabel(for: "ft") == "1:1 Field Survey")
        #expect(t.accuracyLabel(for: "") == nil)
        #expect(t.accuracyLabel(for: nil) == nil)
        // inside Hobart's municipality, [lon, lat] order respected
        for p in t.points {
            #expect((147.1 ... 147.5).contains(p.position.longitude) && (-43.0 ... -42.7).contains(p.position.latitude))
        }
        #expect(t.areas.allSatisfy { !$0.polygons.isEmpty && $0.polygons.allSatisfy { !$0.isEmpty } })
    }

    @Test func latin1() {
        #expect(MapText.isLatin1("Bhutan cypress"))
        #expect(MapText.isLatin1("Café Ñandú ÿ"))
        #expect(MapText.isLatin1("Eucalyptus × hybrid"))  // × is U+00D7: inside the range
        #expect(!MapText.isLatin1("Poplus nigra ‘Italica’"))  // curly quotes: a real register name
        #expect(!MapText.isLatin1("Acacia — wattle"))
        #expect(!MapText.isLatin1("‘Golden’ elm"))
        #expect(!MapText.isLatin1("Cafe\u{301}"))  // decomposed accent is U+0301
        #expect(MapText.isLatin1(""))
    }
}
