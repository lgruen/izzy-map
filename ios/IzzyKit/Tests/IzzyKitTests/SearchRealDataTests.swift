import Foundation
import Testing
@testable import IzzyKit

/// The web app's search tests (app.spec.ts, "search: …") against the REAL
/// bundled indexes, same queries and expectations; `near` stands in for the
/// map centre (the web tests' fake GPS fix unless the test moved the map).
/// Plus one test per rule on real rows.
@Suite struct SearchRealDataTests {
    func search(_ q: String, near: GeoPoint? = SearchFixture.gps) throws -> [SearchResult] {
        try SearchFixture.index().search(query: q, near: near)
    }
    func first(_ q: String, near: GeoPoint? = SearchFixture.gps) throws -> SearchResult {
        try #require(try search(q, near: near).first, "no result for \(q)")
    }

    // MARK: web e2e ports

    @Test func kunanyiFindsTheMountain() throws {
        let r = try first("kunanyi")
        #expect(r.name.contains("Wellington"))
        #expect(r.kind == .naturalFeature)
        // the camera lands on the mountain (web: settled centre within 0.03°)
        guard case let .fit(b, maxZoom, padding) = r.camera else { Issue.record("expected a bbox fit"); return }
        #expect(abs((b.west + b.east) / 2 - 147.237) < 0.03)
        #expect(abs((b.south + b.north) / 2 - -42.896) < 0.03)
        #expect(maxZoom == 14.5 && padding == 56)
    }

    @Test func abbreviationsAndContextWords() throws {
        let eliz = try first("eliz st hob")
        #expect(eliz.name == "Elizabeth Street")
        #expect(eliz.meta.contains("Hobart"))
        #expect(try first("mt wellington").name.contains("Mount Wellington"))
        #expect(try first("sandy bay rd").name == "Sandy Bay Road")
        // the register lists Elizabeth Street under Hobart only; the suburb
        // comes from the address file's per-suburb street rows
        let nh = try first("elizabeth st north hobart")
        #expect(nh.name == "Elizabeth Street")
        #expect(nh.meta.contains("North Hobart"))
        #expect(try first("7 mile beach").name == "Seven Mile Beach") // a number word, not a house number
        #expect(try first("salamanca").name == "Salamanca Square") // the square, not a farm of that name
    }

    @Test func equalNamesRankByDistanceFromTheMapCentre() throws {
        let l = try first("elizabeth street", near: SearchFixture.launceston)
        #expect(l.name == "Elizabeth Street")
        #expect(l.meta.contains("Launceston"))
        let h = try first("elizabeth street", near: SearchFixture.hobart)
        #expect(h.name == "Elizabeth Street")
        #expect(h.meta.contains("Hobart"))
        #expect(!h.meta.contains("Launceston"))
        let hk = try #require(h.distanceKm), lk = try #require(l.distanceKm(from: SearchFixture.hobart))
        #expect(hk < lk)
    }

    @Test func aHouseNumberResolvesToAnAddressAndPropertyNamesResolve() throws {
        let a = try first("12 elizabeth st hobart")
        #expect(a.name.hasPrefix("12 Elizabeth Street"))
        #expect(a.meta.hasPrefix("Address · "))
        guard case let .point(p, zoom) = a.camera else { Issue.record("expected a point"); return }
        #expect(zoom >= 17)
        #expect(abs(p.longitude - 147.33) < 0.01)
        #expect(abs(p.latitude - -42.88) < 0.01)
        let henry = try search("henry jones")
        #expect(henry.contains { $0.meta.hasPrefix("Property") })
        #expect(try #require(henry.first).name.lowercased().contains("henry jones"))
    }

    @Test func hobartAndHobartRivulet() throws {
        #expect(try first("hobart").name.contains("Hobart"))
        #expect(try first("hobart rivulet").name.contains("Hobart Rivulet"))
    }

    @Test func sandyBayListsSeveralRows() throws {
        // the web keyboard test needs ≥ 3 rows and picks the third
        #expect(try search("sandy bay").count >= 3)
    }

    // MARK: rules on real rows

    @Test func apostrophesVanish() throws {
        let r = try search("obriens rd")
        #expect(r.first?.name == "O'Briens Road")
        #expect(r.contains { $0.name == "Obriens Road" }) // the register spells one without
        #expect(try first("dentrecasteaux channel").name == "D'Entrecasteaux Channel")
        #expect(try first("D’Entrecasteaux Channel").name == "D'Entrecasteaux Channel")
    }

    @Test func abbreviationsExpand() throws {
        #expect(try first("nth hobart").name == "North Hobart")
        #expect(try first("saint helens").name == "St Helens") // saint → st
        #expect(try first("st helens").name == "St Helens")
    }

