import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

/// "Show on map": a community soloed statewide, stepped through its
/// largest patches; Escape or × exits (camera back), a map tap ends it in
/// place. Reads the bundled where.bin / where_patches.json.
@MainActor
@Suite struct SpotlightTests {
    private func model() -> AppModel {
        let m = AppModel(data: .none, tables: StyleBuilderTests.tables)
        m.layers.overlay = .vegetation
        return m
    }

    @Test func showOnMapSolosAndFramesTheCore() throws {
        let m = model()
        m.showOnMap("DCO")
        let s = try #require(m.spotlight)
        #expect(s.code == "DCO" && s.step == 0)
        #expect(m.keyHighlight == "DCO")
        // the core is DCO's own (central and southern highlands), inside the state
        let b = s.bounds()
        #expect(b[0] >= 143.5 && b[2] <= 149 && b[1] >= -44 && b[3] <= -39.2 && b[0] < b[2] && b[1] < b[3])
        #expect(s.patchCount > 1000)
        #expect(s.patches.count == 10)
        #expect(s.maxZoom == Spotlight.overviewMaxZoom)
    }

    /// Leo's TestFlight case: DAM's frame was the union of every patch —
    /// nearly the whole state. Now 90 % of its area, the outliers framed out.
    @Test func damFramesItsCoreNotEveryOutlier() throws {
        let m = model()
        m.showOnMap("DAM")
        let s = try #require(m.spotlight)
        let core = s.bounds(aspect: 0.7)  // a phone's map, portrait
        let lons = s.cells.map { s.grid.centre($0.index).longitude }, lats = s.cells.map { s.grid.centre($0.index).latitude }
        let union = (lons.max()! - lons.min()!, lats.max()! - lats.min()!)
        #expect(core[3] - core[1] < 0.75 * union.1, "\(core)")
        #expect(core[2] - core[0] < union.0, "\(core)")
        // a landscape iPad view takes a different, wider core
        let wide = s.bounds(aspect: 1.6)
        #expect(wide != core)
    }

    @Test func fitZoomMatchesMapLibresWorld() {
        // the whole world's width fits 512 pt at z0; half of it at z1 in 512 pt
        #expect(abs(Spotlight.fitZoom([-180, -60, 180, 60], in: CGSize(width: 512, height: 4000))) < 1e-9)
        #expect(abs(Spotlight.fitZoom([0, -1, 180, 1], in: CGSize(width: 512, height: 4000)) - 1) < 1e-9)
    }

    /// The overlay below z11, from where.bin: full cells dissolved into
    /// regions (one casing each, never a keyline per cell), traces as a
    /// tint, a rare community's patches as ringed dots, the ten patch points.
    @Test func presenceOverlayGeoJSON() throws {
        let m = model()
        m.showOnMap("DMO")
        let dmo = try #require(m.spotlight)
        func collection(_ s: Spotlight) -> [[String: Any]] {
            let fc = Spotlight.presenceGeoJSON(cells: s.cells, grid: s.grid, patches: s.patches, patchCount: s.patchCount)
            return fc["features"] as? [[String: Any]] ?? []
        }
        func kinds(_ s: Spotlight) -> [String: Int] {
            var out: [String: Int] = [:]
            for f in collection(s) { out[(f["properties"] as? [String: Any])?["k"] as? String ?? "?", default: 0] += 1 }
            return out
        }
        // three trace cells, all three patches known: three ringed dots on
        // the patches (not 1.7 km squares), three patch points
        #expect(kinds(dmo) == ["spot": 3, "patch": 3])
        m.showOnMap("DAM")
        let dam = try #require(m.spotlight)
        let k = kinds(dam)
        let full = dam.cells.filter { $0.level >= 2 }.count
        // regions dissolve: far fewer polygons than cells, no line features
        #expect((k["cell"] ?? 0) > 0 && (k["cell"] ?? 0) < full / 3, "\(k)")
        #expect((k["trace"] ?? 0) > 0 && k["edge"] == nil && k["dot"] == nil && k["spot"] == nil && k["patch"] == 10)
        // the regions cover exactly the full cells' area
        let cellArea = dam.grid.lonStep * dam.grid.latStep
        func area(_ ring: [[Double]]) -> Double {
            zip(ring, ring.dropFirst()).reduce(0) { $0 + ($1.0[0] * $1.1[1] - $1.1[0] * $1.0[1]) } / 2
        }
        let regions = collection(dam).filter { ($0["properties"] as? [String: Any])?["k"] as? String == "cell" }
        let total = regions.reduce(0.0) { sum, f in
            let rings = (f["geometry"] as? [String: Any])?["coordinates"] as? [[[Double]]] ?? []
            return sum + rings.map(area).reduce(0, +)
        }
        #expect(abs(total / cellArea - Double(full)) < 1e-6)
    }

