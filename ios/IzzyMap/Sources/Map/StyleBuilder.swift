import Foundation
import IzzyKit

/// The bundled tables the style draws from.
nonisolated struct MapTables: Sendable {
    var communities: CommunityTable = [:]
    var geology: GeologyTable = [:]
    var pre1750: Pre1750Table = [:]
    var trees: TreesData?
    /// Tasmania's coastline (the mini-maps' silhouette): the calm stand-in
    /// for the topo map while it isn't on the device and there is no network.
    var outline: TasmaniaOutline?

    static let empty = MapTables()
}

/// What is selected, as the style draws it. A tapped tree (or the tap ring
/// on a big polygon) goes into the `selected` shape source at runtime; the
/// overlay polygon itself is an id filter on its own vector tiles.
nonisolated struct SelectionStyle: Equatable, Sendable {
    /// The tapped overlay polygon's vector-tile feature id: the halo and ink
    /// lines draw that polygon from every tile it spans (each tile strokes
    /// its own part; clip edges sit in the tile buffer and are never drawn),
    /// so the outline is never one tile's clipped piece.
    var featureID: UInt64?
    /// TASVEG code whose other polygons get the dashed "same community" line
    /// (the selected community, or a key row tapped in the legend).
    var community: String?

    static let none = SelectionStyle()
}

