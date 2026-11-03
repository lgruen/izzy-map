import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

@MainActor
struct StyleBuilderTests {
    nonisolated static let communities: CommunityTable = try! JSONDecoder().decode(CommunityTable.self, from: Data("""
        {"DOB": {"name": "(DOB) Eucalyptus obliqua dry forest", "group": "Dry eucalypt forest and woodland",
                 "color": "#38a800", "outline": "#686868", "label": "(DOB) Eucalyptus obliqua dry forest"},
         "AAP": {"name": "(AAP) Alkaline pans", "group": "Saltmarsh and wetland",
                 "color": "#809fff", "outline": "#686868", "label": "(AAP) Alkaline pans"}}
        """.utf8))
    nonisolated static let tables = MapTables(communities: communities)
    /// The real bundled tables (the unit tests run inside the app).
    nonisolated static let bundled: MapTables = {
        guard let data = BundledData.inBundle() else { return .empty }
        return MapTables(communities: (try? data.communities()) ?? [:], geology: (try? data.geologyUnits()) ?? [:],
                         pre1750: (try? data.pre1750Units()) ?? [:], trees: try? data.trees())
    }()

    nonisolated static func location(_ archives: [Archive]) -> DataLocation {
        DataLocation(origin: .debugDirectory(URL(filePath: "/data")),
                     archives: Dictionary(uniqueKeysWithValues: archives.map { ($0, URL(filePath: "/data/\($0.fileName)")) }))
    }
    nonisolated static let all = location(Archive.allCases)
    nonisolated static let both = location([.topo, .tasveg])

