import Foundation

// Detailed areas (docs/NATIVE_PLAN.md §3): a user-framed box taken offline
// at full resolution, per layer, from LIST's tile services by the device.
// Everything here is pure: the tile pyramid, counts, estimates and caps.

/// A lon/lat box in degrees (the frame on the map).
public struct AreaBox: Codable, Sendable, Hashable {
    public var west, south, east, north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = min(west, east); self.east = max(west, east)
        self.south = min(south, north); self.north = max(south, north)
    }

    public var bounds: PMTiles.Bounds { PMTiles.Bounds(west: west, south: south, east: east, north: north) }
    public var centre: (longitude: Double, latitude: Double) { ((west + east) / 2, (south + north) / 2) }

    /// Ground width across the middle and height, in metres (sphere of the
    /// Web Mercator radius: the "4.2 × 3.1 km" of the framing bar).
    public var sizeMetres: (width: Double, height: Double) {
        let r = 6_378_137.0
        let lat = centre.latitude * .pi / 180
        return ((east - west) * .pi / 180 * r * cos(lat), (north - south) * .pi / 180 * r)
    }

    public func intersects(_ other: AreaBox) -> Bool {
        west <= other.east && other.west <= east && south <= other.north && other.south <= north
    }
}

/// One layer an area can hold: a LIST raster service the device fetches
/// verbatim (CC BY-NC-ND photos and Tasmap stay byte-for-byte; topo is
/// CC BY). Relief is deliberately not one (docs/NATIVE_PLAN.md §3 "Detailed
/// areas": translucent shading stacked over the statewide shading would
/// darken the area twice — a raster layer can't be masked).
public enum AreaLayer: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    case aerial
    /// A flying season, by the year it ends (2024 = 2023–24).
    case season(Int)
    case tasmap
    case topo

    /// The registry's and the file name's key: "aerial", "season-2024", …
    public var rawValue: String {
        switch self {
        case .aerial: "aerial"
        case let .season(year): "season-\(year)"
        case .tasmap: "tasmap"
        case .topo: "topo"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "aerial": self = .aerial
        case "tasmap": self = .tasmap
        case "topo": self = .topo
        default:
            guard rawValue.hasPrefix("season-"), let year = Int(rawValue.dropFirst(7)), (2000 ... 2100).contains(year)
            else { return nil }
            self = .season(year)
        }
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let layer = AreaLayer(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown area layer \(raw)"))
        }
        self = layer
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Paint order of the base stack: topo under the photos and the paper map.
    private var order: Int {
        switch self {
        case .topo: 0
        case .tasmap: 1
        case .aerial: 2
        case let .season(year): 3 + year
        }
    }

    public static func < (a: AreaLayer, b: AreaLayer) -> Bool { a.order < b.order }

    public var isSeason: Bool { if case .season = self { true } else { false } }

    /// The LIST `Basemaps/<service>/MapServer` it comes from.
    public var service: String {
        switch self {
        case .aerial: "Orthophoto"
        case let .season(year): "AerialPhoto\(year)"
        case .tasmap: "TasmapRaster"
        case .topo: "Topographic"
        }
    }

    /// The service's deepest level (TasmapRaster ends with the 25K sheets).
    public var maxZoom: Int { self == .tasmap ? 16 : 18 }

    /// Measured mean tile size (the web app's `meanTileBytes`, from the packs).
    public var meanTileBytes: Int {
        switch self {
        case .topo: 12_000
        case .tasmap: 16_000
        case .aerial, .season: 18_000
        }
    }

    /// What the archive declares. LIST's photo and Tasmap services are MIXED
    /// (JPEG, PNG at edges); MapLibre sniffs every tile, the packs say JPEG too.
    public var tileType: PMTiles.TileType { self == .topo ? .png : .jpeg }

    /// The ArcGIS tile URL: row (y) BEFORE column (x).
    public func tileURL(_ tile: TileID, base: String = AreaPlan.listBase) -> URL {
        URL(string: "\(base)\(service)/MapServer/tile/\(tile.z)/\(tile.y)/\(tile.x)")!
    }
}

/// How much detail: the deepest tile zoom fetched.
public enum AreaDetail: Int, Codable, CaseIterable, Sendable, Comparable {
    case good = 16, fine = 17, finest = 18

    public var zoom: Int { rawValue }
    public var title: String {
        switch self {
        case .good: "Good"
        case .fine: "Fine"
        case .finest: "Finest"
        }
    }

