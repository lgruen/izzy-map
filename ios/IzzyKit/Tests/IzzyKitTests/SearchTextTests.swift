import Foundation
import Testing
@testable import IzzyKit

/// The text rules on their own: normalisation, abbreviations, house numbers,
/// units and ranges, distances.
@Suite struct SearchTextTests {
    @Test(arguments: [
        ("Saint-Mary’s Créek", "saint marys creek"), // apostrophes vanish, other punctuation splits
        ("O'Briens Road", "obriens road"),
        ("D’Entrecasteaux", "dentrecasteaux"),
        ("  Kunanyi / Mount Wellington ", "kunanyi mount wellington"),
        ("Ålands—Øya", "alands ya"), // Ø has no decomposition: not a-z, so a gap (as in JS)
        ("1/12 Smith St", "1 12 smith st"),
        ("ÉCOLE", "ecole"),
        ("--", ""),
    ])
    func normalise(_ input: String, _ expected: String) {
        #expect(SearchText.normalise(input) == expected)
    }

    @Test func normalisedTextIsLowerASCIIWords() {
        for s in ["Mount Field", "Cape Pillar's Track", "Hôtel Saint-Clair", "x"] {
            let n = SearchText.normalise(s)
            #expect(n.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x20 })
            #expect(!n.hasPrefix(" ") && !n.hasSuffix(" ") && !n.contains("  "))
        }
    }

    @Test func abbreviationsTryExpansionThenLiteral() {
        #expect(SearchText.forms("rd") == ["road", "rd"])
        #expect(SearchText.forms("mt") == ["mount", "mt"])
        #expect(SearchText.forms("saint") == ["st", "saint"])
        #expect(SearchText.forms("st") == ["st"]) // a prefix form: "st" prefixes "street"
        #expect(SearchText.forms("elizabeth") == ["elizabeth"])
    }

    @Test(arguments: [
        ("1/12 Smith St", "12 Smith St"),
        ("1 / 12a Smith St", "12a Smith St"),
        ("2-4 Smith St", "2 Smith St"),
        ("2a – 4 Smith St", "2a Smith St"),
        ("2—4b Smith", "2 Smith"),
        ("  1/3-5 Smith", "3 Smith"), // unit first, then the range of what is left
        ("1/12ab Smith", "1/12ab Smith"), // \b fails: no rewrite
        ("2-4x5 Smith", "2-4x5 Smith"),
        ("Smith St 1/12", "Smith St 1/12"), // only at the start
        ("12 Smith St", "12 Smith St"),
    ])
    func unitsAndRanges(_ input: String, _ expected: String) {
        #expect(SearchText.stripUnitAndRange(input) == expected)
    }

    @Test func houseNumberSplit() {
        func split(_ q: String) -> (String?, [String], Bool) {
            let r = SearchText.splitHouseNumber(SearchText.tokenise(q))
            return (r.number, r.rest, r.atEnd)
        }
        #expect(split("12 elizabeth st") == ("12", ["elizabeth", "st"], false))
        #expect(split("15a elizabeth st") == ("15a", ["elizabeth", "st"], false))
        #expect(split("1 12 elizabeth st") == ("12", ["elizabeth", "st"], false)) // unit then number
        #expect(split("elizabeth st 12") == ("12", ["elizabeth", "st"], true))
        #expect(split("12 3 smith") == ("3", ["smith"], false))
        #expect(split("12 smith 3") == ("12", ["smith"], false)) // stray bare numbers dropped
        #expect(split("12") == (nil, ["12"], false)) // nothing left to name the street
        #expect(split("2 2") == (nil, ["2", "2"], false))
        #expect(split("12ab smith") == (nil, ["12ab", "smith"], false))
        #expect(SearchText.isHouseNumber("007"))
        #expect(!SearchText.isHouseNumber("a1"))
    }

    @Test func numberWordsSpellTheNumbersThatStartNames() {
        #expect(SearchText.numberWords["7"] == "seven")
        #expect(SearchText.numberWords["20"] == "twenty")
        #expect(SearchText.numberWords["21"] == nil)
        #expect(SearchText.numberWords["07"] == nil)
    }

    @Test func leadingInt() {
        #expect(SearchText.leadingInt("15A") == 15)
        #expect(SearchText.leadingInt("249") == 249)
        #expect(SearchText.leadingInt("A1") == nil)
    }

    @Test func distanceAndItsWording() {
        // Hobart GPO → Launceston ≈ 160 km; 0.001° of latitude ≈ 110 m
        let k = SearchText.km(lat1: -42.8821, lon1: 147.3272, lat2: -41.4332, lon2: 147.1441)
        #expect(k > 155 && k < 170)
        #expect(abs(SearchText.km(lat1: -42, lon1: 147, lat2: -42.001, lon2: 147) - 0.11057) < 1e-9)
        #expect(SearchText.formatDistance(km: 0.01) == "50 m")
        #expect(SearchText.formatDistance(km: 0.34) == "350 m")
        #expect(SearchText.formatDistance(km: 0.96) == "1.0 km")
        #expect(SearchText.formatDistance(km: 4.24) == "4.2 km")
        #expect(SearchText.formatDistance(km: 9.96) == "10.0 km")
        #expect(SearchText.formatDistance(km: 17.4) == "17 km")
    }
}