    private func layerIDs(_ style: [String: Any]) -> [String] {
        (style["layers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private func layer(_ style: [String: Any], _ id: String) -> [String: Any]? {
        (style["layers"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id }
    }

    private func source(_ style: [String: Any], _ id: String) -> [String: Any]? {
        (style["sources"] as? [String: Any])?[id] as? [String: Any]
    }

    private func style(_ state: LayerState = .default, _ data: DataLocation = StyleBuilderTests.all,
                       tables: MapTables = StyleBuilderTests.bundled) -> [String: Any] {
        StyleBuilder.style(state: state, data: data, tables: tables)
    }

    private static let selection = StyleBuilder.LayerID.selection + []

    // MARK: Layer order

    @Test func defaultStackIsTopoThenVegetationThenSelection() {
        #expect(layerIDs(style()) == ["bg", "topo", "topo-live", "tasveg-fill", "tasveg-boundary", "same-community",
                                      "tasveg-label", "tasveg-label-15", "tasveg-label-16", "tasveg-label-17"] + Self.selection)
    }

    /// Trees sit on top of every overlay and its labels; only the selection
    /// layers come after them (a selected tree area's outline must not be
    /// overpainted by the trees' fill).
    @Test func treesThenSelectionAreLast() {
        var state = LayerState.default
        state.trees = true
        state.relief = true
        let ids = layerIDs(style(state))
        let trees = ["trees-area-fill", "trees-area-line", "trees-cluster", "trees-cluster-count", "trees-point", "trees-label"]
        #expect(Array(ids.suffix(trees.count + Self.selection.count)) == trees + Self.selection)
        // relief: above the fill, below every line and label
        #expect(ids.firstIndex(of: "relief")! == ids.firstIndex(of: "tasveg-fill")! + 1)
        #expect(ids.firstIndex(of: "relief")! < ids.firstIndex(of: "tasveg-boundary")!)
    }

    @Test func hiddenLayersAndTheirSourcesAreLeftOut() {
        let s = style()
        let sources = Set((s["sources"] as? [String: Any])?.keys.map { $0 } ?? [])
        #expect(sources == ["topo", "topo-live", "tasveg", "highlight", "selected"])
        for hidden in ["aerial", "tasmap", "geology", "pre1750", "relief", "trees-points", "season-2026"] {
            #expect(!sources.contains(hidden))
        }
    }

    @Test func seasonsStackOldestToNewestUpToTheCutoffOverTopo() throws {
        var state = LayerState.default
        state.base = .seasons
        state.season = 3
        let ids = layerIDs(style(state))
        #expect(Array(ids.prefix(8)) == ["bg", "topo", "topo-live", "season-2020", "season-2021", "season-2022",
                                         "season-2023", "season-live"])
        #expect(!ids.contains("season-2024"))
        let s = style(state)
        for id in ["season-2020", "season-2023", "season-live"] {
            let fade = (layer(s, id)?["paint"] as? [String: Any])?["raster-fade-duration"] as? Int
            #expect(fade == 0, "\(id) must not cross-fade")
        }
        // the newest season shown streams from LIST above its pack only
        let live = try #require(source(s, "season-live"))
        #expect((live["tiles"] as? [String])?.first?.contains("/AerialPhoto2023/MapServer/tile/{z}/{y}/{x}") == true)
        #expect(live["minzoom"] as? Int == 16)
    }

    /// Without its pack the top season streams from tile z11 only (no
    /// statewide 404s for a 6–15 % patchwork) — the caption's rule too.
    @Test func aSeasonNotOnTheDeviceStreamsFromZ11() throws {
        var state = LayerState.default
        state.base = .seasons
        let s = style(state, Self.location([.topo, .season2020]))
        #expect(layerIDs(s).prefix(5) == ["bg", "topo", "topo-live", "season-2020", "season-live"])
        #expect(try #require(source(s, "season-live"))["minzoom"] as? Int == SeasonCoverage.liveMinZoomWithoutPack)
    }

    /// Offline (no network path) the live LIST sources are left out: the
    /// packs are the map, stretched above z15, and nothing is requested.
    @Test func offlineLeavesEveryLiveSourceOut() {
        for base in BaseMap.allCases {
            var state = LayerState.default
            state.base = base
            for data in [Self.all, Self.both, DataLocation.none] {
                let s = StyleBuilder.style(state: state, data: data, tables: .empty, online: false)
                let sources = (s["sources"] as? [String: Any]) ?? [:]
                #expect(Set(sources.keys).isDisjoint(with: StyleBuilder.liveSourceIDs), "\(base)")
                #expect(!sources.values.contains { ($0 as? [String: Any])?["tiles"] != nil })
            }
        }
        // online, the same states stream
        var aerial = LayerState.default
        aerial.base = .aerial
        #expect(source(StyleBuilder.style(state: aerial, data: Self.all, tables: .empty, online: true), "aerial-live") != nil)
    }

    /// Topo stays under the seasons and under an aerial / Tasmap base whose
    /// pack isn't installed (offline: a usable map, not a flat sea).
    @Test func topoUnderlayRules() {
        var aerial = LayerState.default
        aerial.base = .aerial
        #expect(!layerIDs(style(aerial)).contains("topo"))
        #expect(layerIDs(style(aerial)).prefix(3) == ["bg", "aerial", "aerial-live"])
        let noAerial = Self.location([.topo, .tasveg])
        #expect(layerIDs(style(aerial, noAerial)).prefix(4) == ["bg", "topo", "topo-live", "aerial-live"])
        var tasmap = LayerState.default
        tasmap.base = .tasmap
        #expect(layerIDs(style(tasmap)).prefix(3) == ["bg", "tasmap", "tasmap-live"])
        #expect(layerIDs(style(tasmap, noAerial)).prefix(4) == ["bg", "topo", "topo-live", "tasmap-live"])
    }

    @Test func backgroundFollowsTheBaseOnceItsPackIsLocal() {
        func bg(_ base: BaseMap, _ data: DataLocation) -> String? {
            var state = LayerState.default
            state.base = base
            return (layer(style(state, data), "bg")?["paint"] as? [String: Any])?["background-color"] as? String
        }
        // over topo: paper white, as LIST composites its own map
        #expect(bg(.topo, Self.all) == "#ffffff")
        #expect(bg(.seasons, Self.all) == "#ffffff")
        #expect(bg(.aerial, Self.all) == "#1e525f")
        #expect(bg(.tasmap, Self.all) == "#aae0fc")
        #expect(bg(.aerial, Self.both) == "#ffffff")
        #expect(bg(.tasmap, .none) == "#ffffff")
    }

    /// LIST water at z14–15 (the packs' deepest levels) is rgb(176,216,216)
    /// at alpha 207; live z16+ water is opaque rgb(191,223,223) (measured
    /// 2026-11-03). Over the ground, the pack's water must be the live
    /// colour within a level: no step where live tiles take over (online,
    /// map z14.5) and the same water offline.
    @Test func packWaterMatchesLiveWater() throws {
        let ground = try #require(MapColour.components(StyleBuilder.topoBackground))
        let water = (176.0, 216.0, 216.0), a = 207.0 / 255
        let pack = (water.0 * a + ground.0 * 255 * (1 - a), water.1 * a + ground.1 * 255 * (1 - a),
                    water.2 * a + ground.2 * 255 * (1 - a))
        let live = (191.0, 223.0, 223.0)
        #expect(abs(pack.0 - live.0) < 1 && abs(pack.1 - live.1) < 1 && abs(pack.2 - live.2) < 1)
    }

    // MARK: Sources

    /// A `url:` (PMTiles) source gets zoom range, bounds and attribution from
    /// the archive; MapLibre ignores those keys there.
    @Test func packSourcesCarryOnlyWhatTheStyleControls() throws {
        let s = style()
        let topo = try #require(source(s, "topo"))
        #expect(Set(topo.keys) == ["type", "url", "tileSize"])
        #expect(topo["url"] as? String == "pmtiles://file:///data/topo_tas.pmtiles")
        let tasveg = try #require(source(s, "tasveg"))
        #expect(Set(tasveg.keys) == ["type", "url"])
    }

    /// Live LIST sources: z16+ above a local pack, every zoom without one;
    /// bounded to the packs' bounds; ArcGIS row-before-column paths.
    @Test(arguments: [BaseMap.topo, .aerial, .tasmap])
    func liveSourcesTakeOverAboveThePack(_ base: BaseMap) throws {
        var state = LayerState.default
        state.base = base
        let id = "\(base.rawValue)-live"
        let live = try #require(source(style(state), id))
        #expect(Set(live.keys) == ["type", "tiles", "tileSize", "minzoom", "maxzoom", "bounds"])
        #expect(live["minzoom"] as? Int == 16)
        #expect(live["maxzoom"] as? Int == (base == .tasmap ? 16 : 18))
        #expect(live["bounds"] as? [Double] == [143.7, -43.87, 148.6, -39.19])
        #expect((live["tiles"] as? [String])?.first?.hasSuffix("/tile/{z}/{y}/{x}") == true)
        #expect(StyleBuilder.liveSourceIDs.contains(id))
        let streaming = try #require(source(style(state, .none), id))
        #expect(streaming["minzoom"] as? Int == 0)
    }

    // MARK: Overlays and strength

    private func opacity(_ s: [String: Any], _ id: String) -> Double? {
        (layer(s, id)?["paint"] as? [String: Any])?["fill-opacity"] as? Double
    }

    @Test func strengthFollowsTheBase() {
        var state = LayerState.default
        // Light by default (decided 2026-11-03)
        #expect(opacity(style(state), "tasveg-fill") == 0.30)
        state.strength = .full
        #expect(opacity(style(state), "tasveg-fill") == 0.55)
        state.strength = .light
        #expect(opacity(style(state), "tasveg-fill") == 0.30)
        state.base = .aerial
        #expect(opacity(style(state), "tasveg-fill") == 0.20)
        state.base = .tasmap
        state.strength = .full
        #expect(opacity(style(state), "tasveg-fill") == 0.50)
    }

    @Test func outlinesDrawTheEdgeBandAndKeepTheFillTappable() {
        var state = LayerState.default
        state.strength = .outlines
        let s = style(state)
        #expect(opacity(s, "tasveg-fill") == 0)
        let ids = layerIDs(s)
        #expect(ids.contains("tasveg-band"))
        #expect(ids.firstIndex(of: "tasveg-band")! < ids.firstIndex(of: "tasveg-boundary")!)
        // one band, 2.5 pt at 70 %, starting AT the boundary (offset = half
        // the width, inward): nothing spills outside the polygon
        let paint = layer(s, "tasveg-band")?["paint"] as? [String: Any]
        #expect(paint?["line-opacity"] as? Double == 0.7)
        #expect((paint?["line-width"] as? [Any])?.last as? Double == 2.5)
        #expect((paint?["line-offset"] as? [Any])?.last as? Double == 1.25)
    }

    /// No band reads as ink: dark official colours are lightened to a
    /// luminance floor; light ones pass untouched.
    @Test func bandColoursAreCappedInDarkness() throws {
        #expect(StyleBuilder.bandColor("#98FE00") == "#98FE00")
        let wdb = StyleBuilder.bandColor("#326565")
        #expect(wdb != "#326565")
        func lum(_ hex: String) throws -> Double {
            let c = try #require(MapColour.components(hex))
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }
        #expect(try lum(wdb) >= StyleBuilder.bandMinLuminance - 0.01)
        #expect(try lum(wdb) < StyleBuilder.bandMinLuminance + 0.02, "lightened just enough")
        #expect(try lum(StyleBuilder.bandColor("#000000")) >= StyleBuilder.bandMinLuminance - 0.01)
        // the band match uses them; the fill keeps the official colour
        var state = LayerState.default
        state.strength = .outlines
        let wdbTable = try JSONDecoder().decode(CommunityTable.self, from: Data(
            ##"{"WDB":{"name":"(WDB) x","group":"g","color":"#326565","outline":"#000000","label":"WDB"}}"##.utf8))
        let tables = MapTables(communities: wdbTable)
        let s = StyleBuilder.style(state: state, data: Self.all, tables: tables)
        let band = (layer(s, "tasveg-band")?["paint"] as? [String: Any])?["line-color"] as? [Any]
        #expect(band?.contains { $0 as? String == wdb } == true)
        let fill = (layer(s, "tasveg-fill")?["paint"] as? [String: Any])?["fill-color"] as? [Any]
        #expect(fill?.contains { $0 as? String == "#326565" } == true)
    }

    /// Pre-1750 has no boundaries, so Outlines falls back to Light.
    @Test func pre1750OutlinesFallBackToLight() {
        var state = LayerState.default
        state.overlay = .pre1750
        state.strength = .outlines
        #expect(state.effectiveStrength == .light)
        let s = style(state)
        #expect(opacity(s, "pre1750-fill") == 0.30)
        // cell edges are not antialiased (no 1 px outline grid)
        #expect((layer(s, "pre1750-fill")?["paint"] as? [String: Any])?["fill-antialias"] as? Bool == false)
        #expect(!layerIDs(s).contains { $0.hasPrefix("pre1750-") && $0 != "pre1750-fill" })
        #expect(!layerIDs(s).contains("tasveg-fill"))
    }

    @Test func geologyGetsBoundariesFromZ9() throws {
        var state = LayerState.default
        state.overlay = .geology
        let boundary = try #require(layer(style(state), "geology-boundary"))
        #expect(boundary["minzoom"] as? Int == 9)
        #expect(layer(style(state), "tasveg-label") == nil)
    }

    @Test func boundariesTurnPaperWhiteOverPhotos() {
        func colour(_ base: BaseMap) -> String? {
            var state = LayerState.default
            state.base = base
            return (layer(style(state), "tasveg-boundary")?["paint"] as? [String: Any])?["line-color"] as? String
        }
        #expect(colour(.topo) == StyleBuilder.graphite)
        #expect(colour(.aerial) == StyleBuilder.paper)
        #expect(colour(.seasons) == StyleBuilder.paper)
    }

    @Test func noLayerAnimates() throws {
        let transition = try #require(style()["transition"] as? [String: Int])
        #expect(transition["duration"] == 0)
    }

    // MARK: Text

    /// Map text must stay Latin-1 (glyphs ship as 0-255.pbf only): tree
    /// labels come from the register's `label`, never the botanical `name`.
    @Test func treeLabelsAreLatin1() throws {
        let trees = try #require(Self.bundled.trees)
        let geojson = StyleBuilder.treePointsGeoJSON(trees)
        let features = try #require(geojson["features"] as? [[String: Any]])
        #expect(features.count == trees.points.count)
        for f in features {
            let label = (f["properties"] as? [String: Any])?["label"] as? String ?? ""
            #expect(MapText.isLatin1(label), "non-Latin-1 tree label \(label)")
        }
        var state = LayerState.default
        state.trees = true
        let labelLayer = try #require(layer(style(state), "trees-label"))
        #expect(((labelLayer["layout"] as? [String: Any])?["text-field"] as? [String]) == ["get", "label"])
        #expect(labelLayer["minzoom"] as? Int == 17)
        // one label per register entry, "×n" for a stand
        let labels = features.compactMap { ($0["properties"] as? [String: Any])?["label"] as? String }.filter { !$0.isEmpty }
        #expect(labels.count <= trees.refs.count)
        #expect(labels.count == Set(features.compactMap { f -> String? in
            let p = f["properties"] as? [String: Any]
            return (p?["label"] as? String).flatMap { $0.isEmpty ? nil : p?["ref"] as? String }
        }).count, "at most one label per ref")
        #expect(labels.contains { $0.contains(" ×") })
        let points = try #require(source(style(state), "trees-points"))
        #expect(points["cluster"] as? Bool == true)
        #expect(points["clusterRadius"] as? Int == 32)
        #expect(points["clusterMaxZoom"] as? Int == 14)
    }

    @Test func communityCodesComeFromTheLabelPoints() throws {
        let label = try #require(layer(style(), "tasveg-label"))
        #expect(label["source-layer"] as? String == "tasveg_labels")
        #expect(label["minzoom"] as? Int == 14)
        #expect(label["maxzoom"] as? Int == 15)
        // a code shows once the polygon's inscribed circle can hold it:
        // r ≥ 43 m at z14, halving per zoom step
        func threshold(_ id: String) -> Double? { (layer(style(), id)?["filter"] as? [Any])?.last as? Double }
        #expect(threshold("tasveg-label") == 43)
        #expect(threshold("tasveg-label-15") == 21.5)
        #expect(threshold("tasveg-label-17") == 5.375)
        #expect(layer(style(), "tasveg-label-17")?["maxzoom"] == nil)
        // the id outline starts where the source polygons do (TASVEG z11;
        // geology and pre-1750 carry ids at every zoom)
        #expect(layer(style(), "selected-feature")?["minzoom"] as? Int == 11)
        for overlay in [Overlay.geology, .pre1750] {
            var state = LayerState.default
            state.overlay = overlay
            #expect(layer(style(state), "selected-feature")?["minzoom"] as? Int == 0, "\(overlay)")
            #expect(layer(style(state), "selected-feature-halo") == nil, "red, no casing (decided 2026-11-03)")
            let paint = layer(style(state), "selected-feature")?["paint"] as? [String: Any]
            #expect(paint?["line-color"] as? String == "#FF3B30")
            #expect(paint?["line-width"] as? Double == 3)
        }
        // community codes are three capitals: Latin-1
        #expect(Self.bundled.communities.keys.allSatisfy(MapText.isLatin1))
    }

    @Test func selectionFiltersCarryTheFeatureAndItsCommunity() throws {
        let s = StyleBuilder.style(state: .default, data: Self.all, tables: Self.bundled,
                                   selection: SelectionStyle(featureID: 42, community: "DOB"))
        // the selection lines and dashes draw from their own copy of the
        // overlay archive: a tap's filter change re-lays out only that
        // source's tiles, never the fills, boundaries and labels
        let feature = try #require(layer(s, "selected-feature"))
        #expect(feature["source"] as? String == "highlight")
        #expect((source(s, "highlight")?["url"] as? String) == (source(s, "tasveg")?["url"] as? String))
        #expect(layer(s, "same-community")?["source"] as? String == "highlight")
        for id in ["tasveg-fill", "tasveg-boundary", "tasveg-label"] {
            #expect(layer(s, id)?["source"] as? String == "tasveg")
        }
        #expect((feature["filter"] as? [Any])?.last as? UInt64 == 42)
        let same = try #require(layer(s, "same-community"))
        #expect((same["filter"] as? [Any])?.last as? String == "DOB")
        #expect(StyleBuilder.sameCommunityFilter(nil).last as? String == "")
    }

    @Test func glyphsAreBundledAssets() {
        #expect(style()["glyphs"] as? String == "asset://glyphs/{fontstack}/{range}.pbf")
    }

    @Test func fillColoursComeFromTheTable() throws {
        let expression = try #require(StyleBuilder.colorMatch(Self.communities) as? [Any])
        #expect(expression.first as? String == "match")
        let rest = expression.dropFirst(2).compactMap { $0 as? String }
        #expect(rest == ["AAP", "#809fff", "DOB", "#38a800", "#c8c8c8"])
        #expect(StyleBuilder.colorMatch([:]) as? String == "#c8c8c8")
    }

    @Test func jsonIsValidAndPathsUnescaped() throws {
        var state = LayerState.default
        state.trees = true
        let json = StyleBuilder.json(state: state, data: Self.both, tables: Self.bundled)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["version"] as? Int == 8)
        #expect(json.contains("https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic"))
    }

    // MARK: Attribution

    /// Every source any layer state can put in the style has a credit (or is
    /// the app's own drawing), and no layer draws from a missing source.
    @Test func everySourceOfEveryStateHasACredit() throws {
        for base in BaseMap.allCases {
            for overlay in Overlay.allCases {
                for data in [DataLocation.none, Self.all, Self.both] {
                    var state = LayerState.default
                    state.base = base
                    state.overlay = overlay
                    state.trees = true
                    state.relief = true
                    state.season = 6
                    let s = style(state, data)
                    let ids = Set(try #require((s["sources"] as? [String: Any])?.keys))
                    for id in ids {
                        #expect(Attribution.bySource[id] != nil || Attribution.uncreditedSources.contains(id),
                                "style source \(id) has no entry in Attribution.bySource")
                    }
                    for layer in s["layers"] as? [[String: Any]] ?? [] {
                        if let src = layer["source"] as? String { #expect(ids.contains(src)) }
                    }
                }
            }
        }
    }

    @Test func creditsKeepTheWebAppsWording() {
        #expect(Attribution.topo.line == "Topographic Basemap from theLIST © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.tasveg.line == "TASVEG 5.0 from theLIST © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.aerial.line == "Aerial photos from theLIST © State of Tasmania (CC BY-NC-ND 3.0 AU)")
        #expect(Attribution.tasmap.line == "Tasmap from theLIST © State of Tasmania (CC BY-NC-ND 3.0 AU)")
        #expect(Attribution.hillshade.line == "Relief shading from Hillshade Grey © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.geology.line == "Geology from Mineral Resources Tasmania © State of Tasmania (CC BY 3.0 AU)")
        #expect(Attribution.pre1750.line == "Pre-1750 vegetation: NVIS V7.0 © Commonwealth of Australia, DCCEEW (CC BY 4.0)")
        #expect(Attribution.trees.line == "Significant trees: City of Hobart (CC BY 4.0)")
        #expect(Attribution.aerial.terms == Attribution.unalteredTerms)
        #expect(Attribution.seasons.terms == Attribution.unalteredTerms)
        #expect(Attribution.hillshade.terms?.contains("relief shading") == true)
        #expect(Attribution.topo.terms == nil)
    }

    @Test func creditsFollowTheVisibleSources() {
        #expect(Attribution.credits(forSources: []) == [])
        #expect(Attribution.credits(forSources: ["selected"]) == [])
        #expect(Attribution.credits(forSources: ["topo", "topo-live"]) == [Attribution.topo])
        #expect(Attribution.credits(forSources: ["season-2020", "season-2024", "season-live"]) == [Attribution.seasons])
        #expect(Attribution.credits(forSources: ["aerial", "aerial-live"]).first?.licence == .ccByNcNd3AU)
    }

    @Test func liveTileFailuresAreFilteredAndPackFailuresKept() {
        #expect(MapLogging.isLiveTileFailure("[event]:Style [code]:-1 [message]:Failed to load tile 16/1/2=>16 for source topo-live: x"))
        #expect(MapLogging.isLiveTileFailure("Failed to load tile 16/1/2=>16 for source season-live: x"))
        #expect(MapLogging.isLiveTileFailure("Requesting: https://services.thelist.tas.gov.au/arcgis/x failed with error: y"))
        #expect(!MapLogging.isLiveTileFailure("[event]:Style [code]:-1 [message]:Failed to load tile 12/3/4=>12 for source topo: x"))
        #expect(!MapLogging.isLiveTileFailure("Failed to load tile 9/1/1=>9 for source tasveg: corrupt"))
        #expect(!MapLogging.isLiveTileFailure("Requesting: pmtiles://file:///data/topo_tas.pmtiles failed with error: z"))
        #expect(!MapLogging.isLiveTileFailure("Failed to load glyph range 256-511 for font stack Noto Sans Regular"))
    }

    @Test func bundledTablesLoad() {
        #expect(Self.bundled.communities.count >= 150)
        #expect(Self.bundled.geology.count >= 100)
        #expect(Self.bundled.pre1750.count >= 30)
        #expect(Self.bundled.trees?.points.isEmpty == false)
    }
}