    /// Ground size of one pixel at `latitude` (256 px Web Mercator tiles).
    public func metresPerPixel(latitude: Double) -> Double {
        156_543.033_928 * cos(latitude * .pi / 180) / Double(1 << zoom)
    }

    public static func < (a: AreaDetail, b: AreaDetail) -> Bool { a.rawValue < b.rawValue }
}

/// The tile pyramid of an area, its counts, estimates and caps.
public enum AreaPlan {
    public static let listBase = "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/"
    /// The shallowest level an area stores. The statewide packs hold z0–15
    /// anyway; z13–15 make an area readable in context where its pack isn't
    /// on the device (a z13 tile is ~3.6 km across here) without painting
    /// one stray 40 km square over the statewide view, as a z10 tile would.
    public static let minZoom = 13
    /// The packs' deepest level: seasons fetch deeper only under their flown z15 tiles.
    public static let packMaxZoom = 15
    /// Per layer: keeps the device's storage, LIST's load and her patience
    /// bounded (~1 GB of photos).
    public static let maxTilesPerLayer = 60_000
    /// What the framing bar checks against: aerial photos at Fine.
    public static let framingDetail = AreaDetail.fine
    /// Concurrent requests to LIST per download.
    public static let concurrency = 6
    /// Waits between the tries of one tile, as multiples of the download's
    /// base backoff (0.5 s in the app): 0.5, 1, 2, 4, 8, 15 s — about 30 s
    /// in all, so a short outage (a tunnel, a Wi-Fi hand-over, a DNS hiccup)
    /// doesn't end a 60,000-tile run; then the layer stops, resumable.
    public static let retryFactors: [Double] = [1, 2, 4, 8, 16, 30]
    /// Tries per tile in all (the first plus one per wait).
    public static var attempts: Int { retryFactors.count + 1 }
    /// Tries of a tile answering with something that isn't a map tile
    /// before it is skipped for this run.
    public static let badBodyAttempts = 3
    /// Skipped in this many runs, a tile counts as absent (logged): one odd
    /// tile must never stall Resume for ever.
    public static let strikesToGiveUp = 3
    /// This many tiles in a row answering with something that isn't a map
    /// tile is a Wi-Fi login page or a broken service, not odd tiles: the
    /// layer stops (and no tile is held against).
    public static let badRun = 8

    /// The waits of one tile's tries for a base backoff.
    public static func retryDelays(base: Duration) -> [Duration] {
        retryFactors.map { base * $0 }
    }
    /// Room kept for the system beyond an estimate.
    public static let spaceMargin: Int64 = 200_000_000

    /// The x and y tile ranges covering `box` at `zoom` (both edges inclusive,
    /// as the web app's `tilesAt`).
    public static func tileRange(_ box: AreaBox, zoom: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let nw = TileID(longitude: box.west, latitude: box.north, zoom: zoom)
        let se = TileID(longitude: box.east, latitude: box.south, zoom: zoom)
        return (min(nw.x, se.x) ... max(nw.x, se.x), min(nw.y, se.y) ... max(nw.y, se.y))
    }

    /// Tiles covering `box` at one zoom, without listing them.
    public static func count(_ box: AreaBox, zoom: Int) -> Int {
        let r = tileRange(box, zoom: zoom)
        return r.x.count * r.y.count
    }

    public static func count(_ box: AreaBox, zooms: ClosedRange<Int>) -> Int {
        zooms.reduce(0) { $0 + count(box, zoom: $1) }
    }

    /// Tiles covering `box` at `zoom`, row by row.
    public static func tiles(_ box: AreaBox, zoom: Int) -> [TileID] {
        let r = tileRange(box, zoom: zoom)
        var out: [TileID] = []
        out.reserveCapacity(r.x.count * r.y.count)
        for y in r.y { for x in r.x { out.append(TileID(z: zoom, x: x, y: y)) } }
        return out
    }

    /// The levels a layer stores at a detail (Tasmap stops at z16).
    public static func zooms(_ layer: AreaLayer, detail: AreaDetail) -> ClosedRange<Int> {
        minZoom ... max(minZoom, min(detail.zoom, layer.maxZoom))
    }

