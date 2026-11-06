import BackgroundAssets
import CryptoKit
import Foundation
import os

/// Where the encoder was loaded from (Diagnostics).
nonisolated enum PlantIDModelLocation: String, Sendable {
    /// The `plantid` pack's own folder (Background Assets staging, another
    /// container) — or the DEBUG `-dataDir` / `-plantIDDir` folder.
    case pack
    /// The app's own copy in Application Support (`PlantIDModelCopy`).
    case appCopy = "app copy"
}

/// The encoder (`PlantEncoder-w8.mlmodelc`, ~0.6 GB) copied into the app's
/// own container, once per model + pack version, and loaded from there.
///
/// Why: on the device Core ML spent 17 s on the first load AND 32 s on the
/// load after a relaunch — the device-specialised program it builds on a
/// load was evidently not reused when the model lives in the Background
/// Assets staging folder (another container, owned by a system daemon).
/// The headers don't say what keys that cache; a stable path inside our own
/// container, with files we own, is the case Core ML is built for (models
/// shipped in the app bundle or compiled into Application Support). The
/// Diagnostics benchmark compares both locations.
///
/// The copy: made on first use of a model id + pack version, after a free
/// space check, into a temporary folder that is then renamed into place
/// (atomic: a folder named for the model is always complete); copies for
/// other models are deleted first; excluded from backup. Any failure →
/// the pack's folder is used, as before. FileManager clones on APFS where
/// it can (instant, no extra space); the log says how long it took.
nonisolated enum PlantIDModelCopy {
    static let folderName = "PlantIDModel"
    /// Free space left over after the copy (beyond its own size).
    static let margin: Int64 = 1 << 30
    private static let markerName = "copy.json"
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")
    /// All copying and checking is serial and off the cooperative pool (a
    /// 0.6 GB copy blocks its thread for seconds).
    private static let queue = DispatchQueue(label: "org.gruenschloss.izzymap.plantid-copy", qos: .utility)

    static var root: URL { URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory) }

    struct Placed: Sendable {
        let url: URL
        let location: PlantIDModelLocation
        /// "made in 812 ms (0.6 GB)", "made earlier", "not made: …"
        let note: String
    }

    private struct Marker: Codable { var identity: String; var bytes: Int64 }

    /// The encoder to load for the model in `dir`: the app's copy (made now
    /// if missing), else the pack's own.
    static func place(_ dir: URL) async -> Placed {
        await withCheckedContinuation { k in queue.async { k.resume(returning: placeNow(dir)) } }
    }

    /// A copy that failed to load: removed, so the next load makes it again.
    static func discard(_ encoder: URL) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            queue.async {
                let folder = encoder.deletingLastPathComponent()
                if folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
                    try? FileManager.default.removeItem(at: folder)
                }
                k.resume()
            }
        }
    }

    /// What the copy on the device is (Diagnostics): "<folder> · 605 MB", or nil.
    static func describe() -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let copies = items.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !copies.isEmpty else { return nil }
        return copies.map { "\($0.lastPathComponent) · \(StorageText.size(Int(treeSize($0))))" }.joined(separator: "; ")
    }

    /// The model id + pack version + the encoder files' sizes and dates: a
    /// new pack version (new files) gets a new copy.
    static func identity(_ dir: URL) -> String {
        var parts = [PlantIDLoadLog.modelKey(dir)]
        if #available(iOS 27.2, *), let v = try? AssetPackManager.shared.localVersion(ofAssetPackWithID: "plantid") {
            parts.append("pack v\(v)")
        }
        let encoder = dir.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
        for (rel, size, date) in files(encoder) {
            parts.append("\(rel) \(size) \(Int(date?.timeIntervalSince1970 ?? 0))")
        }
        return parts.joined(separator: " · ")
    }

    private static func placeNow(_ dir: URL) -> Placed {
        let fm = FileManager.default
        let source = dir.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
        let start = ContinuousClock.now
        let identity = identity(dir)
        let slug = slug(identity, dir)
        let folder = root.appending(path: slug, directoryHint: .isDirectory)
        let target = folder.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
        func fallback(_ why: String) -> Placed {
            logger.error("app copy not made: \(why, privacy: .public)")
            return Placed(url: source, location: .pack, note: "not made: \(why)")
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var r = root
            try r.setResourceValues(values)
            // other models' copies and half-made leftovers
            for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where item.lastPathComponent != slug {
                try? fm.removeItem(at: item)
                logger.notice("removed \(item.lastPathComponent, privacy: .public)")
            }
            if isComplete(folder, identity: identity) {
                return Placed(url: target, location: .appCopy, note: "made earlier")
            }
            if fm.fileExists(atPath: folder.path(percentEncoded: false)) { try fm.removeItem(at: folder) }
            let need = treeSize(source)
            guard need > 0 else { return fallback("the pack's encoder is empty or unreadable") }
            let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            if let free, free < need + margin {
                return fallback("\(StorageText.size(Int(free))) free, \(StorageText.size(Int(need))) + 1 GB needed")
            }
            let tmp = root.appending(path: ".tmp-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? fm.removeItem(at: tmp) }
            try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
            try fm.copyItem(at: source, to: tmp.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory))
            let copied = treeSize(tmp.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory))
            guard copied == need else { return fallback("copied \(copied) of \(need) bytes") }
            try JSONEncoder().encode(Marker(identity: identity, bytes: need)).write(to: tmp.appending(path: markerName))
            try fm.moveItem(at: tmp, to: folder)
            let ms = Int((start.duration(to: .now) / .milliseconds(1)).rounded())
            logger.info("app copy made in \(ms) ms (\(need) bytes): \(slug, privacy: .public)")
            return Placed(url: target, location: .appCopy, note: "made in \(ms) ms (\(StorageText.size(Int(need))))")
        } catch {
            return fallback(error.localizedDescription)
        }
    }

    private static func isComplete(_ folder: URL, identity: String) -> Bool {
        guard let data = try? Data(contentsOf: folder.appending(path: markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.identity == identity
        else { return false }
        let encoder = folder.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: encoder.appending(path: "coremldata.bin").path(percentEncoded: false))
            && treeSize(encoder) == marker.bytes
    }

    /// "final-mpA01-adaptive-3f9c2a1b7e40": readable, unique per identity.
    private static func slug(_ identity: String, _ dir: URL) -> String {
        let id = PlantIDModelIdentity.load(dir)?.id ?? "model"
        let safe = String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }.prefix(40))
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe)-\(hash)"
    }

    static func treeSize(_ dir: URL) -> Int64 { files(dir).reduce(0) { $0 + $1.1 } }

    private static func files(_ dir: URL) -> [(String, Int64, Date?)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        let base = dir.standardizedFileURL.path(percentEncoded: false)
        var out: [(String, Int64, Date?)] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
            out.append((rel, Int64(v.fileSize ?? 0), v.contentModificationDate))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