    @Test func houseNumbers() throws {
        let exact = try first("14a abbotsfield rd")
        #expect(exact.name == "14A Abbotsfield Road")
        #expect(exact.meta == "Address · Claremont") // exact: no "nearest"
        #expect(exact.score == 4 + 3 + 4 + 1) // first word exact (+1 first), rd → road exact, +4 address, +1 exact
        for q in ["1/12 abbotsfield rd", "1 12 abbotsfield rd", "abbotsfield rd 12", "12 abbotsfield road claremont"] {
            let r = try first(q)
            #expect(r.name == "12 Abbotsfield Road", "\(q)")
            #expect(r.meta == "Address · Claremont", "\(q)")
        }
        // a range keeps its first number; the street has 2A but no 2 — the
        // stand-in is named, ties prefer a plain number, then the lower one
        // (a 2A stand-in for 2 costs nothing, so it ties at 11 with the
        // register's whole-name road, which is nearer — as on the web)
        let rows = try search("2-4 abbotsfield rd")
        #expect(rows.prefix(2).map(\.score) == [11, 11])
        let range = try #require(rows.first { $0.type == "Address" })
        #expect(range.name == "2 Abbotsfield Road")
        #expect(range.meta == "Address · Claremont · nearest: 2A")
        // "nearest: 14" for a typed 12: the stand-in loses (14 − 12) / 100
        let near = try first("12 bird st montello")
        #expect(near.name == "12 Bird Street")
        #expect(near.meta == "Address · Montello · nearest: 14")
        #expect(abs(near.score - (4 + 2 + 1 + 4 - 0.02)) < 1e-9)
        // the same street in another suburb, far off in house numbers, ranks lower
        // an absurd number neither overflows nor finds a match
        let huge = try first("99999999999999999999 elizabeth st")
        #expect(huge.name == "99999999999999999999 Elizabeth Street")
        #expect(huge.meta == "Address · North Hobart · nearest: 249") // as the web ranks it
        let hob = try search("12 elizabeth st hobart")
        #expect(hob.prefix(2).map(\.meta) == ["Address · Hobart · nearest: 11", "Address · North Hobart · nearest: 249"])
    }

    @Test func numberWords() throws {
        let r = try search("7 mile beach")
        #expect(r.first?.name == "Seven Mile Beach")
        #expect(r.contains { $0.name == "7 Seven Mile Beach Road" })
        #expect(try first("ten mile").name == "Ten Mile Hill")
    }

    @Test func propertyDemotion() throws {
        let r = try search("salamanca")
        #expect(r.first?.name == "Salamanca Square")
        let farm = try #require(r.first { $0.name == "Salamanca" && $0.type == "Property" })
        #expect(farm.score == 3 + 1 + 1 - 0.5 - 2) // exact first word, whole-name bonus 1, −0.5, −2 (official rows answered)
        #expect(farm.kind == .property)
        #expect(farm.camera == .point(farm.coordinate, zoom: 16))
    }

    @Test func substringTierCatchesMidWordTypos() throws {
        let r = try search("ellington")
        #expect(r.first?.name == "Ellington Road") // a real prefix match first…
        #expect(r.dropFirst().allSatisfy { $0.score <= 0.5 }) // …then the substring tier (properties −2 below it)
        #expect(r.dropFirst().contains { $0.name == "Kunanyi / Mount Wellington" })
    }

    @Test func distanceTieBreakAndWording() throws {
        // equal-score rows: the nearer one first, every row knows its distance
        let h = try search("elizabeth street", near: SearchFixture.hobart)
        let top = h.filter { $0.score == h[0].score }
        #expect(top.count > 3)
        #expect(zip(top, top.dropFirst()).allSatisfy { $0.distanceKm! <= $1.distanceKm! })
        #expect(h[0].distanceText != nil)
        #expect(try search("elizabeth street", near: nil).allSatisfy { $0.distanceText == nil })
    }

    @Test func minimumLength() throws {
        #expect(try search("s").isEmpty)
        #expect(try search(" é ").isEmpty)
        #expect(try search("a.").isEmpty)
        #expect(try search("aa").map(\.name) == ["Aarons Creek", "Aazure Fashion"])
    }

    @Test func idsAreUniqueWithinAList() throws {
        for q in ["elizabeth street", "seven mile beach", "12 elizabeth st", "sa", "st"] {
            let r = try search(q)
            #expect(Set(r.map(\.id)).count == r.count, "\(q)")
        }
    }

    @Test func resultKindsAndCameraTable() throws {
        #expect(Set(try SearchFixture.index().groups.map(SearchResult.Kind.init(group:))) ==
                Set(SearchResult.Kind.allCases.filter { $0 != .address }))
        #expect(SearchResult.zoomByType["Waterfall"] == 15)
        #expect(SearchResult.zoomByType["Town"] == 13)
        #expect(SearchResult.zoomByType["Address"] == 17.5)
        #expect(SearchResult.zoomByType["Property"] == 16)
        let unlisted = try #require(try search("mona").first { $0.bbox == nil && SearchResult.zoomByType[$0.type] == nil })
        #expect(unlisted.camera == .point(unlisted.coordinate, zoom: 14))
    }
}

private extension SearchResult {
    func distanceKm(from p: GeoPoint) -> Double? {
        SearchText.km(lat1: p.latitude, lon1: p.longitude, lat2: coordinate.latitude, lon2: coordinate.longitude)
    }
}