    /// The deepest level ≤ `requested` (and ≥ `packMaxZoom`) whose pyramid
    /// from `minZoom` stays within `cap` requests, given the count of each
    /// level; nil when even z13–15 don't fit.
    public static func depth(requested: Int, cap: Int = maxTilesPerLayer, count: (Int) -> Int) -> Int? {
        var total = 0
        var deepest: Int?
        for z in minZoom ... max(minZoom, requested) {
            total += count(z)
            if total > cap { break }
            if z >= min(packMaxZoom, requested) { deepest = z }
        }
        return deepest
    }

    /// The z15 ancestor of a tile at z ≥ 15.
    public static func packParent(_ tile: TileID) -> TileID {
        let d = tile.z - packMaxZoom
        return d <= 0 ? tile : TileID(z: packMaxZoom, x: tile.x >> d, y: tile.y >> d)
    }

    /// Every tile to fetch for one layer, shallowest level first (a season's
    /// z ≤ 15 levels come before the deeper ones, which are kept only under a
    /// z15 tile `flown` says has photos). Stops listing past `limit`.
    public static func candidates(_ box: AreaBox, layer: AreaLayer, detail: AreaDetail,
                                  flown: ((TileID) -> Bool)? = nil, limit: Int = .max) -> [TileID] {
        var out: [TileID] = []
        for z in zooms(layer, detail: detail) {
            for tile in tiles(box, zoom: z) {
                if layer.isSeason, z > packMaxZoom, let flown, !flown(packParent(tile)) { continue }
                out.append(tile)
                if out.count > limit { return out }
            }
        }
        return out
    }

    /// One layer's size before it's fetched.
    public struct Estimate: Sendable, Equatable {
        public let layer: AreaLayer
        /// Requests: every tile of the pyramid (a season's deeper levels only
        /// under flown z15 tiles, when that's known).
        public let tiles: Int
        /// Expected bytes: tiles that should hold an image × the mean size.
        public let bytes: Int64
        /// False for a season whose coverage isn't known (an upper bound).
        public let exact: Bool

        public var overCap: Bool { tiles > AreaPlan.maxTilesPerLayer }

        public init(layer: AreaLayer, tiles: Int, bytes: Int64, exact: Bool) {
            self.layer = layer
            self.tiles = tiles
            self.bytes = bytes
            self.exact = exact
        }
    }

    /// `flownParents`: for a season, the z15 tiles inside the box its pack
    /// holds (nil: not known — every tile counts, an upper bound).
    public static func estimate(_ box: AreaBox, layer: AreaLayer, detail: AreaDetail,
                                flownParents: Set<TileID>? = nil) -> Estimate {
        let zs = zooms(layer, detail: detail)
        guard layer.isSeason, let flownParents else {
            let n = count(box, zooms: zs)
            return Estimate(layer: layer, tiles: n, bytes: Int64(n) * Int64(layer.meanTileBytes), exact: !layer.isSeason)
        }
        // z13–15 are all asked for; only flown z15 tiles (and below them) hold photos
        var requests = count(box, zooms: zs.lowerBound ... min(zs.upperBound, packMaxZoom))
        var images = flownParents.count
        if zs.upperBound > packMaxZoom {
            for z in (packMaxZoom + 1) ... zs.upperBound {
                let r = tileRange(box, zoom: z)
                let d = z - packMaxZoom
                for parent in flownParents {
                    // children of `parent` at z, clipped to the box's range
                    let xs = max(r.x.lowerBound, parent.x << d) ... min(r.x.upperBound, ((parent.x + 1) << d) - 1)
                    let ys = max(r.y.lowerBound, parent.y << d) ... min(r.y.upperBound, ((parent.y + 1) << d) - 1)
                    guard xs.lowerBound <= xs.upperBound, ys.lowerBound <= ys.upperBound else { continue }
                    requests += xs.count * ys.count
                    images += xs.count * ys.count
                }
            }
        }
        return Estimate(layer: layer, tiles: requests, bytes: Int64(images) * Int64(layer.meanTileBytes), exact: true)
    }

    /// The framing bar's check: aerial photos at Fine fit in one download.
    public static func fitsFraming(_ box: AreaBox) -> Bool {
        count(box, zooms: zooms(.aerial, detail: framingDetail)) <= maxTilesPerLayer
    }

    /// Share of the per-layer cap the framing bar's gauge shows (may exceed 1).
    public static func framingFill(_ box: AreaBox) -> Double {
        Double(count(box, zooms: zooms(.aerial, detail: framingDetail))) / Double(maxTilesPerLayer)
    }

