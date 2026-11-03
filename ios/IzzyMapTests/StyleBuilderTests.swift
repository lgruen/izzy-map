import Foundation
import Testing
@testable import IzzyMap

@MainActor
struct StyleBuilderTests {
    static let communities = CommunityTable(byCode: [
        "DOB": Community(name: "(DOB) Eucalyptus obliqua dry forest", group: "Dry eucalypt forest and woodland",
                         color: "#38a800", outline: "#686868", label: "(DOB) Eucalyptus obliqua dry forest"),
        "AAP": Community(name: "(AAP) Alkaline pans", group: "Saltmarsh and wetland",
                         color: "#809fff", outline: "#686868", label: "(AAP) Alkaline pans"),
    ])
    nonisolated static let both = DataLocation(origin: .debugDirectory(URL(filePath: "/data")), archives: [
        .topo: URL(filePath: "/data/topo_tas.pmtiles"),
        .tasveg: URL(filePath: "/data/tasveg.pmtiles"),
    ])

    private func layerIDs(_ style: [String: Any]) -> [String] {
        (style["layers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func source(_ style: [String: Any], _ id: String) -> [String: Any]? {
        (style["sources"] as? [String: Any])?[id] as? [String: Any]
    }

    @Test func layerOrderWithAllArchives() {
        let style = StyleBuilder.style(data: Self.both, communities: Self.communities)
        #expect(layerIDs(style) == ["bg", "topo", "topo-live", "tasveg-fill", "tasveg-outline", "selected-outline"])
    }

    @Test func missingArchivesLeaveTheirLayersOut() {
        let style = StyleBuilder.style(data: .none, communities: Self.communities)
        #expect(layerIDs(style) == ["bg", "topo-live", "selected-outline"])
        #expect(source(style, "topo") == nil)
        #expect(source(style, "tasveg") == nil)
    }

    /// A `url:` (PMTiles) source gets zoom range, bounds and attribution from
    /// the archive; MapLibre ignores those keys there. The style controls only
    /// type, url and (raster) tileSize — so that is all it may say.
    @Test func packSourcesCarryOnlyWhatTheStyleControls() throws {
        let style = StyleBuilder.style(data: Self.both, communities: Self.communities)
        let topo = try #require(source(style, "topo"))
        #expect(Set(topo.keys) == ["type", "url", "tileSize"])
        #expect(topo["url"] as? String == "pmtiles://file:///data/topo_tas.pmtiles")
        #expect(topo["tileSize"] as? Int == 256)
        let tasveg = try #require(source(style, "tasveg"))
        #expect(Set(tasveg.keys) == ["type", "url"])
        #expect(tasveg["url"] as? String == "pmtiles://file:///data/tasveg.pmtiles")
    }

    /// A `tiles:` source is fully described by the style: z16–18 above the
    /// pack, bounded to the pack's header bounds, no attribution key (the
    /// app's credits sheet owns that).
    @Test func liveTopoTakesOverAboveThePack() throws {
        let style = StyleBuilder.style(data: Self.both, communities: Self.communities)
        let live = try #require(source(style, "topo-live"))
        #expect(Set(live.keys) == ["type", "tiles", "tileSize", "minzoom", "maxzoom", "bounds"])
        #expect(live["minzoom"] as? Int == 16)
        #expect(live["maxzoom"] as? Int == 18)
        #expect(live["bounds"] as? [Double] == [143.7, -43.87, 148.6, -39.19])
        // ArcGIS tile path: row (y) before column (x)
        #expect((live["tiles"] as? [String])?.first?.hasSuffix("/tile/{z}/{y}/{x}") == true)
        let host = try #require(URL(string: (live["tiles"] as? [String])?.first?
            .replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "") ?? "")?.host())
        #expect(StyleBuilder.liveHosts.contains(host))
        #expect(StyleBuilder.liveSourceIDs == ["topo-live"])
    }

    /// Every source a style can contain has a credit (or is the app's own drawing).
    @Test(arguments: [DataLocation.none, StyleBuilderTests.both])
    func everySourceHasACredit(_ data: DataLocation) throws {
        let style = StyleBuilder.style(data: data, communities: Self.communities)
        let ids = try #require((style["sources"] as? [String: Any])?.keys)
        for id in ids {
            #expect(Attribution.bySource[id] != nil || Attribution.uncreditedSources.contains(id),
                    "style source \(id) has no entry in Attribution.bySource")
        }
        // and no layer draws from a source the style lacks
        for layer in style["layers"] as? [[String: Any]] ?? [] {
            if let src = layer["source"] as? String { #expect(ids.contains(src)) }
        }
    }

    @Test func creditsKeepTheWebAppsWording() {
        #expect(Attribution.topo.line == "Topographic Basemap from theLIST © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.tasveg.line == "TASVEG 5.0 from theLIST © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.aerial.line == "Aerial photos from theLIST © State of Tasmania (CC BY-NC-ND 3.0 AU)")
        #expect(Attribution.tasmap.line == "Tasmap from theLIST © State of Tasmania (CC BY-NC-ND 3.0 AU)")
        #expect(Attribution.hillshade.line == "Hillshade from theLIST © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.geology.line == "Geology from Mineral Resources Tasmania © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.pre1750.line == "Pre-1750 vegetation: NVIS V7.0 © Commonwealth of Australia, DCCEEW (CC BY 4.0)")
        #expect(Attribution.trees.line == "Significant trees: City of Hobart (CC BY 4.0)")
        #expect(Attribution.aerial.terms == Attribution.unalteredTerms)
        #expect(Attribution.topo.terms == nil)
    }

    @Test func creditsFollowTheVisibleSources() {
        #expect(Attribution.credits(forSources: []) == [])
        #expect(Attribution.credits(forSources: ["selected"]) == [])
        // pack + live topo share one credit
        #expect(Attribution.credits(forSources: ["topo", "topo-live"]) == [Attribution.topo])
        #expect(Attribution.credits(forSources: ["topo-live", "tasveg", "selected"]) == [Attribution.tasveg, Attribution.topo])
    }

    @Test func backgroundIsOpaqueTopoGround() {
        let style = StyleBuilder.style(data: Self.both, communities: Self.communities)
        let bg = (style["layers"] as? [[String: Any]])?.first
        #expect((bg?["paint"] as? [String: Any])?["background-color"] as? String == "#eef3f0")
    }

    @Test func glyphsAreBundledAssets() {
        let style = StyleBuilder.style(data: .none, communities: .empty)
        #expect(style["glyphs"] as? String == "asset://glyphs/{fontstack}/{range}.pbf")
    }

    @Test func fillColoursComeFromTheTable() throws {
        let expression = try #require(StyleBuilder.colorMatch(Self.communities) as? [Any])
        #expect(expression.first as? String == "match")
        let rest = expression.dropFirst(2).compactMap { $0 as? String }
        #expect(rest == ["AAP", "#809fff", "DOB", "#38a800", "#c8c8c8"])
        #expect(StyleBuilder.colorMatch(.empty) as? String == "#c8c8c8")
    }

    @Test func liveTileFailuresAreFilteredAndPackFailuresKept() {
        #expect(MapLogging.isLiveTileFailure("[event]:Style [code]:-1 [message]:Failed to load tile 16/1/2=>16 for source topo-live: x"))
        #expect(MapLogging.isLiveTileFailure("Requesting: https://services.thelist.tas.gov.au/arcgis/x failed with error: y"))
        // a local pack failing is a real problem: keep it
        #expect(!MapLogging.isLiveTileFailure("[event]:Style [code]:-1 [message]:Failed to load tile 12/3/4=>12 for source topo: x"))
        #expect(!MapLogging.isLiveTileFailure("Failed to load tile 9/1/1=>9 for source tasveg: corrupt"))
        #expect(!MapLogging.isLiveTileFailure("Requesting: pmtiles://file:///data/topo_tas.pmtiles failed with error: z"))
        #expect(!MapLogging.isLiveTileFailure("Requesting: https://example.org/x failed with error: y"))
        #expect(!MapLogging.isLiveTileFailure("Failed to load glyph range 256-511 for font stack Noto Sans Regular"))
    }

    @Test func jsonIsValidAndPathsUnescaped() throws {
        let json = StyleBuilder.json(data: Self.both, communities: Self.communities)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["version"] as? Int == 8)
        #expect(json.contains("https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic"))
    }

    @Test func bundledTableLoads() throws {
        // the unit tests run inside the app, so Bundle.main is IzzyMap.app
        let table = try CommunityTable.load(bundle: .main)
        #expect(table.byCode.count >= 150)
        #expect(table["DOB"]?.color.hasPrefix("#") == true)
    }
}
