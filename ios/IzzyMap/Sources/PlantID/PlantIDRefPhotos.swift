import BackgroundAssets
import Foundation
import ImageIO
import IzzyKit
import os
import SwiftUI
import System

/// The `refphotos` pack's index.json (pipeline/plantid/build_refphotos_v2.py):
/// one photo per class, keyed by name, with the class index `u` (= the
/// v2-labels row), the file and the ready-made attribution line; a
/// `caption` ("Herbarium specimen", "Hand-held sprig") when no field photo
/// was acceptable and a specimen or hand-held photo stands in.
nonisolated struct PlantIDRefIndex: Decodable, Sendable {
    struct Photo: Decodable, Sendable {
        var u: Int?
        var file: String
        var attribution: String
        var license: String?
        var licence: String?
        var caption: String?
    }

    var built: String?
    var count: Int?
    var photos: [String: Photo]
}

/// One reference photo: where it is, the credit to show with it (complete:
/// author, licence, source) and what it shows when it isn't a field photo.
nonisolated struct PlantIDRefPhoto: Sendable, Equatable {
    let url: URL
    let attribution: String
    var caption: String?
}

/// Reference photos for Identify, read from the `refphotos` pack once it
/// is on the device (a DEBUG `-dataDir` run: the staged pack or the
/// pipeline's output beside it). Until then `photo(for:)` is nil and the
/// views show the guide's photo or a name plate.
@MainActor
@Observable
final class PlantIDRefPhotos {
    static let shared = PlantIDRefPhotos()

    private(set) var folder: URL?
    private(set) var count = 0
    private(set) var built: String?
    @ObservationIgnored private var byClass: [Int: PlantIDRefIndex.Photo] = [:]
    @ObservationIgnored private var byName: [String: PlantIDRefIndex.Photo] = [:]
    @ObservationIgnored private var loading: URL?
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")
    /// NSCache is thread-safe; the box only tells Swift so.
    nonisolated private final class Cache: @unchecked Sendable {
        let images: NSCache<NSString, UIImage> = {
            let c = NSCache<NSString, UIImage>()
            c.countLimit = 40
            return c
        }()
    }
    nonisolated private static let cache = Cache()