    /// What is left of a partly fetched layer: its requests and expected
    /// bytes. `planned`/`done`/`stored`/`bytes` come from the layer's record
    /// (a season's plan is exact once its z15 coverage is known); the share
    /// of answers that held an image so far (≥ 50 answers) stands for the
    /// rest, so known absents and seas aren't counted again. The archive
    /// written at the end holds the whole layer: `finalBytes`.
    public static func remaining(estimate: Estimate, planned: Int, done: Int, stored: Int, bytes: Int64,
                                 meanTileBytes: Double? = nil) -> (estimate: Estimate, finalBytes: Int64) {
        guard planned > 0 else { return (estimate, estimate.bytes) }
        let left = max(0, planned - done)
        let hitRate = done >= 50 ? Double(stored) / Double(done) : 1
        let mean = meanTileBytes ?? (stored > 0 ? Double(bytes) / Double(stored) : Double(estimate.layer.meanTileBytes))
        let more = Int64((Double(left) * hitRate * mean).rounded(.up))
        return (Estimate(layer: estimate.layer, tiles: left, bytes: more, exact: estimate.exact), bytes + more)
    }

    /// Free space a download needs: its bytes, plus the largest layer once
    /// more (finishing a layer writes the archive beside its work file
    /// before the work file goes), plus a margin for the system.
    public static func spaceNeeded(_ estimates: [Estimate]) -> Int64 {
        let total = estimates.reduce(Int64(0)) { $0 + $1.bytes }
        return total + (estimates.map(\.bytes).max() ?? 0) + spaceMargin
    }

    /// A resumed download: the remaining bytes, plus the largest layer's
    /// whole archive (written beside its work file), plus the margin.
    public static func spaceNeeded(remaining: [(estimate: Estimate, finalBytes: Int64)]) -> Int64 {
        remaining.reduce(Int64(0)) { $0 + $1.estimate.bytes } + (remaining.map(\.finalBytes).max() ?? 0) + spaceMargin
    }
}

/// How far the estimates are off, learnt from finished areas: the bytes
/// and tiles of every finished layer of one kind (the seasons share one).
/// Estimates assume `AreaLayer.meanTileBytes`; a city of roofs comes out
/// ~45–60 % larger, so before any area has finished the range shown runs
/// to ×1.6, narrowing as finished layers measure the real mean.
public struct AreaCalibration: Codable, Sendable, Equatable {
    /// Finished layers measured.
    public var layers: Int
    public var tiles: Int
    public var bytes: Int64

    public init(layers: Int = 0, tiles: Int = 0, bytes: Int64 = 0) {
        self.layers = layers
        self.tiles = tiles
        self.bytes = bytes
    }

    /// Below this many measured tiles the nominal mean stands.
    public static let minTiles = 100
    /// The range's upper end before anything was measured.
    public static let uncalibratedHigh = 1.6

    public var isCalibrated: Bool { tiles >= Self.minTiles && layers > 0 }

    public mutating func add(tiles: Int, bytes: Int64) {
        guard tiles > 0, bytes > 0 else { return }
        layers += 1
        self.tiles += tiles
        self.bytes += bytes
    }

    /// The measured mean tile size (nil until calibrated).
    public var meanTileBytes: Double? { isCalibrated ? Double(bytes) / Double(tiles) : nil }

    /// The likely range of a layer the nominal estimate puts at `nominal`
    /// bytes: [nominal, ×1.6] before calibration; around the measured mean
    /// after, ±45 %/√layers but never tighter than ±15 %.
    public func range(nominal: Int64, nominalMean: Int) -> ClosedRange<Int64> {
        guard nominal > 0 else { return 0 ... 0 }
        guard let mean = meanTileBytes else {
            return nominal ... Int64((Double(nominal) * Self.uncalibratedHigh).rounded(.up))
        }
        let centre = Double(nominal) * mean / Double(max(nominalMean, 1))
        let spread = max(0.15, 0.45 / Double(layers).squareRoot())
        let low = Int64((centre * (1 - spread)).rounded(.down))
        return max(0, low) ... Int64((centre * (1 + spread)).rounded(.up))
    }
}

extension AreaLayer {
    /// The calibration a layer shares (all seasons: one).
    public var calibrationKey: String { isSeason ? "season" : rawValue }
}