@MainActor
struct LayerThumbnailTests {
    /// A tile previews what tapping it shows: bases bare, overlays over the
    /// current base at the current strength, relief/trees over the bare base.
    @Test func tilesDeriveTheirStateFromTheCurrentOne() {
        var current = LayerState.default
        current.base = .aerial
        current.strength = .light
        current.trees = true
        let base = ThumbnailSubject.base(.tasmap).state(from: current)
        #expect(base.base == .tasmap && base.overlay == .none && !base.trees)
        let overlay = ThumbnailSubject.overlay(.geology).state(from: current)
        #expect(overlay.base == .aerial && overlay.overlay == .geology && overlay.strength == .light && !overlay.trees)
        let relief = ThumbnailSubject.relief.state(from: current)
        #expect(relief.relief && relief.overlay == .none)
        #expect(ThumbnailSubject.trees.state(from: current).trees)
    }

    /// A tile whose base pack is missing streams LIST at the tile's zoom and
    /// must never be cached; with the pack, it is local.
    @Test func onlyAllLocalRendersAreCacheable() {
        var aerial = LayerState.default
        aerial.base = .aerial
        aerial.overlay = .none
        let place = ThumbnailSubject.place
        #expect(!LayerThumbnails.streamsAtThumbnailZoom(aerial, data: StyleBuilderTests.all, camera: place))
        #expect(LayerThumbnails.streamsAtThumbnailZoom(aerial, data: StyleBuilderTests.both, camera: place))
        // with its pack, a base streams only where the live source starts
        // (tile z16): map z15.3 draws tile z16 (ceil(15.3 + 0.5)), z14.4 tile z15
        let topo = ThumbnailSubject.base(.topo).state(from: .default)
        #expect(LayerThumbnails.streamsAtThumbnailZoom(topo, data: StyleBuilderTests.all, camera: (-42.9, 147.3, 15.3)))
        #expect(!LayerThumbnails.streamsAtThumbnailZoom(topo, data: StyleBuilderTests.all, camera: (-42.9, 147.3, 14.4)))
        #expect(LayerThumbnails.coveringZoom(12) == 13)
        #expect(LayerThumbnails.coveringZoom(14.5) == 15)
        #expect(LayerThumbnails.coveringZoom(14.6) == 16)
    }