    /// The folder holding index.json, if any.
    static func locate(packs: PackStore) -> URL? {
        func has(_ dir: URL) -> Bool {
            FileManager.default.fileExists(atPath: dir.appending(path: RefPhotoFiles.index).path(percentEncoded: false))
        }
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "refPhotosDir"), !dir.isEmpty {
            let url = URL(filePath: dir, directoryHint: .isDirectory)
            return has(url) ? url : nil
        }
        if case let .debugDirectory(data) = packs.mode {
            return RefPhotoFiles.staged(in: data).first(where: has)
        }
        #endif
        guard packs.state(.refphotos).isInstalled,
              let index = try? AssetPackManager.shared.url(for: FilePath("\(RefPhotoFiles.folder)/\(RefPhotoFiles.index)"))
        else { return nil }
        let dir = index.deletingLastPathComponent()
        return has(dir) ? dir : nil
    }

    /// Reads the index when the pack's folder is new (cheap when unchanged);
    /// forgets it when the pack is gone (removed, or replaced by a version
    /// whose files aren't in place yet), so no view points at missing files.
    func use(packs: PackStore) {
        guard let dir = Self.locate(packs: packs) else {
            if folder != nil || loading != nil { forget() }
            return
        }
        guard dir != folder, dir != loading else { return }
        loading = dir
        Task {
            let decoded: PlantIDRefIndex? = await Task.detached(priority: .utility) {
                do {
                    return try JSONDecoder().decode(PlantIDRefIndex.self, from: Data(contentsOf: dir.appending(path: RefPhotoFiles.index)))
                } catch {
                    Self.logger.error("refphotos index unreadable: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }.value
            guard loading == dir else { return }   // forgotten (or another folder) meanwhile
            loading = nil
            guard let decoded else { return }
            var c: [Int: PlantIDRefIndex.Photo] = [:]
            for p in decoded.photos.values { if let u = p.u { c[u] = p } }
            byClass = c
            byName = decoded.photos
            count = decoded.photos.count
            built = decoded.built
            folder = dir
            Self.logger.info("refphotos: \(decoded.photos.count) photos in \(dir.path(percentEncoded: false), privacy: .public)")
        }
    }

    private func forget() {
        Self.logger.info("refphotos: gone, index forgotten")
        loading = nil
        folder = nil
        byClass = [:]
        byName = [:]
        count = 0
        built = nil
        Self.cache.images.removeAllObjects()
    }

    /// The reference photo of class `label`: by index (= the v2-labels row;
    /// a Tasmanian row's display name may differ from the index's key),
    /// else by name. The DEBUG fake identifier's labels aren't the pack's
    /// rows: by name only.
    func photo(for label: Int, name: String?) -> PlantIDRefPhoto? {
        guard let folder else { return nil }
        var byIndex = byClass[label]
        #if DEBUG
        if !(UserDefaults.standard.string(forKey: "plantIDFake") ?? "").isEmpty { byIndex = nil }
        #endif
        guard let p = byIndex ?? name.flatMap({ byName[$0] }) else { return nil }
        return PlantIDRefPhoto(url: folder.appending(path: p.file), attribution: p.attribution,
                               caption: p.caption.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Decoding blocks (ImageIO's AV1 decoder for AVIF): one at a time on a
    /// queue of its own, never on Swift's cooperative pool — a screenful of
    /// decodes parked there stalled in the simulator (none returned within
    /// 20 s, CPU idle; 2026-11-06), so no photo ever appeared.
    nonisolated private static let decodeQueue = DispatchQueue(label: "org.gruenschloss.izzymap.refphotos", qos: .userInitiated)

    /// The photo decoded at `pixels` on its long edge (ImageIO thumbnail:
    /// AVIF or JPEG), off the main thread, cached.
    nonisolated static func image(_ photo: PlantIDRefPhoto, pixels: Int) async -> UIImage? {
        let key = "\(photo.url.lastPathComponent)@\(pixels)" as NSString
        if let hit = cache.images.object(forKey: key) { return hit }
        let made: UIImage? = await withCheckedContinuation { done in
            decodeQueue.async {
                if let hit = cache.images.object(forKey: key) { return done.resume(returning: hit) }
                done.resume(returning: decode(photo.url, pixels: pixels))
            }
        }
        if let made { cache.images.setObject(made, forKey: key) } else {
            logger.error("refphoto undecodable: \(photo.url.lastPathComponent, privacy: .public)")
        }
        return made
    }

    nonisolated private static func decode(_ url: URL, pixels: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(pixels, 64)]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return UIImage(cgImage: thumb) }
        // should the thumbnail path fail: the photos are ≤ 512 px, decode it whole
        return CGImageSourceCreateImageAtIndex(src, 0, nil).map { UIImage(cgImage: $0) }
    }
}

/// A reference photo, square-filled at `side`, drawn once it is decoded; a
/// stand-in's caption ("Herbarium specimen") over its lower edge from
/// tile size up (a list thumbnail is too small to carry it).
struct RefPhotoImage: View {
    let photo: PlantIDRefPhoto
    let side: CGFloat
    var showsCaption = true
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if showsCaption, side >= 80, let caption = photo.caption {
                PhotoTag(text: caption, compact: side < 140)
            }
        }
        .task(id: photo.url) {
            let img = await PlantIDRefPhotos.image(photo, pixels: Int(side * scale))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
        .accessibilityHidden(true)
    }
}

/// Small white text on a dark band over a photo's corner ("Your photo",
/// "Herbarium specimen").
struct PhotoTag: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(compact ? .system(size: 10, weight: .semibold) : .caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(.black.opacity(0.5))
            .padding(compact ? 4 : 8)
            .accessibilityIdentifier("plant-id-ref-caption")
    }
}

/// The credit under a reference photo (CC BY / BY-NC, APII: LICENSING.md):
/// always complete — author, licence and source — however many lines.
struct RefPhotoCredit: View {
    let photo: PlantIDRefPhoto

    var body: some View {
        Text(photo.attribution)
            .font(.caption2)
            .foregroundStyle(DesignColor.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("plant-id-ref-credit")
    }
}
