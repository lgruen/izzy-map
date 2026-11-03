import Foundation

/// Builds the MapLibre style JSON from the located archives and the bundled
/// tables. Pure and deterministic, so the layer stack is unit-tested.
///
/// Stack, bottom to top (docs/NATIVE_PLAN.md §3):
/// background → topo pack (z ≤ 15, stretched natively above) → live LIST
/// topo (z16–18: full resolution online; offline its tiles fail and the
/// stretched pack shows through) → TASVEG fill → TASVEG outline → selection.
nonisolated enum StyleBuilder {
    enum LayerID {
        static let background = "bg"
        static let topo = "topo"
        static let topoLive = "topo-live"
        static let tasvegFill = "tasveg-fill"
        static let tasvegOutline = "tasveg-outline"
        static let selectionOutline = "selected-outline"
    }

    enum SourceID {
        static let topo = "topo"
        static let topoLive = "topo-live"
        static let tasveg = "tasveg"
        static let selection = "selected"
    }

    /// Opaque ground under the topo raster: LIST's water is alpha 207, so
    /// without it the clear colour shows through the sea.
    static let topoBackground = "#eef3f0"
    /// Where a community code is missing from the table.
    static let fallbackFill = "#c8c8c8"
    static let fillOpacity = 0.5
    static let selectionColor = "#ff3b30"

    /// LIST topographic tiles. ArcGIS order: row (y) before column (x).
    static let listTopoTiles =
        "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic/MapServer/tile/{z}/{y}/{x}"

    /// The live sources (LIST, over the network). Their per-tile failures
    /// offline are expected and kept out of the log (MapLogging).
    static let liveSourceIDs: Set<String> = [SourceID.topoLive]
    static let liveHosts: Set<String> = ["services.thelist.tas.gov.au"]

    /// [west, south, east, north] of the live topo source: the topo pack's
    /// PMTiles header bounds (topo_tas.pmtiles, `pmtiles show`, 2026-11-03),
    /// so no tile is requested off Tasmania and the Bass Strait islands.
    static let topoBounds: [Double] = [143.7, -43.87, 148.6, -39.19]

    /// Self-hosted glyphs in the app bundle. Only the 0–255 range ships: any
    /// character outside Latin-1 makes MapLibre drop the whole label.
    static let glyphs = "asset://glyphs/{fontstack}/{range}.pbf"

    static func style(data: DataLocation, communities: CommunityTable) -> [String: Any] {
        var sources: [String: Any] = [:]
        var layers: [[String: Any]] = [
            ["id": LayerID.background, "type": "background", "paint": ["background-color": topoBackground]],
        ]

        // A `url:` source takes its zoom range, bounds and attribution from
        // the PMTiles header/metadata (MapLibre ignores those style keys
        // there), so they're left out: the topo pack's header says z0–15 and
        // MapLibre overzooms it natively above. Credits: Attribution.swift.
        if let topo = data.url(for: .topo) {
            sources[SourceID.topo] = [
                "type": "raster", "url": pmtilesURL(topo), "tileSize": 256,
            ] as [String: Any]
            layers.append(["id": LayerID.topo, "type": "raster", "source": SourceID.topo])
        }

        sources[SourceID.topoLive] = [
            "type": "raster", "tiles": [listTopoTiles], "tileSize": 256,
            "minzoom": 16, "maxzoom": 18, "bounds": topoBounds,
        ] as [String: Any]
        layers.append(["id": LayerID.topoLive, "type": "raster", "source": SourceID.topoLive])

        if let tasveg = data.url(for: .tasveg) {
            sources[SourceID.tasveg] = [
                "type": "vector", "url": pmtilesURL(tasveg),
            ] as [String: Any]
            layers.append([
                "id": LayerID.tasvegFill, "type": "fill",
                "source": SourceID.tasveg, "source-layer": "tasveg",
                "paint": ["fill-color": colorMatch(communities), "fill-opacity": fillOpacity] as [String: Any],
            ])
            layers.append([
                "id": LayerID.tasvegOutline, "type": "line",
                "source": SourceID.tasveg, "source-layer": "tasveg", "minzoom": 11,
                "paint": ["line-color": "#c8c800", "line-width": 1] as [String: Any],
            ])
        }

        // The tapped polygon, set at runtime through MLNShapeSource.
        sources[SourceID.selection] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": [Any]()]]
        layers.append([
            "id": LayerID.selectionOutline, "type": "line", "source": SourceID.selection,
            "layout": ["line-join": "round"],
            "paint": ["line-color": selectionColor, "line-width": 3] as [String: Any],
        ])

        return ["version": 8, "name": "IzzyMap", "glyphs": glyphs, "sources": sources, "layers": layers]
    }

    static func json(data: DataLocation, communities: CommunityTable) -> String {
        let object = style(data: data, communities: communities)
        // A dictionary of JSON-safe literals can't fail to serialise.
        let bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `pmtiles://` + the file URL (MapLibre Native reads local PMTiles).
    static func pmtilesURL(_ file: URL) -> String { "pmtiles://" + file.absoluteString }

    /// `["match", ["get", "VEGCODE"], code, colour, …, fallback]`, sorted for
    /// a stable style.
    static func colorMatch(_ communities: CommunityTable) -> Any {
        // "match" needs at least one label/output pair
        guard !communities.byCode.isEmpty else { return fallbackFill }
        var expression: [Any] = ["match", ["get", "VEGCODE"]]
        for (code, community) in communities.byCode.sorted(by: { $0.key < $1.key }) {
            expression.append(code)
            expression.append(community.color)
        }
        expression.append(fallbackFill)
        return expression
    }
}