/// Builds the MapLibre style JSON from the layer state, the located archives
/// and the bundled tables. Pure and deterministic, so the stack is unit-tested.
///
/// **Hidden layers are not in the style at all** (and nor are their
/// sources): the map proof measured ~145 MB of texture memory for the full
/// stack, and MapLibre keeps a tile cache for every source even when its
/// layers are invisible. A layer change therefore re-sets the whole style
/// JSON (`MLNMapView.styleJSON`, supported API); MapLibre diffs sources by
/// id and keeps the tiles of sources whose definition is unchanged.
///
/// Stack, bottom to top (docs/NATIVE_PLAN.md §3, DESIGN.md §4):
/// background → base rasters (topo underlay, Tasmap, aerial, seasons oldest →
/// newest; each pack z ≤ 15 stretched natively above, plus its live LIST
/// source z16+, plus the detailed areas of that layer right above them) →
/// overlay fill → relief → overlay boundaries / edge band →
/// same-community dashes → TASVEG codes → Hobart trees → selection.
nonisolated enum StyleBuilder {
    enum LayerID {
        static let background = "bg"
        /// The coastline placeholder (no topo pack, offline).
        static let coast = "coast"
        static let topo = "topo"
        static let topoLive = "topo-live"
        static let tasmap = "tasmap"
        static let tasmapLive = "tasmap-live"
        static let aerial = "aerial"
        static let aerialLive = "aerial-live"
        static let seasonLive = "season-live"
        static let tasvegFill = "tasveg-fill"
        static let geologyFill = "geology-fill"
        static let pre1750Fill = "pre1750-fill"
        static let relief = "relief"
        static let tasvegBand = "tasveg-band"
        static let tasvegBoundary = "tasveg-boundary"
        static let geologyBand = "geology-band"
        static let geologyBoundary = "geology-boundary"
        static let sameCommunity = "same-community"
        static let outlineBandPrefix = "-band"
        static let tasvegLabel = "tasveg-label"
        static let areaOutlines = "detail-outlines"
        static let treesAreaFill = "trees-area-fill"
        static let treesAreaLine = "trees-area-line"
        static let treesCluster = "trees-cluster"
        static let treesClusterCount = "trees-cluster-count"
        static let treesPoint = "trees-point"
        static let treesLabel = "trees-label"
        static let selectedFeature = "selected-feature"
        static let selectionOutline = "selected-outline"
        static let selectionPoint = "selected-point"

        /// The overlay fills a tap consults.
        static let overlayFills = [tasvegFill, geologyFill, pre1750Fill]
        /// Tree layers a tap consults, topmost first.
        static let treePoints = [treesPoint, treesCluster]
        /// Everything that must stay last (after the trees), in order.
        /// The selection layers, last in the style. (The halo ids are no
        /// longer drawn: the selection is red — decided 2026-11-03.)
        static let selection = [selectedFeature, selectionOutline, selectionPoint]

        /// "Show on map" (SpotlightPresenter): runtime layers, never in the
        /// style JSON. Presence cells below z11 (halo, fill, ink, dots, the
        /// stepped-to patch's ring) and the patch's red line from z11.
        static let spotlightHalo = "spotlight-halo"
        static let spotlightCells = "spotlight-cells"
        static let spotlightInk = "spotlight-ink"
        static let spotlightDots = "spotlight-dots"
        static let spotlightSpots = "spotlight-spots"
        static let spotlightPatchRing = "spotlight-patch-ring"
        static let spotlightPatch = "spotlight-patch"
        static let spotlight = [spotlightHalo, spotlightCells, spotlightInk, spotlightDots, spotlightSpots,
                                       spotlightPatchRing, spotlightPatch]
    }

    enum SourceID {
        /// A second source over the visible overlay's archive, holding only
        /// the selection lines and the same-community dashes: a tap changes
        /// THEIR filters, and MapLibre re-lays out every tile of a source
        /// whose layer filter changes — on this source that is a few
        /// filtered lines, never the fills, boundaries and labels.
        static let highlight = "highlight"
        static let coast = "coast"
        static let topo = "topo"
        static let topoLive = "topo-live"
        static let tasmap = "tasmap"
        static let tasmapLive = "tasmap-live"
        static let aerial = "aerial"
        static let aerialLive = "aerial-live"
        static let seasonLive = "season-live"
        static let tasveg = "tasveg"
        static let geology = "geology"
        static let pre1750 = "pre1750"
        static let relief = "relief"
        static let treePoints = "trees-points"
        static let treeAreas = "trees-areas"
        static let selection = "selected"
        /// Where the detailed areas end: their frames, dashed (GeoJSON in the style).
        static let areaOutlines = "detail-outlines"
        /// "Show on map"'s presence cells (runtime GeoJSON source).
        static let spotlight = "spotlight"
    }

    // MARK: Colours (DESIGN.md §2 roles, §4 cartography)

    /// Opaque ground under topo: paper white, as LIST composites its own
    /// map. Measured 2026-11-03 (packs + live tiles at the Derwent):
    /// - z ≤ 13 water is opaque rgb(179,217,218);
    /// - z14–15 water (the packs' deepest levels, stretched above z15
    ///   offline) is rgb(176,216,216) at alpha 207;
    /// - live z16+ water is OPAQUE rgb(191,223,223).
    /// 176·207/255 + 255·48/255 = 190.8 (and 223 for G/B): over white the
    /// translucent z15 water IS the live z16 colour, so pack and live —
    /// online from map z14.5, or the stretched pack offline at z17 — show
    /// one water. Over the earlier #eef3f0 the pack's water was
    /// rgb(188,221,220) against the live (191,223,223): the step the M2
    /// review saw (it read as double compositing; live water has no alpha,
    /// so nothing is drawn twice). Only water lets the ground through.
    static let topoBackground = "#ffffff"
    /// LIST's constant ocean tile (pruned from the aerial pack).
    static let aerialBackground = "#1e525f"
    /// Tasmap's printed sea (pruned from the paper-map pack).
    static let tasmapBackground = "#aae0fc"
    /// Where a community code is missing from the table.
    static let fallbackFill = "#c8c8c8"
    /// Geology / pre-1750's per-feature colour, typed: `to-color` tries its
    /// arguments in turn, so a feature without a parsable `color` draws the
    /// fallback grey rather than failing its evaluation (MapLibre's implicit
    /// coercion of a bare `["get", "color"]` has no fallback).
    static var featureColor: [Any] { ["to-color", ["get", "color"], fallbackFill] }
    static let mapInk = "#000000"
    static let mapHalo = "rgba(255,255,255,0.85)"
    /// The tapped feature's line and rings: system red, 3 pt — decided by
    /// the user (2026-11-03, DESIGN.md §4), over the cased ink proposal.
    static let selectionRed = "#FF3B30"
    static let selectionWidth = 3.0
    /// Community boundaries over cartography and over photos.
    static let graphite = "rgba(0,0,0,0.2)"
    static let paper = "rgba(255,255,255,0.45)"
    static let treeGreen = "#1F5130"

    // MARK: Live LIST services

    static let listBase = "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/"
    /// ArcGIS tile path: row (y) before column (x).
    static func listTiles(_ service: String) -> String { listBase + service + "/MapServer/tile/{z}/{y}/{x}" }

    /// The live sources (LIST, over the network). Their per-tile failures
    /// offline are expected and kept out of the log (MapLogging).
    static let liveSourceIDs: Set<String> = [SourceID.topoLive, SourceID.aerialLive, SourceID.tasmapLive, SourceID.seasonLive]
    static let liveHosts: Set<String> = ["services.thelist.tas.gov.au"]

    /// [west, south, east, north] of every live source: the packs' PMTiles
    /// header bounds (all raster packs share the region bbox, `pmtiles
    /// show`, 2026-11-03), so no tile is requested off Tasmania.
    static let listBounds: [Double] = [143.7, -43.87, 148.6, -39.19]
    /// TASVEG code label bands: z14, 15, 16, 17+.
    static let labelZooms = [14, 15, 16, 17]
    /// TASVEG tiles carry the source polygons (with stable feature ids) from
    /// z11; below are generalised dominant-class bands.
    static let idMinZoom = 11
    /// The packs stop at z15; MapLibre stretches z15 natively above.
    static let packMaxZoom = 15

    // MARK: Raster tile size (which tile level a base map draws from)

    /// The base-map families whose pack, live LIST source and detailed areas
    /// must agree on one tile size (seasons count as aerial).
    nonisolated enum RasterFamily: String, Sendable { case topo, tasmap, aerial }

    /// The `tileSize` a base family's raster sources declare. MapLibre Native
    /// (7.0.0, `util::coveringZoomLevel`) draws a raster source from tile zoom
    /// round(map zoom + log2(512 / tileSize)); the pixels themselves always
    /// fill the tile's extent, so the declared size only moves the level
    /// switch. 256 (the tiles' real size) shows each level from 0.71× to
    /// 1.41× — just past a switch the coarser level is magnified ~1.4×.
    /// 181 (≈ 256/√2) shifts every switch half a zoom earlier: tiles are only
    /// ever shrunk (0.5×–1.0×), at ~2× the tiles on screen.
    /// Shipped: 181 for every family (2026-11-06, Leo: the 1:100K magnified
    /// 1.4× next to crisp 1:25K sheets; simulator frame times unchanged,
    /// ~1.75× tile textures — check the seasons stack on the device).
    /// DEBUG override: `-rasterTileSize 256` for every base family, or
    /// `-rasterTileSizeTopo` / `-rasterTileSizeTasmap` / `-rasterTileSizeAerial`
    /// (aerial includes the seasons) per family.
    nonisolated static let defaultTileSize = 181

    nonisolated static func tileSize(_ family: RasterFamily) -> Int {
        #if DEBUG
        let defaults = UserDefaults.standard
        let key = "rasterTileSize" + family.rawValue.prefix(1).uppercased() + family.rawValue.dropFirst()
        for k in [key, "rasterTileSize"] {
            let v = defaults.integer(forKey: k)
            if (64 ... 512).contains(v) { return v }
        }
        #endif
        return defaultTileSize
    }

    /// The map zoom from which a source of `tileSize` stops drawing its tile
    /// level `level` (and asks for `level + 1`): round(z + log2(512 / size))
    /// passes level + 0.5 at z = level + 0.5 − log2(512 / size); for 256 px
    /// that is level − 0.5.
    nonisolated static func levelEndZoom(_ level: Int, tileSize: Int) -> Double {
        Double(level) + 0.5 - log2(512 / Double(tileSize))
    }

    /// Self-hosted glyphs in the app bundle. Only the 0–255 range ships: any
    /// character outside Latin-1 makes MapLibre drop the whole label.
    static let glyphs = "asset://glyphs/{fontstack}/{range}.pbf"
    static let boldFont = ["Noto Sans Bold"]
    static let regularFont = ["Noto Sans Regular"]

    /// The outline's rings as one GeoJSON polygon set (line layer only:
    /// rings are drawn as they come, holes or not).
    static func coastGeoJSON(_ outline: TasmaniaOutline) -> [String: Any] {
        ["type": "Feature", "properties": [String: Any](),
         "geometry": ["type": "MultiLineString", "coordinates": outline.rings] as [String: Any]]
    }

    // MARK: Visibility rules

    /// The topo map stays under the season stack (gaps read as map, not
    /// sea) and under an aerial / Tasmap base whose pack isn't on the device
    /// (offline the screen is still a usable map, never a flat sea colour).
    static func showsTopo(_ state: LayerState, data: DataLocation) -> Bool {
        switch state.base {
        case .topo, .seasons: true
        case .aerial, .tasmap: data.url(for: state.base.archive!) == nil
        }
    }

    /// The background follows the base only once its pack is local;
    /// otherwise the topo underlay is what shows through gaps.
    static func background(_ state: LayerState, data: DataLocation) -> String {
        switch state.base {
        case .topo, .seasons: topoBackground
        case .aerial: data.url(for: .aerial) == nil ? topoBackground : aerialBackground
        case .tasmap: data.url(for: .tasmap) == nil ? topoBackground : tasmapBackground
        }
    }

    /// DEBUG `-highlightOnOverlaySource YES`: the selection lines on the
    /// overlay's own source (finding 14's timing comparison).
    #if DEBUG
    static let highlightOnOverlaySource = UserDefaults.standard.bool(forKey: "highlightOnOverlaySource")
    #else
    static let highlightOnOverlaySource = false
    #endif

    /// The source the selection lines and dashes draw from.
    static func highlightSource(_ overlaySource: String) -> String {
        highlightOnOverlaySource ? overlaySource : SourceID.highlight
    }

    /// The zoom from which a tapped polygon's id outlines it. TASVEG tiles
    /// carry the source polygons (stable ids) from z11; below they hold
    /// dominant-class bands, so the card answers without an outline.
    /// Geology and pre-1750 carry stable ids at every zoom (pre-1750: per
    /// zoom band — the coordinator re-resolves the id when the band changes).
    static func idMinZoom(_ overlay: Overlay) -> Int {
        overlay == .vegetation ? idMinZoom : 0
    }

    // MARK: Style

    /// - Parameter online: the live LIST sources are in the style only while
    ///   the device has a network path (`Connectivity`): offline the packs
    ///   are the map (stretched above z15) and nothing is requested.
    /// - Parameter areas: the finished detailed-area layers (AreaStore), oldest
    ///   first. Each draws right above its statewide pack and that pack's live
    ///   source, so an area beats both; deleting it falls back to the
    ///   stretched z15 pack. A season's area sits between its own season and
    ///   the next newer one: the newest flown photo still paints on top.
    static func style(
        state: LayerState, data: DataLocation, tables: MapTables, selection: SelectionStyle = .none,
        online: Bool = true, areas: [AreaStyleSource] = []
    ) -> [String: Any] {
        var sources: [String: Any] = [:]
        var layers: [[String: Any]] = [
            ["id": LayerID.background, "type": "background",
             "paint": ["background-color": background(state, data: data)]],
        ]

        // A `url:` (PMTiles) source takes zoom range, bounds and attribution
        // from the archive header/metadata (MapLibre ignores those style keys
        // there): only type, url and tileSize. Credits: Attribution.swift.
        func pack(_ archive: Archive, id: String, family: RasterFamily, paint: [String: Any] = [:]) -> Bool {
            guard let url = data.url(for: archive) else { return false }
            sources[id] = ["type": "raster", "url": pmtilesURL(url), "tileSize": tileSize(family)] as [String: Any]
            layers.append(["id": id, "type": "raster", "source": id, "paint": paint])
            return true
        }
        /// A plain LIST source above the pack: full resolution online; offline
        /// its tiles fail and the stretched pack shows through. Without a pack
        /// it is the only source and streams every zoom.
        /// Same tile size as its pack, so both pick the same tile level and
        /// the live z16 sits exactly where the pack starts to stretch.
        func live(_ service: String, id: String, family: RasterFamily, hasPack: Bool, maxzoom: Int,
                  minzoomWithoutPack: Int = 0, paint: [String: Any] = [:]) {
            guard online else { return }
            sources[id] = [
                "type": "raster", "tiles": [listTiles(service)], "tileSize": tileSize(family),
                "minzoom": hasPack ? packMaxZoom + 1 : minzoomWithoutPack, "maxzoom": maxzoom, "bounds": listBounds,
            ] as [String: Any]
            layers.append(["id": id, "type": "raster", "source": id, "paint": paint])
        }
        /// The detailed areas of one layer: local PMTiles (zooms and bounds
        /// from the archive's header, like a pack), right above the layer's
        /// live source. With a live source in the style that goes deeper
        /// than an area (`liveMaxZoom`), the area hands over where it would
        /// only stretch: its layer stops at map zoom (its deepest tile level
        /// − 0.5 for 256 px tiles, `levelEndZoom`) — MapLibre draws them at
        /// round(map zoom + 1), so from there the live source's next level is
        /// sharper. A second copy of the area (same source) sits UNDER the
        /// live source with no limit: while live tiles load or fail
        /// ("online" is a network path, not theLIST answering) the area
        /// still stretches over the statewide pack instead of the z15 mush.
        func areaUnder(_ layer: AreaLayer, liveMaxZoom: Int, paint: [String: Any] = [:]) {
            guard online else { return }
            for a in areas where a.layer == layer && a.maxZoom < liveMaxZoom {
                sources[a.id] = ["type": "raster", "url": pmtilesURL(a.url), "tileSize": tileSize(layer.family)] as [String: Any]
                layers.append(["id": a.id + areaUnderSuffix, "type": "raster", "source": a.id, "paint": paint])
            }
        }
        var drawnAreas: Set<String> = []
        func area(_ layer: AreaLayer, liveMaxZoom: Int?, paint: [String: Any] = [:]) {
            for a in areas where a.layer == layer {
                drawnAreas.insert(a.areaID)
                let size = tileSize(layer.family)
                sources[a.id] = ["type": "raster", "url": pmtilesURL(a.url), "tileSize": size] as [String: Any]
                var l: [String: Any] = ["id": a.id, "type": "raster", "source": a.id, "paint": paint]
                if online, let liveMaxZoom, a.maxZoom < liveMaxZoom {
                    l["maxzoom"] = levelEndZoom(a.maxZoom, tileSize: size)
                }
                layers.append(l)
            }
        }

        // The topo map not here yet and no network to stream it (first
        // launch offline, DESIGN.md §3 "States"): plain paper with the
        // coast in a grey hairline, as on the mini-map plates — the overlay
        // reads as a map, not as colour floating on white. Only to z9: the
        // outline is a union of locality areas, which run out to mid-river
        // in estuaries — invisible statewide, a jagged line across the
        // Derwent at z11 (seen 2026-11-04) — and from z10 the vegetation's
        // own edges draw the land anyway.
        if showsTopo(state, data: data), data.url(for: .topo) == nil, !online, let outline = tables.outline {
            sources[SourceID.coast] = ["type": "geojson", "data": coastGeoJSON(outline)] as [String: Any]
            layers.append(["id": LayerID.coast, "type": "line", "source": SourceID.coast, "maxzoom": 9.5,
                           "paint": ["line-color": "rgba(0,0,0,0.45)", "line-width": 0.5]])
        }

        if showsTopo(state, data: data) {
            let local = pack(.topo, id: SourceID.topo, family: .topo)
            areaUnder(.topo, liveMaxZoom: 18)
            live("Topographic", id: SourceID.topoLive, family: .topo, hasPack: local, maxzoom: 18)
            area(.topo, liveMaxZoom: 18)
        }
        switch state.base {
        case .topo:
            break
        case .tasmap:
            // TasmapRaster stops at z16 (the 25K sheets)
            let local = pack(.tasmap, id: SourceID.tasmap, family: .tasmap)
            areaUnder(.tasmap, liveMaxZoom: 16)
            live("TasmapRaster", id: SourceID.tasmapLive, family: .tasmap, hasPack: local, maxzoom: 16)
            area(.tasmap, liveMaxZoom: 16)
        case .aerial:
            let local = pack(.aerial, id: SourceID.aerial, family: .aerial)
            areaUnder(.aerial, liveMaxZoom: 18)
            live("Orthophoto", id: SourceID.aerialLive, family: .aerial, hasPack: local, maxzoom: 18)
            area(.aerial, liveMaxZoom: 18)
        case .seasons:
            // Oldest → newest, so the newest flown photo paints on top and the
            // transparent gaps let older seasons, then topo, through. Fades
            // off: seven stacked cross-fades flicker.
            let noFade: [String: Any] = ["raster-fade-duration": 0]
            let cutoff = state.seasonClamped
            var topLocal = false
            for (i, season) in Season.all.enumerated() where i <= cutoff {
                let local = pack(season.archive, id: season.sourceID, family: .aerial, paint: noFade)
                if i == cutoff { topLocal = local } else { area(.season(season.year), liveMaxZoom: nil, paint: noFade) }
            }
            // Live above the packs only for the newest season shown. The
            // plan's rule — stream a season above z15 only where its z15 pack
            // tile exists — can't be said in a style, and a source's bounds
            // can't approximate it (every season's coverage spans the state,
            // measured at z9). One live season bounds the 404s to one source's
            // worth; older seasons stay at their stretched z15 in its gaps.
            // Without its pack the season streams only from tile z11 (a
            // patchwork of 6–15 % of land: below that a statewide view would
            // be mostly 404s for photos too small to read). The caption
            // (SeasonCoverage) promises streaming on the same rule.
            let top = Season.all[cutoff]
            areaUnder(.season(top.year), liveMaxZoom: 18, paint: noFade)
            live(top.service, id: SourceID.seasonLive, family: .aerial, hasPack: topLocal, maxzoom: 18,
                 minzoomWithoutPack: SeasonCoverage.liveMinZoomWithoutPack, paint: noFade)
            // the newest season's areas above its live source
            area(.season(top.year), liveMaxZoom: 18, paint: noFade)
        }

        let strength = state.effectiveStrength
        let opacity = state.fillOpacity
        let boundary = state.base.isPhoto ? paper : graphite

        // Overlay fill. In Outlines mode the fill stays at opacity 0: it is
        // what a tap queries.
        switch state.overlay {
        case .vegetation:
            if let url = data.url(for: .tasveg) {
                sources[SourceID.tasveg] = ["type": "vector", "url": pmtilesURL(url)] as [String: Any]
                layers.append(fill(LayerID.tasvegFill, source: SourceID.tasveg, color: colorMatch(tables.communities), opacity: opacity))
            }
        case .geology:
            if let url = data.url(for: .geology) {
                sources[SourceID.geology] = ["type": "vector", "url": pmtilesURL(url)] as [String: Any]
                // the official MRT unit colour ships per feature in the tiles
                layers.append(fill(LayerID.geologyFill, source: SourceID.geology, color: featureColor, opacity: opacity))
            }
        case .pre1750:
            if let url = data.url(for: .pre1750) {
                sources[SourceID.pre1750] = ["type": "vector", "url": pmtilesURL(url)] as [String: Any]
                // per-feature NVIS colour; no boundaries (1 ha cell edges are noise)
                // No fill antialiasing: MapLibre antialiases a fill by
                // stroking every edge with a 1 px line at the fill colour,
                // which here outlines each 1 ha cell twice-painted — a dark
                // grid over the whole layer (the M2 "pixels, not patches"
                // speckle). Off, adjacent cells abut exactly (measured
                // 2026-11-03 at the Great Lake, z9.5).
                var preFill = fill(LayerID.pre1750Fill, source: SourceID.pre1750, color: featureColor, opacity: opacity)
                preFill["paint"] = ["fill-color": featureColor, "fill-opacity": opacity, "fill-antialias": false] as [String: Any]
                layers.append(preFill)
            }
        case .none:
            break
        }

        // Relief shading: above the fills (vegetation colours get shaded, as
        // on a terrain map), below every line and label. The pack is already
        // translucent black, so it draws as an exact multiply.
        if state.relief, let url = data.url(for: .relief) {
            sources[SourceID.relief] = ["type": "raster", "url": pmtilesURL(url), "tileSize": 256] as [String: Any]
            layers.append(["id": LayerID.relief, "type": "raster", "source": SourceID.relief,
                           "paint": ["raster-fade-duration": 0]])
        }

        // Boundaries (Full/Light) or the edge band (Outlines).
        if state.overlay == .vegetation, sources[SourceID.tasveg] != nil {
            if strength == .outlines {
                layers.append(band(LayerID.tasvegBand, source: SourceID.tasveg,
                                   color: colorMatch(tables.communities, transform: bandColor)))
            }
            layers.append(boundaryLine(LayerID.tasvegBoundary, source: SourceID.tasveg, color: boundary,
                                       outlines: strength == .outlines, from: 11))
            // The same-community dashes: on the highlight source (below),
            // drawn here in the stack — above the boundaries, below the codes.
            if let url = data.url(for: .tasveg) {
                let source = highlightSource(SourceID.tasveg)
                sources[source] = ["type": "vector", "url": pmtilesURL(url)] as [String: Any]
                layers.append([
                    "id": LayerID.sameCommunity, "type": "line", "source": source,
                    "source-layer": "tasveg", "minzoom": 11,
                    "filter": sameCommunityFilter(selection.community),
                    "layout": ["line-join": "round"],
                    "paint": ["line-color": "rgba(0,0,0,0.55)", "line-width": 0.75, "line-dasharray": [2, 2]] as [String: Any],
                ])
            }
            // Codes on polygons from z14, as on the official TASVEG sheets:
            // 156 codes share 29 fills, so colour names a family and the code
            // the community. One point per polygon at its largest inscribed
            // circle (`tasveg_labels`, z13–14, overzoomed beyond), shown once
            // the circle can hold the code: r ≥ 43 m at z14, halving per zoom.
            // One layer per zoom band (a zoom-dependent filter is not
            // something to rely on in MapLibre Native).
            for (index, zoom) in labelZooms.enumerated() {
                var label: [String: Any] = [
                    "id": index == 0 ? LayerID.tasvegLabel : "\(LayerID.tasvegLabel)-\(zoom)",
                    "type": "symbol", "source": SourceID.tasveg,
                    "source-layer": "tasveg_labels", "minzoom": zoom,
                    "filter": [">=", ["coalesce", ["get", "r"], 0], 43.0 / Double(1 << (zoom - 14))] as [Any],
                    "layout": [
                        "text-field": ["get", "VEGCODE"],
                        "text-font": boldFont,
                        "text-size": ["interpolate", ["linear"], ["zoom"], 14, 10, 17, 12] as [Any],
                        "text-letter-spacing": 0.1,
                        "text-padding": 4,
                        // bigger polygons win label collisions
                        "symbol-sort-key": ["-", 0, ["coalesce", ["get", "area"], 0]] as [Any],
                    ] as [String: Any],
                    "paint": ["text-color": "rgba(0,0,0,0.85)", "text-halo-color": mapHalo, "text-halo-width": 1.5] as [String: Any],
                ]
                if index + 1 < labelZooms.count { label["maxzoom"] = labelZooms[index + 1] }
                layers.append(label)
            }
        }
        if state.overlay == .geology, sources[SourceID.geology] != nil {
            if strength == .outlines {
                layers.append(band(LayerID.geologyBand, source: SourceID.geology,
                                   color: geologyBandColor(tables.geology)))
            }
            layers.append(boundaryLine(LayerID.geologyBoundary, source: SourceID.geology, color: boundary,
                                       outlines: strength == .outlines, from: 9))
        }

        // Where detail ends: each finished area's frame, a fine dashed line
        // from where the statewide packs stop (tile z15, map zoom 14.5 at
        // 256 px, `levelEndZoom`) —
        // the frame she drew, so it reads as "full detail inside".
        let frames = Dictionary(areas.filter { drawnAreas.contains($0.areaID) }.map { ($0.areaID, $0.box) },
                                uniquingKeysWith: { a, _ in a })
            .sorted { $0.key < $1.key }.map(\.value)
        if !frames.isEmpty {
            let features: [Any] = frames.map { b in
                ["type": "Feature", "properties": [:] as [String: Any],
                 "geometry": ["type": "LineString", "coordinates": [[b.west, b.north], [b.east, b.north], [b.east, b.south],
                                                                    [b.west, b.south], [b.west, b.north]]] as [String: Any]]
                    as [String: Any]
            }
            sources[SourceID.areaOutlines] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": features]
                as [String: Any]] as [String: Any]
            layers.append([
                "id": LayerID.areaOutlines, "type": "line", "source": SourceID.areaOutlines,
                "minzoom": levelEndZoom(packMaxZoom, tileSize: tileSize(state.base.family)),
                "paint": ["line-color": state.base.isPhoto ? "rgba(255,255,255,0.75)" : "rgba(0,0,0,0.45)",
                          "line-width": 1, "line-dasharray": [4, 3]] as [String: Any],
            ])
        }

        // Hobart significant trees: last before the selection (a test pins it).
        if state.trees, let trees = tables.trees {
            addTrees(trees, sources: &sources, layers: &layers)
        }

        // Selection, always last. The tapped overlay polygon by id, a red
        // line over its own vector tiles (never a copy of one tile's
        // clipped geometry) …
        if let overlaySource = overlaySource(state.overlay), let archive = state.overlay.archive,
           let url = data.url(for: archive) {
            let source = highlightSource(overlaySource.id)
            if sources[source] == nil {
                sources[source] = ["type": "vector", "url": pmtilesURL(url)] as [String: Any]
            }
            layers.append([
                "id": LayerID.selectedFeature, "type": "line", "source": source, "source-layer": overlaySource.layer,
                "minzoom": idMinZoom(state.overlay), "filter": featureFilter(selection.featureID),
                "layout": ["line-join": "round"],
                "paint": ["line-color": selectionRed, "line-width": selectionWidth] as [String: Any],
            ])
        }
        // … and a tapped tree (or the tap point on a big polygon) in this
        // shape source, set at runtime.
        sources[SourceID.selection] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": [Any]()]]
        let polygons: [Any] = ["!=", ["geometry-type"], "Point"]
        let points: [Any] = ["==", ["geometry-type"], "Point"]
        layers.append(["id": LayerID.selectionOutline, "type": "line", "source": SourceID.selection, "filter": polygons,
                       "layout": ["line-join": "round"],
                       "paint": ["line-color": selectionRed, "line-width": selectionWidth] as [String: Any]])
        // a tree ring (11 pt) or the smaller tap ring (`tap` property, 6 pt)
        let radius: [Any] = ["case", ["has", "tap"], 6, 11]
        layers.append(["id": LayerID.selectionPoint, "type": "circle", "source": SourceID.selection, "filter": points,
                       "paint": ["circle-radius": radius, "circle-color": "rgba(0,0,0,0)",
                                 "circle-stroke-color": selectionRed, "circle-stroke-width": selectionWidth] as [String: Any]])

        return [
            "version": 8, "name": "IzzyMap", "glyphs": glyphs,
            // nothing on the map animates on a layer change (DESIGN.md "Never moves")
            "transition": ["duration": 0, "delay": 0],
            "sources": sources, "layers": layers,
        ]
    }

    /// The id suffix of an area's copy under its live source.
    static let areaUnderSuffix = "-under"

    static func json(state: LayerState, data: DataLocation, tables: MapTables, selection: SelectionStyle = .none,
                     online: Bool = true, areas: [AreaStyleSource] = []) -> String {
        let object = style(state: state, data: data, tables: tables, selection: selection, online: online, areas: areas)
        // A dictionary of JSON-safe literals can't fail to serialise.
        let bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The vector source and source layer of an overlay.
    static func overlaySource(_ overlay: Overlay) -> (id: String, layer: String)? {
        switch overlay {
        case .vegetation: (SourceID.tasveg, "tasveg")
        case .geology: (SourceID.geology, "geology")
        case .pre1750: (SourceID.pre1750, "pre1750")
        case .none: nil
        }
    }

    // MARK: Layer pieces

    private static func fill(_ id: String, source: String, color: Any, opacity: Double) -> [String: Any] {
        ["id": id, "type": "fill", "source": source, "source-layer": source,
         "paint": ["fill-color": color, "fill-opacity": opacity] as [String: Any]]
    }

    /// DESIGN.md §4: none ≤ z10, 0.25 pt z11 → 0.5 z13 → 0.75 z15 → 1.0 z17+
    /// (geology from z9). In Outlines mode a 0.5 pt line beside the band.
    private static func boundaryLine(_ id: String, source: String, color: String, outlines: Bool, from zoom: Int) -> [String: Any] {
        let width: Any = outlines
            ? 0.5
            : ["interpolate", ["linear"], ["zoom"], zoom, 0.25, zoom + 2, 0.5, zoom + 4, 0.75, zoom + 6, 1.0] as [Any]
        return ["id": id, "type": "line", "source": source, "source-layer": source, "minzoom": zoom,
                "layout": ["line-join": "round"],
                "paint": ["line-color": outlines ? graphite : color, "line-width": width] as [String: Any]]
    }

    /// Outlines mode: ONE band of the official colour just inside each
    /// polygon — the hand-tinted boundary ribbon of printed maps. 2.5 pt at
    /// 70 %, its inner edge offset by exactly half its width so the band
    /// starts at the boundary and never spills outside (positive offset =
    /// right of the ring = inside, for MVT's clockwise exterior rings and
    /// counter-clockwise holes). Dark fills are lightened (`bandColor`) so
    /// no band reads as ink — ink is the selection's alone.
    static let bandWidth = 2.5
    static let bandOpacity = 0.7
    private static func band(_ id: String, source: String, color: Any) -> [String: Any] {
        ["id": id, "type": "line", "source": source, "source-layer": source,
         "layout": ["line-join": "round"],
         "paint": [
             "line-color": color, "line-opacity": bandOpacity,
             "line-width": ["interpolate", ["linear"], ["zoom"], 8, 1, 12, bandWidth] as [Any],
             "line-offset": ["interpolate", ["linear"], ["zoom"], 8, 0.5, 12, bandWidth / 2] as [Any],
         ] as [String: Any]]
    }

    /// The darkest a band may be: relative luminance ≥ 0.4, i.e. at most
    /// 60 % luminance contrast against paper. Darker official colours
    /// (#326565 WDB/WDR, near-black geology units) are mixed toward white
    /// just enough; lighter ones are untouched. The key's Outlines box
    /// should use the same colour.
    static let bandMinLuminance = 0.4
    static func bandColor(_ hex: String) -> String {
        guard let rgb = MapColour.components(hex) else { return hex }
        func lum(_ c: (Double, Double, Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }
        let c = rgb
        guard lum(c) < bandMinLuminance else { return hex }
        // bisect the mix toward white that just reaches the floor
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 20 {
            let t = (lo + hi) / 2
            let m = (c.0 + (1 - c.0) * t, c.1 + (1 - c.1) * t, c.2 + (1 - c.2) * t)
            if lum(m) < bandMinLuminance { lo = t } else { hi = t }
        }
        let m = (c.0 + (1 - c.0) * hi, c.1 + (1 - c.1) * hi, c.2 + (1 - c.2) * hi)
        return MapColour.hex((red: m.0, green: m.1, blue: m.2))
    }

    /// Geology bands: the unit colours (per feature in the tiles) through
    /// `bandColor`, as a match on the unit symbol.
    static func geologyBandColor(_ units: GeologyTable) -> Any {
        let darkened = units.sorted { $0.key < $1.key }.compactMap { symb, unit -> (String, String)? in
            let band = bandColor(String(unit.color.prefix(7)))
            return band.lowercased() == String(unit.color.prefix(7)).lowercased() ? nil : (symb, band)
        }
        guard !darkened.isEmpty else { return featureColor }
        var expression: [Any] = ["match", ["get", "SYMB"]]
        for (symb, band) in darkened where MapText.isLatin1(symb) {
            expression.append(symb)
            expression.append(band)
        }
        expression.append(featureColor)
        return expression.count > 3 ? expression : featureColor
    }

    private static func addTrees(_ trees: TreesData, sources: inout [String: Any], layers: inout [[String: Any]]) {
        // Clustered until z15 so the CBD doesn't read as one green smear
        // (clusters are re-evaluated at integer zooms: max 14 = up to z15).
        sources[SourceID.treePoints] = [
            "type": "geojson", "data": treePointsGeoJSON(trees),
            "cluster": true, "clusterRadius": 32, "clusterMaxZoom": 14,
        ] as [String: Any]
        sources[SourceID.treeAreas] = ["type": "geojson", "data": treeAreasGeoJSON(trees)] as [String: Any]
        let clustered: [Any] = ["has", "point_count"]
        let single: [Any] = ["!", ["has", "point_count"]]
        layers += [
            ["id": LayerID.treesAreaFill, "type": "fill", "source": SourceID.treeAreas, "minzoom": 12,
             "paint": ["fill-color": treeGreen, "fill-opacity": 0.15] as [String: Any]],
            ["id": LayerID.treesAreaLine, "type": "line", "source": SourceID.treeAreas, "minzoom": 12,
             "layout": ["line-join": "round"],
             "paint": ["line-color": treeGreen, "line-width": 1.25] as [String: Any]],
            ["id": LayerID.treesCluster, "type": "circle", "source": SourceID.treePoints, "filter": clustered,
             "minzoom": 10,
             "paint": ["circle-radius": 11, "circle-color": treeGreen,
                       "circle-stroke-color": "#ffffff", "circle-stroke-width": 1.5] as [String: Any]],
            ["id": LayerID.treesClusterCount, "type": "symbol", "source": SourceID.treePoints, "filter": clustered,
             "minzoom": 10,
             "layout": ["text-field": ["get", "point_count_abbreviated"], "text-font": boldFont,
                        "text-size": 11, "text-allow-overlap": true, "text-ignore-placement": true] as [String: Any],
             "paint": ["text-color": "#ffffff"]],
            ["id": LayerID.treesPoint, "type": "circle", "source": SourceID.treePoints, "filter": single,
             "minzoom": 10,
             "paint": ["circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 2.5, 14, 3.5] as [Any],
                       "circle-color": treeGreen,
                       "circle-stroke-color": "#ffffff", "circle-stroke-width": 1.5] as [String: Any]],
            // Latin-1 `label` only: map glyphs are 0-255.pbf (the botanical
            // `name` holds curly quotes and ×; it is UI text only). One label
            // per register entry ("White gum ×18", on the stand's middle
            // tree), never one per tree; from z17, placed beside the dot
            // wherever it fits.
            ["id": LayerID.treesLabel, "type": "symbol", "source": SourceID.treePoints,
             "filter": ["all", single, ["!=", ["get", "label"], ""]] as [Any],
             "minzoom": 17,
             "layout": ["text-field": ["get", "label"], "text-font": regularFont, "text-size": 11,
                        "text-variable-anchor": ["top", "bottom", "right", "left"],
                        "text-radial-offset": 0.8, "text-justify": "auto", "text-optional": true,
                        "text-max-width": 8] as [String: Any],
             "paint": ["text-color": treeGreen, "text-halo-color": mapHalo, "text-halo-width": 1.5] as [String: Any]],
        ]
    }

    /// Tree points as GeoJSON: `ref`, `sheet`, `acc`, the point's index into
    /// `TreesData.points` (`i`, for the card and the selection ring) and its
    /// Latin-1 map `label` — only on the one point of each register entry
    /// nearest the entry's centre, with "×n" for a stand of n trees (empty
    /// elsewhere, and when the register's label isn't Latin-1; × is 0xD7).
    static func treePointsGeoJSON(_ trees: TreesData) -> [String: Any] {
        var members: [String: [Int]] = [:]
        for (i, p) in trees.points.enumerated() { members[p.tag.ref, default: []].append(i) }
        var labelled: [Int: String] = [:]
        for (ref, indices) in members {
            let lat = indices.map { trees.points[$0].position.latitude }.reduce(0, +) / Double(indices.count)
            let lon = indices.map { trees.points[$0].position.longitude }.reduce(0, +) / Double(indices.count)
            let middle = indices.min { a, b in
                let pa = trees.points[a].position, pb = trees.points[b].position
                return hypot(pa.latitude - lat, pa.longitude - lon) < hypot(pb.latitude - lat, pb.longitude - lon)
            }!
            let base = trees.refs[ref]?.label ?? ""
            labelled[middle] = indices.count > 1 && !base.isEmpty ? "\(base) ×\(indices.count)" : base
        }
        let features: [Any] = trees.points.enumerated().map { i, p in
            let label = labelled[i] ?? ""
            return [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [p.position.longitude, p.position.latitude]],
                "properties": ["ref": p.tag.ref, "sheet": p.tag.sheet, "acc": p.tag.acc, "i": i,
                               "label": MapText.isLatin1(label) ? label : ""] as [String: Any],
            ] as [String: Any]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    /// Tree areas as GeoJSON (`i` = index into `TreesData.areas`).
    static func treeAreasGeoJSON(_ trees: TreesData) -> [String: Any] {
        let features: [Any] = trees.areas.enumerated().map { i, a in
            let polygons = a.polygons.map { rings in rings.map { ring in ring.map { [$0.longitude, $0.latitude] } } }
            return [
                "type": "Feature",
                "geometry": ["type": "MultiPolygon", "coordinates": polygons],
                "properties": ["ref": a.tag.ref, "sheet": a.tag.sheet, "acc": a.tag.acc, "i": i] as [String: Any],
            ] as [String: Any]
        }
        return ["type": "FeatureCollection", "features": features]
    }

    /// `pmtiles://` + the file URL (MapLibre Native reads local PMTiles).
    static func pmtilesURL(_ file: URL) -> String { "pmtiles://" + file.absoluteString }

    /// `["match", ["get", "VEGCODE"], code, colour, …, fallback]`, sorted for
    /// a stable style.
    static func colorMatch(_ communities: CommunityTable, transform: (String) -> String = { $0 }) -> Any {
        // "match" needs at least one label/output pair
        guard !communities.isEmpty else { return fallbackFill }
        var expression: [Any] = ["match", ["get", "VEGCODE"]]
        for (code, community) in communities.sorted(by: { $0.key < $1.key }) {
            expression.append(code)
            expression.append(transform(community.color))
        }
        expression.append(fallbackFill)
        return expression
    }

    /// The selected overlay polygon by feature id; matches nothing without one.
    static func featureFilter(_ id: UInt64?) -> [Any] {
        guard let id else { return ["==", ["id"], -1] }
        return ["==", ["id"], id]
    }

    /// "Show on map"'s fade: `solo` for the community, `others` for the
    /// rest — from `zoom` on; below it everything at `others` (the presence
    /// cells stand in for the community there).
    static func spotlightOpacity(code: String, solo: Double, others: Double, from zoom: Int) -> [Any] {
        let pick: [Any] = ["case", ["==", ["get", "VEGCODE"], code], solo, others]
        return zoom <= 0 ? pick : ["step", ["zoom"], others, zoom, pick]
    }

    /// The whole fade, per overlay layer: the tile fill, the Outlines band
    /// and the codes (SpotlightPresenter sets them at runtime; the
    /// style-variant tests bake the same values into the JSON).
    static func spotlightFade(code: String, fillOpacity: Double) -> (fill: [Any], band: [Any], label: [Any]) {
        let from = Spotlight.polygonsFrom
        return (spotlightOpacity(code: code, solo: max(0.85, fillOpacity), others: min(0.1, fillOpacity), from: from),
                spotlightOpacity(code: code, solo: 1, others: 0.15, from: from),
                spotlightOpacity(code: code, solo: 1, others: 0.3, from: 0))
    }

    /// Polygons of one community; matches nothing for nil.
    static func sameCommunityFilter(_ code: String?) -> [Any] {
        ["==", ["get", "VEGCODE"], code.flatMap { MapText.isLatin1($0) ? $0 : nil } ?? ""]
    }
}

extension BaseMap {
    /// The family whose tile size the base's rasters share.
    nonisolated var family: StyleBuilder.RasterFamily {
        switch self {
        case .topo: .topo
        case .tasmap: .tasmap
        case .aerial, .seasons: .aerial
        }
    }
}

extension AreaLayer {
    /// The base family whose tile size an area's layer shares.
    nonisolated var family: StyleBuilder.RasterFamily {
        switch self {
        case .topo: .topo
        case .tasmap: .tasmap
        case .aerial, .season: .aerial
        }
    }
}
