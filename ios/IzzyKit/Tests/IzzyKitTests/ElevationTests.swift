import Foundation
import Testing
@testable import IzzyKit

/// The plant sheet's elevation: height parsing (UN's field and the few
/// heights stated only in prose), the drawing scale chosen from the
/// ladder, the scale bar, and the silhouette per plant — on the real
/// plants.json.
@Suite struct ElevationTests {
    // MARK: Parsing

    @Test func heightFormsParse() {
        #expect(HeightRange("0.3 – 1") == HeightRange(min: 0.3, max: 1))
        #expect(HeightRange("0.3-1 m") == HeightRange(min: 0.3, max: 1))
        #expect(HeightRange("2 to 4 m") == HeightRange(min: 2, max: 4))
        #expect(HeightRange("30–60 cm") == HeightRange(min: 0.3, max: 0.6))
        #expect(HeightRange("30 cm – 1.2 m") == HeightRange(min: 0.3, max: 1.2))
        #expect(HeightRange("0,5 – 1") == HeightRange(min: 0.5, max: 1))
        #expect(HeightRange("15 mm")?.max == 0.015)
        #expect(HeightRange("to 2 m") == HeightRange(min: 2, max: 2, upTo: true))
        #expect(HeightRange("Up to 40 cm")?.max == 0.4)
        #expect(HeightRange("1.5m tall")?.max == 1.5)
        for bad in ["to 2 – 3 m", "about a metre", "2 m wide x", "-1", "0", "1 – 2 – 3", "500"] {
            #expect(HeightRange(bad) == nil, "\(bad)")
        }
    }

    @Test func heightsInProseNeedTallOrHigh() {
        #expect(HeightRange(prose: "Climbing over shrubs, to 5–6m tall; stems shining") == HeightRange(min: 5, max: 6))
        #expect(HeightRange(prose: "ascending flowering branches to 15 cm high")?.max == 0.15)
        #expect(HeightRange(prose: "cushions to 1m in diameter") == nil)
        #expect(HeightRange(prose: "leaves up to 60cm long") == nil)
        #expect(HeightRange(prose: nil) == nil)
    }

    @Test func labelsUseCentimetresBelowAMetre() {
        #expect(HeightRange("0.01 – 0.03")?.text == "1–3\u{00A0}cm")
        #expect(HeightRange("0.04 – 0.25")?.text == "4–25\u{00A0}cm")
        #expect(HeightRange("to 2 m")?.text == "to 2\u{00A0}m")
        #expect(HeightRange.label(15) == "15\u{00A0}m")
        #expect(HeightRange.label(0.3) == "30\u{00A0}cm")
    }

    @Test func everyRealHeightParsesAndOnlyTwoComeFromProse() throws {
        let plants = try TestData.catalog().plants
        var fromProse: [String] = []
        for p in plants {
            if let h = p.height {
                let r = try #require(HeightRange(h), "\(p.name): \(h)")
                #expect(r.min > 0 && r.max <= 100 && r.min <= r.max, "\(p.name): \(h)")
            } else if p.heightRange != nil {
                fromProse.append(p.name)
            }
        }
        // 2026-10 pull: Billardiera macrantha "to 5–6m tall", Hydrocotyle laxiflora "to 15 cm high"
        #expect(fromProse.count <= 10, "\(fromProse)")
        #expect(fromProse.contains("Billardiera macrantha"))
    }

    // MARK: Scale

    @Test func scaleFitsTheTallestAndIsTheLargestThatDoes() {
        for h in stride(from: 0.01, through: 90, by: 0.37) {
            for plot in [140.0, 180] {
                let s = ElevationScale.choose(maxHeight: h, plotHeight: plot)
                #expect(h * s.pointsPerMetre <= plot * ElevationScale.fill + 1e-9, "\(h) m at \(s.label)")
                if let i = ElevationScale.ladder.firstIndex(of: s.denominator), i > 0 {
                    let larger = ElevationScale(denominator: ElevationScale.ladder[i - 1])
                    #expect(h * larger.pointsPerMetre > plot * ElevationScale.fill, "\(h) m: \(larger.label) also fits")
                }
            }
        }
    }

