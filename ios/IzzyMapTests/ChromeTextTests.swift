import Foundation
import Testing
@testable import IzzyMap

struct DisplayTextTests {
    @Test func correctsKnownUpstreamTyposAsWholeWords() {
        #expect(DisplayText.corrected("Sedgelands, rushs or reeds") == "Sedgelands, rushes or reeds")
        #expect(DisplayText.corrected("Rushs") == "rushes")
        #expect(DisplayText.corrected("rushes and Rushlands") == "rushes and Rushlands")
    }

    @Test func geologyTitlesLoseTheClosingFullStopOnly() {
        #expect(DisplayText.unitTitle("Dolerite (tholeiitic) with granophyre in places.")
            == "Dolerite (tholeiitic) with granophyre in places")
        #expect(DisplayText.unitTitle("Orthoquartzite") == "Orthoquartzite")
        #expect(DisplayText.unitTitle("Shale, siltstone etc.") == "Shale, siltstone etc.")
        #expect(DisplayText.unitTitle("  Sandstone.  ") == "Sandstone")
    }

    @Test func treePositionIsPlainLanguage() {
        #expect(DisplayText.treePosition(code: "sk") == "Approximate (sketched)")
        #expect(DisplayText.treePosition(code: "ft") == "Surveyed on site")
        #expect(DisplayText.treePosition(code: "un") == nil)
        #expect(DisplayText.treePosition(code: nil) == nil)
        // every code of the council's domain has wording (except "unknown")
        let url = Bundle(for: BundleToken.self).url(forResource: "trees", withExtension: "json")
            ?? Bundle.main.url(forResource: "trees", withExtension: "json")
        if let url, let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let domain = json["accuracy"] as? [String: String] {
            for code in domain.keys where code != "un" {
                #expect(DisplayText.treePosition(code: code) != nil, "no wording for \(code)")
            }
        }
    }
}

private final class BundleToken {}

struct ScaleBarModelTests {
    @Test func picksTheLongestNiceLengthThatFits() throws {
        // z9 at 42.2° S: ≈ 113 m per point → 120 pt ≈ 13.6 km → 10 km
        let mpp = ScaleBarModel.metresPerPoint(zoom: 9, latitude: -42.2)
        #expect(abs(mpp - 113.25) < 0.5)
        let bar = try #require(ScaleBarModel(metresPerPoint: mpp, maxWidth: 120))
        #expect(bar.metres == 10_000)
        #expect(bar.label == "10\u{00A0}km")
        #expect(bar.width <= 120 && bar.width > 120 / 2.5)
    }

    @Test func stepsAreOneTwoFive() {
        for zoom in stride(from: 5.0, through: 19, by: 0.25) {
            let mpp = ScaleBarModel.metresPerPoint(zoom: zoom, latitude: -42)
            guard let bar = ScaleBarModel(metresPerPoint: mpp, maxWidth: 160) else { Issue.record("no bar"); continue }
            let mantissa = bar.metres / pow(10, floor(log10(bar.metres)))
            #expect([1.0, 2, 5].contains { abs($0 - mantissa) < 1e-9 }, "\(bar.metres)")
            #expect(bar.width <= 160 + 1e-9 && bar.width >= 160 / 2.5 - 1e-9)
        }
    }

    @Test func labelsMetresBelowAKilometre() throws {
        let bar = try #require(ScaleBarModel(metresPerPoint: 2.5, maxWidth: 120))
        #expect(bar.metres == 200)
        #expect(bar.label == "200\u{00A0}m")
        #expect(ScaleBarModel(metresPerPoint: .nan, maxWidth: 120) == nil)
    }
}
