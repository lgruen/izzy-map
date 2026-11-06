import Foundation
import IzzyKit

/// Which files of a resolved pack `PackIntegrity` checks, and what a cached
/// verdict is keyed on. After the iPad ran out of space mid-download
/// (2026-11-06) the system reported packs "downloaded" whose files were
/// cut short — a truncated PMTiles must never reach MapLibre, nor a
/// truncated model Core ML: `PackStore` treats a damaged pack as missing
/// and repairs it (remove, download again).
nonisolated enum PackVerification {
    /// The files to look at, nil when the resolution has none for the pack
    /// (nothing to say — a fake without a directory, a folder not found).
    static func inputs(_ pack: Pack, in found: PackResolution) -> [URL]? {
        switch pack {
        case .plantid:
            guard let dir = found.folders[.plantid] ?? found.plantID else { return nil }
            let encoder = dir.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
            return PlantIDFiles.packPaths.filter { !$0.hasSuffix("/") }.map { dir.appending(path: String($0.dropFirst(PlantIDFiles.folder.count + 1))) }
                + [encoder.appending(path: "model.mil"), encoder.appending(path: "weights/weight.bin")]
        case .refphotos:
            guard let dir = found.folders[.refphotos] else { return nil }
            return [dir.appending(path: RefPhotoFiles.index)]
        default:
            let urls = pack.archives.compactMap { found.location.url(for: $0) }
            return urls.count == pack.archives.count && !urls.isEmpty ? urls : nil
        }
    }

    /// The cache key: every input's path, size and date.
    static func signature(_ pack: Pack, in found: PackResolution) -> String? {
        inputs(pack, in: found).map { "\(pack.rawValue)|" + PackIntegrity.signature($0) }
    }

    /// The full check (synchronous file I/O: off the main thread).
    static func check(_ pack: Pack, in found: PackResolution) -> PackIntegrity.Report? {
        switch pack {
        case .plantid:
            guard let dir = found.folders[.plantid] ?? found.plantID else { return nil }
            return plantID(dir)
        case .refphotos:
            guard let dir = found.folders[.refphotos] else { return nil }
            return PackIntegrity.refPhotos(dir, prefix: RefPhotoFiles.folder + "/")
        default:
            let pairs = pack.archives.compactMap { a in found.location.url(for: a).map { (a, $0) } }
            guard pairs.count == pack.archives.count, !pairs.isEmpty else { return nil }
            return PackIntegrity.Report(files: pairs.map { PackIntegrity.pmtiles($0.1, path: $0.0.fileName) })
        }
    }

    /// The plant-ID folder as the pack lists it (also run before every
    /// model load, `PlantIDEngine`).
    static func plantID(_ dir: URL) -> PackIntegrity.Report {
        let required = PlantIDFiles.packPaths.filter { !$0.hasSuffix("/") }.map { String($0.dropFirst(PlantIDFiles.folder.count + 1)) }
        return PackIntegrity.plantID(dir, prefix: PlantIDFiles.folder + "/", encoder: PlantIDFiles.encoder, required: required)
    }

    /// Posted (object: the pack's raw value) when a reader finds a pack's
    /// files damaged — the plant-ID load: the store looks again at once.
    static let damagedNotification = Notification.Name("org.gruenschloss.izzymap.packDamaged")
}