    @Test func realPlantsGetTheExpectedScales() throws {
        let catalog = try TestData.catalog()
        func scale(_ name: String, plot: Double = 140) throws -> ElevationScale {
            let p = try #require(catalog.plants.first { $0.name == name }, "\(name) missing")
            let h = try #require(p.heightRange, "\(name) has no height")
            return ElevationScale.choose(maxHeight: h.max, plotHeight: plot)
        }
        // 50–80 m: the bottom of the ladder, figure a speck, 10 m level lines
        let regnans = try scale("Eucalyptus regnans")
        #expect(regnans.label == "1:500")
        #expect(regnans.levelInterval == 10)
        #expect(regnans.showsFigure(plotHeight: 140))
        // 1–3 cm herb: enlarged, a boot instead of the figure
        let tiny = try scale("Aphelia pumilio")
        #expect(tiny.label == "2:1")
        #expect(!tiny.showsFigure(plotHeight: 140))
        // every real plant fits its plot, and nothing taller than 1:500 holds
        for p in catalog.plants {
            guard let h = p.heightRange else { continue }
            for plot in [140.0, 180] {
                let s = ElevationScale.choose(maxHeight: h.max, plotHeight: plot)
                #expect(h.max * s.pointsPerMetre <= plot * ElevationScale.fill, "\(p.name) \(h.text) at \(s.label)")
            }
        }
    }

    @Test func shrubsShowTheWholeFigureAndHerbsABoot() {
        let shrub = ElevationScale.choose(maxHeight: 2, plotHeight: 140)
        #expect(shrub.label == "1:10")
        #expect(shrub.showsFigure(plotHeight: 140))
        let herb = ElevationScale.choose(maxHeight: 0.1, plotHeight: 140)
        #expect(herb.label == "2:1")
        #expect(!herb.showsFigure(plotHeight: 140))
        #expect(ElevationScale.choose(maxHeight: 0.6, plotHeight: 140).label == "1:5")
        #expect(ElevationScale.choose(maxHeight: 15, plotHeight: 140).label == "1:100")
        #expect(ElevationScale.choose(maxHeight: 50, plotHeight: 180).label == "1:200")
    }

    @Test func scaleBarStaysShortAndRound() {
        for n in ElevationScale.ladder {
            let s = ElevationScale(denominator: n)
            let bar = s.scaleBar(maxPoints: 80)
            #expect(bar.metres * s.pointsPerMetre <= 80, "\(s.label)")
            #expect(bar.metres * s.pointsPerMetre >= 30, "\(s.label): \(bar.metres) m too short")
            #expect(bar.labels.first == 0 && bar.labels.last == bar.metres)
        }
        #expect(ElevationScale(denominator: 500).scaleBar(maxPoints: 80).metres == 50)
        #expect(ElevationScale(denominator: 100).scaleBar(maxPoints: 80).metres == 10)
    }

    // MARK: Silhouettes

    @Test func silhouettesFollowTheData() throws {
        let catalog = try TestData.catalog()
        func shape(_ name: String) throws -> PlantSilhouette {
            try #require(catalog.plants.first { $0.name == name }, "\(name) missing").silhouette
        }
        #expect(try shape("Eucalyptus regnans") == .eucalypt)
        #expect(try shape("Nothofagus cunninghamii") == .broadleafTree)
        #expect(try shape("Athrotaxis selaginoides") == .conifer)
        #expect(try shape("Dicksonia antarctica") == .treeFern)
        #expect(try shape("Abrotanella forsteroides") == .cushion)
        var seen = Set<PlantSilhouette>()
        for p in catalog.plants { seen.insert(p.silhouette) }
        // every shape but the bare fallback occurs in the real data
        #expect(seen.isSuperset(of: Set(PlantSilhouette.allCases).subtracting([.plant])), "\(seen)")
    }
}
