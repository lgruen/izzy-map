import Foundation
import ImageIO
import IzzyKit
import UIKit

/// Understorey Network photos (© their photographers): shown straight from
/// UN, fetched on view and kept in Application Support (excluded from
/// backup) — never bundled, committed or hosted by us (LICENSING.md §2).
/// Large versions live where the photo batch keeps them (`plants/`, one
/// file per photo, size suffix left out of the name); thumbnails in their
/// own folder. Offline and not stored → nil: the caller keeps its
/// pictogram, never a broken image.
actor PlantPhotoStore {
    static let shared = PlantPhotoStore(storage: .shared)

    enum Size: Sendable { case thumb, large }

    let storage: ExtrasStorage
    private let session = ExtrasNetwork.session(timeout: 20)
    /// NSCache is thread-safe; the box only tells Swift so.
    private final class Memory: @unchecked Sendable {
        let cache: NSCache<NSString, UIImage> = {
            let c = NSCache<NSString, UIImage>()
            c.countLimit = 200
            return c
        }()
    }
    private nonisolated let memoryBox = Memory()
    private nonisolated var memory: NSCache<NSString, UIImage> { memoryBox.cache }
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// Photos that failed this session (a 404, a server error): not asked
    /// for again until the app opens again. Transient failures are not
    /// kept (the views re-ask when connectivity changes).
    private var failed: Set<String> = []

    init(storage: ExtrasStorage) { self.storage = storage }

    private static func key(_ photo: PlantPhoto, _ size: Size, _ pixels: Int) -> String {
        "\(size == .thumb ? "t" : "l")\(pixels)/\(photo.storedName)"
    }

    /// An image already decoded this session (no I/O; for first frames).
    nonisolated func cached(_ photo: PlantPhoto, size: Size, pixels: Int) -> UIImage? {
        memory.object(forKey: Self.key(photo, size, pixels) as NSString)
    }

    /// The photo at about `pixels` on its longer side: from the device,
    /// else fetched from UN and kept.
    func image(_ photo: PlantPhoto, size: Size, pixels: Int) async -> UIImage? {
        let key = Self.key(photo, size, pixels)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inflight[key] { return await running.value }
        let task = Task { await self.load(photo, size: size, pixels: pixels) }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    private func load(_ photo: PlantPhoto, size: Size, pixels: Int) async -> UIImage? {
        let largeFile = storage.existing(.photos, photo.storedName)
        let thumbFile = storage.thumbnails.appending(path: photo.storedName)
        switch size {
        case .thumb:
            if FileManager.default.fileExists(atPath: thumbFile.path(percentEncoded: false)) {
                return Self.decode(thumbFile, pixels: pixels)
            }
            // offline, a stored large version is all there is
            if let largeFile { return Self.decode(largeFile, pixels: pixels) }
            guard let url = photo.thumbURL ?? photo.largeURL else { return nil }
            guard let file = await fetch(url, name: photo.storedName + (photo.thumb == nil ? "" : "#t")) else { return nil }
            if photo.thumb == nil {
                // no thumbnail on UN: the large file IS the photo — keep it where the batch would
                guard let kept = try? storage.adopt(file, as: .photos, photo.storedName) else { return nil }
                return Self.decode(kept, pixels: pixels)
            }
            try? FileManager.default.removeItem(at: thumbFile)
            guard (try? FileManager.default.moveItem(at: file, to: thumbFile)) != nil else { return nil }
            return Self.decode(thumbFile, pixels: pixels)
        case .large:
            if let largeFile { return Self.decode(largeFile, pixels: pixels) }
            guard let url = photo.largeURL, let file = await fetch(url, name: photo.storedName) else { return nil }
            guard let kept = try? storage.adopt(file, as: .photos, photo.storedName) else { return nil }
            storage.updateGone(.photos) { $0.forget(photo.storedName) }
            return Self.decode(kept, pixels: pixels)
        }
    }

    /// A checked image file in a temporary location, or nil.
    private func fetch(_ url: URL, name: String) async -> URL? {
        guard !failed.contains(url.absoluteString) else { return nil }
        let (result, file) = await ExtrasNetwork.fetch(url, kind: .photos, session: session)
        if FetchVerdict.of(result, kind: .photos) == .store, let file { return file }
        if let file { try? FileManager.default.removeItem(at: file) }
        // nothing learned about the photo (offline, a stall, a captive
        // portal's login page): try again when it is next shown or the
        // network changes — only a real answer marks it failed
        if !FetchVerdict.of(result, kind: .photos).isTransient { failed.insert(url.absoluteString) }
        return nil
    }

    /// Decodes at about `pixels` on the longer side (ImageIO thumbnails:
    /// no full-size bitmap for a 56 pt row).
    private static func decode(_ url: URL, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, pixels),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
