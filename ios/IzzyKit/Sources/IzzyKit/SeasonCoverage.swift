import Foundation

/// A web-mercator tile address (XYZ, y from the north).
public struct TileID: Sendable, Hashable, CustomStringConvertible {
    public var z: Int
    public var x: Int
    public var y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }

    /// The tile holding a point at zoom `z`.
    public init(longitude: Double, latitude: Double, zoom z: Int) {
        let n = Double(1 << z)
        let lat = min(max(latitude, -85.051_128_78), 85.051_128_78) * .pi / 180
        let x = Int(((longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n).rounded(.down))
        self.init(z: z, x: min(max(x, 0), (1 << z) - 1), y: min(max(y, 0), (1 << z) - 1))
    }

    public var description: String { "\(z)/\(x)/\(y)" }
}

/// Answers "does this local archive hold a tile here?" — a directory lookup
/// in a PMTiles file on the device, never a network request.
public protocol TileExistenceProbe: Sendable {
    /// nil when the archive can't be read (treated as "no photo").
    func hasTile(_ tile: TileID) async -> Bool?
}

/// The season stack's coverage caption: which flying season's photo shows
/// at the map centre (docs/NATIVE_PLAN.md §3 "Seasons", web protocol.ts
/// `seasonAt`). Probes LOCAL season packs only, at the zoom MapLibre draws
/// 256 px tiles at — round(zoom + 1), capped at the packs' z15.
public enum SeasonCoverage {
    /// The packs' deepest level.
    public static let packMaxZoom = 15
    /// The top season streams without its pack only from this tile zoom
    /// (the app's style uses the same constant): below it a statewide view
    /// of a 6–15 % patchwork would be mostly 404s.
    public static let liveMinZoomWithoutPack = 11

    /// Tile zoom drawn at map zoom `mapZoom` for 256 px raster tiles.
    public static func probeZoom(mapZoom: Double) -> Int {
        min(packMaxZoom, max(0, Int((mapZoom + 1).rounded())))
    }

    /// What the caption says. Only the TOP season shown (the cutoff) ever
    /// streams from LIST (StyleBuilder gives it the one live season source);
    /// an older season that isn't on the device simply isn't drawn. So "may
    /// stream" is said only when the top season's pack is missing.
    public enum Caption: Sendable, Equatable {
        /// "Showing 2023–24 photos here"; `newerMayStream` when the top
        /// season (newer than the one shown) isn't on the device and may
        /// stream over it while online.
        case showing(season: Int, newerMayStream: Bool)
        /// No local season up to the cutoff has a photo here and the top
        /// one is on the device: "…the topo map shows instead" (`partial`
        /// when some older season isn't on the device).
        case noneHere(cutoff: Int, partial: Bool = false)
        /// No local season has a photo here and the top season isn't on the
        /// device: it may stream while online.
        case noneOnDevice(cutoff: Int)
    }

    /// The caption for seasons `0…cutoff` (oldest first) at a point.
    /// `probes[i]` is season i's local pack, nil when it isn't on the device.
    public static func caption(
        cutoff: Int, probes: [(any TileExistenceProbe)?],
        longitude: Double, latitude: Double, mapZoom: Double
    ) async -> Caption {
        let top = min(max(cutoff, 0), probes.count - 1)
        guard top >= 0 else { return .noneOnDevice(cutoff: cutoff) }
        let tile = TileID(longitude: longitude, latitude: latitude, zoom: probeZoom(mapZoom: mapZoom))
        // the top season streams (while online) only without its pack, and
        // only from the tile zoom its live source starts at
        let topMissing = probes[top] == nil && tile.z >= liveMinZoomWithoutPack
        var anyMissing = false
        for i in stride(from: top, through: 0, by: -1) {
            guard let probe = probes[i] else {
                if i < top || !topMissing { anyMissing = true }
                continue
            }
            if await probe.hasTile(tile) == true { return .showing(season: i, newerMayStream: topMissing && i < top) }
        }
        return topMissing ? .noneOnDevice(cutoff: top) : .noneHere(cutoff: top, partial: anyMissing)
    }

    /// Words for a caption. `labels[i]` = "2023–24"; `device` = "iPhone".
    public static func text(_ caption: Caption, labels: [String], device: String) -> String {
        func label(_ i: Int) -> String { labels.indices.contains(i) ? labels[i] : "?" }
        switch caption {
        case let .showing(season, newer):
            return newer
                ? "Showing \(label(season)) photos here — newer photos not on this \(device) may stream while online"
                : "Showing \(label(season)) photos here"
        case let .noneHere(cutoff, partial):
            return partial
                ? "No downloaded photos up to \(label(cutoff)) here — the topo map shows instead"
                : "No photos up to \(label(cutoff)) here — the topo map shows instead"
        case let .noneOnDevice(cutoff):
            return "No downloaded photos up to \(label(cutoff)) here — \(label(cutoff)) isn't on this \(device) and may stream while online"
        }
    }
}