    @Test func fadeShowsTheSoloedTilesOnlyWhereTheyHoldRealPolygons() {
        let e = StyleBuilder.spotlightOpacity(code: "DAM", solo: 0.85, others: 0.1, from: 11)
        #expect(e[0] as? String == "step" && e[2] as? Double == 0.1 && e[3] as? Int == 11)
        let labels = StyleBuilder.spotlightOpacity(code: "DAM", solo: 1, others: 0.3, from: 0)
        #expect(labels[0] as? String == "case")
    }

    @Test func stepsStayInsideStatewidePlusThePatches() throws {
        let m = model()
        m.showOnMap("DCO")
        m.stepSpotlight(-1)
        #expect(m.spotlight?.step == 0)
        for _ in 0 ..< 15 { m.stepSpotlight(1) }
        let s = try #require(m.spotlight)
        #expect(s.step == s.patches.count)
        // a patch is framed whole (no clip around its label point)
        #expect(s.bounds() == s.patches.last!.bbox)
        #expect(s.maxZoom == Spotlight.patchMaxZoom)
        #expect(s.patchPoint?.longitude == s.patches.last?.p[0])
        // patches come largest first
        #expect(s.patches.map(\.ha) == s.patches.map(\.ha).sorted(by: >))
    }

    @Test func escapeExitsAndRestoresTheCamera() {
        let m = model()
        m.showOnMap("DCO")
        #expect(m.escapeStep == .clearHighlight)
        m.escape()
        #expect(m.spotlight == nil)
        #expect(m.keyHighlight == nil)
        #expect(m.spotlightRestoresCamera)
    }

    @Test func theCardStaysAndEscapeClosesItFirst() {
        let m = model()
        m.selectCommunity(code: "DCO", sourceName: nil)
        m.showOnMap("DCO")
        #expect(m.selection != nil)
        m.escape()
        #expect(m.selection == nil)
        #expect(m.spotlight != nil)
        m.escape()
        #expect(m.spotlight == nil)
    }

    @Test func aMapTapEndsItWhereSheIs() {
        let m = model()
        m.showOnMap("DCO")
        m.selectCommunity(code: "DOB", sourceName: nil)
        #expect(m.spotlight == nil)
        #expect(!m.spotlightRestoresCamera)
        m.showOnMap("DCO")
        m.exitSpotlight()
        #expect(m.spotlightRestoresCamera)
    }

    @Test func anOverlayChangeEndsIt() {
        let m = model()
        m.showOnMap("DCO")
        m.layers.overlay = .geology
        #expect(m.spotlight == nil)
    }

    /// Finding 11: a search pick (a new view) ends the spotlight AND its
    /// own same-community highlight.
    @Test func aSearchPickEndsItAndItsHighlight() {
        let m = model()
        m.showOnMap("DCO")
        #expect(m.keyHighlight == "DCO")
        m.search.onPick()
        #expect(m.spotlight == nil)
        #expect(m.keyHighlight == nil)
        #expect(!m.spotlightRestoresCamera)
    }

    @Test func pillAreasNeverTruncateAndRoundToTwoFigures() {
        #expect(SpotlightPill.area(4412) == 4400.formatted())
        #expect(SpotlightPill.area(3.46) == 3.5.formatted())
    }
}