    @Test func keysFollowStateAndScale() {
        let thumbs = LayerThumbnails()
        let data = DataLocation.none
        let a = thumbs.key(.base(.topo), state: .default, data: data, scale: 3)
        #expect(a == thumbs.key(.base(.topo), state: .default, data: data, scale: 3))
        #expect(a != thumbs.key(.base(.topo), state: .default, data: data, scale: 2))
        var full = LayerState.default
        full.strength = .full
        #expect(a != thumbs.key(.base(.topo), state: full, data: data, scale: 3))
        #expect(a != thumbs.key(.overlay(.vegetation), state: .default, data: data, scale: 3))
        // a bare base tile doesn't re-render for a strength or season change
        var other = LayerState.default
        other.strength = .outlines
        other.season = 1
        #expect(thumbs.key(.base(.topo), state: ThumbnailSubject.base(.topo).state(from: other), data: data, scale: 3)
            == thumbs.key(.base(.topo), state: ThumbnailSubject.base(.topo).state(from: .default), data: data, scale: 3))
        // the app build and the packs are part of it
        #expect(a.contains(LayerThumbnails.buildIdentity))
        let packs = thumbs.key(.base(.topo), state: .default, data: StyleBuilderTests.all, scale: 3)
        #expect(packs != a)
    }
}

