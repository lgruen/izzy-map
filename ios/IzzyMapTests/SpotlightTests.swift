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

    @Test func showOnMapSolosAndFramesTheStatewideExtent() throws {
        let m = model()
        m.showOnMap("DCO")
        let s = try #require(m.spotlight)
        #expect(s.code == "DCO" && s.step == 0)
        #expect(m.keyHighlight == "DCO")
        // the extent is DCO's own (central and southern highlands), inside the state
        let b = s.bounds
        #expect(b[0] >= 143.5 && b[2] <= 149 && b[1] >= -44 && b[3] <= -39.2 && b[0] < b[2] && b[1] < b[3])
        #expect(s.patchCount > 1000)
        #expect(s.patches.count == 10)
    }

    @Test func stepsStayInsideStatewidePlusThePatches() throws {
        let m = model()
        m.showOnMap("DCO")
        m.stepSpotlight(-1)
        #expect(m.spotlight?.step == 0)
        for _ in 0 ..< 15 { m.stepSpotlight(1) }
        let s = try #require(m.spotlight)
        #expect(s.step == s.patches.count)
        #expect(s.bounds == s.patches.last?.bbox)
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

    @Test func padsTinyPatchesAndKeepsBigOnes() {
        let tiny = Spotlight.padded([147, -42, 147.001, -41.999])
        #expect(tiny[2] - tiny[0] >= 0.025 - 1e-9)
        let big = Spotlight.padded([146, -43, 148, -41])
        #expect(big == [146, -43, 148, -41])
    }
}
