import Foundation
import Testing
@testable import IzzyKit

/// Port of the web test "search: normalisation, abbreviations, minimum
/// length, road demotion, address decode" — the same hand-made index, so
/// each rule is pinned without depending on the yearly LIST data.
@Suite struct SearchSyntheticTests {
    static let gazetteer = #"""
    {"version": 1, "built": "", "attribution": "",
     "types": ["Road", "Mountain", "Suburb/Locality", "Property", "Square", "Pier", "Beach"],
     "groups": ["Transport", "Natural Feature", "Cultural", "Property"],
     "typeGroup": [0, 1, 2, 3, 2, 0, 1],
     "places": ["", "North Hobart", "Wellington Park", "Longford", "Battery Point", "Hobart"],
     "munis": ["", "Hobart", "Glenorchy, Hobart, Kingborough"],
     "rows": [
      ["Sandy Bay Road", 0, 0, 1, -4290000, 14733000, [-100, -900, 100, 900]],
      ["Sandy Bay", 2, 0, 1, -4290500, 14732000],
      ["Mount Direction", 1, 0, 0, -4280000, 14730000],
      ["Elizabeth Street", 0, 1, 1, -4287000, 14731500],
      ["Elizabeth Street Pier", 5, 5, 1, -4288200, 14733500],
      ["Elizabeth Street Pier", 3, 5, 1, -4288200, 14733500],
      ["Kunanyi / Mount Wellington", 1, 2, 2, -4290464, 14722438],
      ["O'Briens Road", 0, 0, 0, -4300000, 14720000],
      ["Seven Mile Beach", 6, 0, 0, -4286000, 14750000],
      ["Salamanca", 3, 3, 0, -4160000, 14710000],
      ["Salamanca Square", 4, 4, 1, -4288800, 14733000],
      ["Henry Jones IXL Complex", 3, 5, 1, -4288000, 14733200]
     ]}
    """#
    static let addresses = #"""
    {"version": 1, "built": "", "attribution": "", "streets": [
      ["Sandy Bay Road", "Sandy Bay", 14733000, -4290000, [1, 3, "5A", 7], [0, 10, 10, 10], [0, -5, -5, -5]],
      ["Elizabeth Street", "North Hobart", 14731500, -4287000, [2, 4], [0, 10], [0, 10]],
      ["Elizabeth Street", "New Town", 14731000, -4285000, [300, 302, 304], [0, 10, 10], [0, 10, 10]],
      ["Seven Mile Beach Road", "Seven Mile Beach", 14750000, -4286000, [7, 9], [0, 10], [0, 10]]
    ]}
    """#
    static let index = Result { try SearchIndex(gazetteer: Data(gazetteer.utf8), addresses: Data(addresses.utf8)) }
    static let noAddresses = Result { try SearchIndex(gazetteer: Data(gazetteer.utf8), addresses: nil) }

    func idx() throws -> SearchIndex { try Self.index.get() }
    func names(_ q: String) throws -> [String] { try idx().search(query: q).map(\.name) }

    @Test func abbreviationAndMinimumLength() throws {
        #expect(try names("sandy bay rd").first == "Sandy Bay Road")
        #expect(try names("s").isEmpty) // two-letter minimum
        #expect(try names("sa").contains("Sandy Bay"))
        #expect(try names("mt direction").first == "Mount Direction")
    }

    @Test func roadDemotionAndStreetWords() throws {
        let demote = try names("sandy bay")
        #expect(demote.first == "Sandy Bay") // the suburb outranks its road…
        #expect(demote.contains("Sandy Bay Road")) // …which still lists
        #expect(try names("eliz hob").contains("Elizabeth Street")) // "hob" via the locality/council
        let streetWord = try names("eliz st hob")
        #expect(streetWord.first == "Elizabeth Street") // a street word: the road beats the pier
        #expect(streetWord.contains("Elizabeth Street Pier"))
        // a Property twinning a register row (same name + place) is dropped
        #expect(try idx().search(query: "eliz st hob").filter { $0.name == "Elizabeth Street Pier" }.map(\.type) == ["Pier"])
    }

    @Test func apostrophesAndNumberWords() throws {
        #expect(try names("obriens rd").first == "O'Briens Road")
        #expect(try names("o'briens").first == "O'Briens Road")
        let n = try names("7 mile beach")
        #expect(n.first == "Seven Mile Beach") // "7" spelt out beats the address
        #expect(n.contains("7 Seven Mile Beach Road"))
    }

    @Test func unitsRangesAndHouseNumbers() throws {
        let unit = try #require(try idx().search(query: "1/3 sandy bay rd").first)
        #expect(unit.name == "3 Sandy Bay Road") // unit 1, number 3
        #expect(unit.meta == "Address · Sandy Bay")
        #expect(try names("3-5 sandy bay rd").first == "3 Sandy Bay Road") // a range keeps its first number
        #expect(try names("1 3 sandy bay rd").first == "3 Sandy Bay Road")
        let exact = try #require(try idx().search(query: "3 sandy bay rd").first)
        #expect(exact.name == "3 Sandy Bay Road")
        #expect(exact.meta == "Address · Sandy Bay")
        #expect(abs(exact.coordinate.longitude - 147.3301) < 5e-6) // lon0 + 0 + 10 (1e-5°)
        #expect(abs(exact.coordinate.latitude - -42.90005) < 5e-6)
        #expect(exact.type == "Address" && exact.kind == .address && exact.bbox == nil)
        #expect(exact.camera == .point(exact.coordinate, zoom: 17.5))
        let nearest = try #require(try idx().search(query: "5 sandy bay rd").first)
        #expect(nearest.name == "5 Sandy Bay Road")
        #expect(nearest.meta == "Address · Sandy Bay · nearest: 5A")
    }

    @Test func suburbQualifiedStreets() throws {
        // a suburb the register does not list comes from the address file:
        // one Road row, pinned at the middle number, framed by all of them
        let suburb = try idx().search(query: "elizabeth st new town")
        #expect(suburb.map { [$0.name, $0.type, $0.meta] } == [["Elizabeth Street", "Road", "Road · New Town"]])
        let s = try #require(suburb.first)
        #expect(abs(s.coordinate.longitude - 147.3101) < 5e-6)
        #expect(abs(s.coordinate.latitude - -42.8499) < 5e-6)
        #expect(s.bbox == SearchBBox(west: 147.31, south: -42.85, east: 147.3102, north: -42.8498))
        #expect(s.kind == .transport)
        #expect(s.camera == .fit(s.bbox!, maxZoom: 16, padding: 56))
        // …but a (name, place) the register has is shown once, from the register
        #expect(try idx().search(query: "elizabeth st north hobart").map(\.meta) == ["Road · North Hobart, Hobart"])
        // and without a suburb word the address file adds no duplicate rows
        #expect(try names("elizabeth street").filter { $0 == "Elizabeth Street" }.count == 1)
    }

    @Test func propertyNames() throws {
        let p = try names("salamanca")
        #expect(p.first == "Salamanca Square") // the property "Salamanca" trails official names…
        #expect(p.contains("Salamanca"))
        #expect(try names("henry jones") == ["Henry Jones IXL Complex"]) // …but still answers alone
    }

    @Test func multiCouncilMeta() throws {
        // matches as context in full, displays its first council only
        let m = try #require(try idx().search(query: "kunanyi hob").first)
        #expect(m.name == "Kunanyi / Mount Wellington")
        #expect(m.meta == "Mountain · Wellington Park, Glenorchy")
        #expect(m.camera == .point(m.coordinate, zoom: 13)) // no bbox: the Mountain zoom
    }

    @Test func distanceFromNear() throws {
        let i = try Self.noAddresses.get()
        let km = try #require(i.search(query: "sandy bay", near: GeoPoint(longitude: 147.325, latitude: -42.905)).first?.distanceKm)
        #expect(km > 0 && km < 1)
        #expect(i.search(query: "sandy bay").allSatisfy { $0.distanceKm == nil })
        #expect(i.search(query: "12 sandy bay rd").allSatisfy { $0.type != "Address" }) // no address file
    }

    @Test func substringTier() throws {
        // "ellington" is inside no word's start: only the substring tier finds it
        let r = try idx().search(query: "ellington")
        #expect(r.map(\.name) == ["Kunanyi / Mount Wellington"])
        #expect(r.first?.score == 0.5)
        #expect(try names("el").isEmpty == false) // prefix "el…" (Elizabeth)
        #expect(try idx().search(query: "zz").isEmpty) // too short for the substring tier
    }

    @Test func limit() throws {
        #expect(try idx().search(query: "sa", limit: 2).count == 2)
        #expect(try idx().search(query: "sa", limit: 0).isEmpty)
    }
}