@MainActor
struct LayerStateTests {
    @Test func defaultsArePerPlan() {
        let d = LayerState.default
        #expect(d.base == .topo)
        #expect(d.season == Season.all.count - 1)
        #expect(d.overlay == .vegetation)
        #expect(d.strength == .light, "decided by the user, 2026-11-03")
        #expect(!d.relief && !d.trees)
    }

    /// A stored state with unknown or out-of-range values clamps field by
    /// field to the defaults — never fails whole.
    @Test func invalidValuesClampToDefaults() throws {
        let json = #"{"base":"satellite","season":42,"overlay":"geology","strength":"bold","relief":true,"trees":"yes"}"#
        let s = try JSONDecoder().decode(LayerState.self, from: Data(json.utf8))
        #expect(s.base == .topo)
        #expect(s.season == Season.all.count - 1)
        #expect(s.overlay == .geology)
        #expect(s.strength == .light)
        #expect(s.relief)
        #expect(!s.trees)
        let empty = try JSONDecoder().decode(LayerState.self, from: Data("{}".utf8))
        #expect(empty == .default)
    }

    /// The season is stored as its year (or "latest"), not a slider index:
    /// a build with a new season keeps "up to 2023–24" meaning that.
    @Test func seasonPersistsAsAYear() throws {
        var s = LayerState.default
        #expect(s.seasonYear == nil)
        let latest = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(latest.contains(#""season":"latest""#))
        s.season = 4
        #expect(s.seasonYear == 2024)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(json.contains(#""season":2024"#))
        #expect(try JSONDecoder().decode(LayerState.self, from: Data(json.utf8)).season == 4)
        // choosing the newest season means "latest"
        s.season = Season.all.count - 1
        #expect(s.seasonYear == nil)
        // a pre-M2 index still means its season; an unknown year → latest
        let legacy = try JSONDecoder().decode(LayerState.self, from: Data(#"{"season":2}"#.utf8))
        #expect(legacy.seasonYear == 2022)
        let future = try JSONDecoder().decode(LayerState.self, from: Data(#"{"season":2031}"#.utf8))
        #expect(future.seasonYear == nil)
        let word = try JSONDecoder().decode(LayerState.self, from: Data(#"{"season":"latest"}"#.utf8))
        #expect(word.seasonYear == nil)
    }

    @Test func roundTripsThroughTheStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "izzy-layers-\(UUID().uuidString)"))
        let store = LayerStore(defaults: defaults)
        #expect(store.load() == .default)
        var s = LayerState.default
        s.base = .seasons
        s.season = 2
        s.trees = true
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func seasonLabels() {
        #expect(Season.labels == ["2019–20", "2020–21", "2021–22", "2022–23", "2023–24", "2024–25", "2025–26"])
        #expect(Season.all.last?.isIncomplete == true)
        #expect(Season.all.first?.archive.fileName == "aerial_2020.pmtiles")
    }

    /// Changing the overlay dismisses an overlay card, never a tree card;
    /// toggling trees dismisses only a tree card.
    @Test func cardDismissalRules() {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.selectCommunity(code: "DOB", sourceName: nil)
        model.layers.trees = true
        #expect(model.selection != nil, "a vegetation card survives the trees toggle")
        model.layers.base = .aerial
        #expect(model.selection != nil, "a base change dismisses nothing")
        model.layers.overlay = .geology
        #expect(model.selection == nil, "a vegetation answer over a geology map would lie")

        model.select(.tree(TreeSelection(ref: "D5", accuracy: "sk", isArea: false, index: 0)))
        model.layers.overlay = .vegetation
        #expect(model.selection != nil, "an overlay change keeps a tree card")
        model.layers.trees = false
        #expect(model.selection == nil, "hiding the trees dismisses a tree card")
    }

    @Test func aKeyHighlightClearsOnSelectionAndOverlayChange() {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.keyHighlight = "DOB"
        #expect(model.selectionStyle(featureID: nil).community == "DOB")
        model.selectCommunity(code: "AAP", sourceName: nil)
        #expect(model.keyHighlight == nil)
        #expect(model.selectionStyle(featureID: 7) == SelectionStyle(featureID: 7, community: "AAP"))
        model.clearSelection()
        model.keyHighlight = "DOB"
        model.layers.overlay = .pre1750
        #expect(model.keyHighlight == nil)
    }

    /// A second tap on the same key row clears it; another row switches.
    @Test func aKeyRowTogglesItsHighlight() {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        #expect(model.toggleKeyHighlight("DOB"))
        #expect(model.keyHighlight == "DOB")
        #expect(model.toggleKeyHighlight("AAP"))
        #expect(model.keyHighlight == "AAP")
        #expect(!model.toggleKeyHighlight("AAP"))
        #expect(model.keyHighlight == nil)
    }

    /// Escape walks back: card first, then the key highlight.
    @Test func escapeClearsTheKeyHighlightAfterTheCard() {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        model.keyHighlight = "DOB"
        #expect(model.escapeStep == .clearHighlight)
        model.escape()
        #expect(model.keyHighlight == nil)
        #expect(model.escapeStep == nil)
    }
}
