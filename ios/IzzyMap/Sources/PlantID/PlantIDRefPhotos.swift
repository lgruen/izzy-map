import BackgroundAssets
import Foundation
import ImageIO
import IzzyKit
import os
import SwiftUI
import System

/// The `refphotos` pack's index.json (pipeline/plantid/build_refphotos_v2.py):
/// one photo per class, keyed by name, with the class index `u` (= the
/// v2-labels row), the file and the ready-made attribution line.
nonisolated struct PlantIDRefIndex: Decodable, Sendable {
    struct Photo: Decodable, Sendable {
        var u: Int?
        var file: String
        var attribution: String
        var license: String?
        var licence: String?
    }

    var built: String?
    var count: Int?
    var photos: [String: Photo]
}

/// One reference photo: where it is and the credit to show under it.
nonisolated struct PlantIDRefPhoto: Sendable, Equatable {
    let url: URL
    let attribution: String
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

    /// Reads the index when the pack's folder is new (cheap when unchanged).
    func use(packs: PackStore) {
        guard let dir = Self.locate(packs: packs), dir != folder, dir != loading else { return }
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

    /// The reference photo of class `label` (by index, else by name).
    func photo(for label: Int, name: String?) -> PlantIDRefPhoto? {
        guard let folder else { return nil }
        guard let p = byClass[label] ?? name.flatMap({ byName[$0] }) else { return nil }
        return PlantIDRefPhoto(url: folder.appending(path: p.file), attribution: p.attribution)
    }

    /// The photo decoded at `pixels` on its long edge (ImageIO thumbnail:
    /// AVIF or JPEG), off the main thread, cached.
    nonisolated static func image(_ photo: PlantIDRefPhoto, pixels: Int) async -> UIImage? {
        let key = "\(photo.url.lastPathComponent)@\(pixels)" as NSString
        if let hit = cache.images.object(forKey: key) { return hit }
        let made: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(photo.url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(pixels, 64)]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
        if let made { cache.images.setObject(made, forKey: key) }
        return made
    }
}

/// A reference photo, square-filled at `side`, drawn once it is decoded.
struct RefPhotoImage: View {
    let photo: PlantIDRefPhoto
    let side: CGFloat
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
        .task(id: photo.url) {
            let img = await PlantIDRefPhotos.image(photo, pixels: Int(side * scale))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
        .accessibilityHidden(true)
    }
}

/// The credit under a reference photo (CC BY / BY-NC, APII: LICENSING.md).
struct RefPhotoCredit: View {
    let photo: PlantIDRefPhoto

    var body: some View {
        Text(photo.attribution)
            .font(.caption2)
            .foregroundStyle(DesignColor.secondaryInk)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("plant-id-ref-credit")
    }
}
