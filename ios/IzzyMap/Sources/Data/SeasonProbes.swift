import Foundation
import IzzyKit
import Synchronization

/// A local pack as a tile-existence probe: a PMTiles directory lookup on the
/// device, never a network request.
nonisolated struct PackProbe: TileExistenceProbe {
    let reader: PMTilesReader

    @concurrent func hasTile(_ tile: TileID) async -> Bool? {
        try? reader.tileExists(z: tile.z, x: tile.x, y: tile.y)
    }
}

/// The local season packs' readers, opened on first use (off the main
/// thread) and kept for the process. A pack that fails to open is "not on
/// the device" for the caption.
nonisolated final class SeasonProbes: Sendable {
    private let urls: [URL?]
    private let readers = Mutex<[Int: PMTilesReader]>([:])

    init(location: DataLocation) {
        urls = Season.all.map { location.url(for: $0.archive) }
    }

    /// One probe per season, oldest first; nil = not on the device.
    func probes() -> [(any TileExistenceProbe)?] {
        urls.enumerated().map { i, url -> (any TileExistenceProbe)? in
            guard let url else { return nil }
            if let cached = readers.withLock({ $0[i] }) { return PackProbe(reader: cached) }
            guard let reader = try? PMTilesReader(url: url) else { return nil }
            readers.withLock { $0[i] = reader }
            return PackProbe(reader: reader)
        }
    }

    /// The caption at a point, computed off the main thread.
    @concurrent func caption(cutoff: Int, longitude: Double, latitude: Double, mapZoom: Double) async -> SeasonCoverage.Caption {
        await SeasonCoverage.caption(cutoff: cutoff, probes: probes(), longitude: longitude, latitude: latitude, mapZoom: mapZoom)
    }
}
