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
    @ObservationIgnored private var recheck: Task<Void, Never>?
    /// Bumped whenever an index is read: photo views ask again then.
    private(set) var revision = 0
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
            // installed but its files not in place yet (the pack arriving):
            // look again shortly — no further state change may come
            if packs.state(.refphotos).isInstalled, recheck == nil {
                recheck = Task {
                    for delay in [1, 3, 10, 30] {
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled, folder == nil else { break }
                        if Self.locate(packs: packs) != nil { recheck = nil; use(packs: packs); return }
                    }
                    recheck = nil
                }
            }
            return
        }
        recheck?.cancel()
        recheck = nil
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
            revision += 1
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

    /// The photo decoded at `pixels` on its long edge (ImageIO thumbnail:
    /// AVIF or JPEG), off the main thread, cached; nil when it can't be
    /// decoded (the reason is logged, category RefPhotos) or didn't decode
    /// in time — the view then sets the name as a plate, never a blank box.
    nonisolated static func image(_ photo: PlantIDRefPhoto, pixels: Int) async -> UIImage? {
        let name = "\(photo.url.lastPathComponent)@\(pixels)"
        if let hit = cache.images.object(forKey: name as NSString) { return hit }
        let made = await RefPhotoDecoder.lane.run(file: photo.url.lastPathComponent) {
            let key = name as NSString
            if let hit = cache.images.object(forKey: key) { return hit }
            let img = RefPhotoDecoder.decode(photo.url, pixels: pixels)
            // a late answer (after the lane's timeout) still fills the cache
            if let img { cache.images.setObject(img, forKey: key) }
            return img
        }
        return made
    }
}

/// ImageIO decoding of the reference photos, with the evidence logged on a
/// failure: which way in (a URL source, else the bytes read by the app
/// itself — the pack lives in a Background Assets daemon's container, so a
/// URL source opened inside ImageIO is worth a fallback), what ImageIO made
/// of the file, how long it took. (2026-11-06: photos stayed grey on an
/// iPhone while the pack was arriving and the model loading; fine after a
/// reopen — hence the view's retries and the index revision.)
nonisolated enum RefPhotoDecoder {
    static let log = Logger(subsystem: "org.gruenschloss.izzymap", category: "RefPhotos")

    enum Way: String, Sendable { case url, data }

    /// One decode, described.
    struct Attempt: Sendable {
        var way: Way
        var bytes: Int?
        var readError: String?
        var sourceCreated = false
        var type: String?
        var status: String?
        var count = 0
        var header: String?     // pixel size from the properties (no decode)
        var thumb: String?      // thumbnail size, or nil = failed
        var full: String?       // full decode size (only tried when the thumbnail failed)
        var ms = 0.0

        var ok: Bool { thumb != nil || full != nil }

        var line: String {
            var parts: [String] = []
            if way == .data { parts.append(readError.map { "read failed: \($0)" } ?? "read \(bytes.map(String.init) ?? "?") B") }
            if way == .data, readError != nil { return parts.joined() }
            parts.append(sourceCreated ? "source yes" : "source NIL")
            if sourceCreated {
                parts.append(type ?? "type nil")
                parts.append("status \(status ?? "?")")
                parts.append("\(count) image\(count == 1 ? "" : "s")")
                parts.append("header \(header ?? "none")")
                parts.append("thumb \(thumb ?? "NIL")")
                if let full { parts.append("full \(full)") }
            }
            parts.append(String(format: "%.0f ms", ms))
            return parts.joined(separator: " · ")
        }
    }

    /// The photo at `pixels`: from a URL source, else from the bytes; each
    /// failure logged with what ImageIO said.
    static func decode(_ url: URL, pixels: Int) -> UIImage? {
        let (img, a) = attempt(url, pixels: pixels, way: .url)
        if let img { return UIImage(cgImage: img) }
        log.error("refphoto \(url.lastPathComponent, privacy: .public) via url failed: \(a.line, privacy: .public)")
        let (img2, b) = attempt(url, pixels: pixels, way: .data)
        if let img2 {
            log.notice("refphoto \(url.lastPathComponent, privacy: .public) decoded via data instead (\(b.line, privacy: .public))")
            return UIImage(cgImage: img2)
        }
        log.error("refphoto \(url.lastPathComponent, privacy: .public) via data failed: \(b.line, privacy: .public)")
        return nil
    }

    /// One way in: the thumbnail (ImageIO scales while decoding), else the
    /// whole image (the photos are ≤ 512 px).
    private static func attempt(_ url: URL, pixels: Int, way: Way) -> (CGImage?, Attempt) {
        var a = Attempt(way: way)
        let t0 = ContinuousClock.now
        func done(_ img: CGImage?) -> (CGImage?, Attempt) {
            a.ms = (ContinuousClock.now - t0) / .milliseconds(1)
            return (img, a)
        }
        let src: CGImageSource?
        switch way {
        case .url:
            src = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data:
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                let ns = error as NSError
                a.readError = "\(ns.domain) \(ns.code)\((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? "")"
                return done(nil)
            }
            a.bytes = data.count
            let hint: [CFString: Any] = [kCGImageSourceTypeIdentifierHint: url.pathExtension.lowercased() == "avif" ? "public.avif" : "public.jpeg"]
            src = CGImageSourceCreateWithData(data as CFData, hint as CFDictionary)
        }
        guard let src else { return done(nil) }
        a.sourceCreated = true
        a.type = CGImageSourceGetType(src) as String?
        a.status = statusName(CGImageSourceGetStatus(src))
        a.count = CGImageSourceGetCount(src)
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            a.header = "\(w)×\(h)"
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(pixels, 64)]
        let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        a.thumb = thumb.map { "\($0.width)×\($0.height)" }
        var full: CGImage?
        if thumb == nil {
            full = CGImageSourceCreateImageAtIndex(src, 0, nil)
            a.full = full.map { "\($0.width)×\($0.height)" } ?? "NIL"
            if full == nil { a.status = "\(a.status ?? "?") → index \(statusName(CGImageSourceGetStatusAtIndex(src, 0)))" }
        }
        return done(thumb ?? full)
    }

    static func statusName(_ s: CGImageSourceStatus) -> String {
        switch s {
        case .statusComplete: "complete"
        case .statusIncomplete: "incomplete"
        case .statusReadingHeader: "readingHeader"
        case .statusUnknownType: "unknownType"
        case .statusInvalidData: "invalidData"
        case .statusUnexpectedEOF: "unexpectedEOF"
        @unknown default: "raw \(s.rawValue)"
        }
    }

    /// The decode lane: one decode at a time on a queue of its own, never
    /// on Swift's cooperative pool — a screenful of decodes parked there
    /// stalled in the simulator (none returned within 20 s, CPU idle;
    /// 2026-11-06). A decode that doesn't answer within `timeout` gives
    /// nil (the plate) and the lane moves to a fresh queue, so one stuck
    /// decode can't keep every later photo blank; after three stuck
    /// decodes the lane gives up (logged) rather than leak more threads.
    static let lane = Lane()

    final class Lane: @unchecked Sendable {
        private let lock = NSLock()
        private var queue = DispatchQueue(label: "org.gruenschloss.izzymap.refphotos", qos: .userInitiated)
        private var generation = 0
        private var stuck = 0
        let timeout: TimeInterval = 5

        private func snapshot() -> (DispatchQueue, Int, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (queue, generation, stuck >= 3)
        }

        func run(file: String, _ work: @escaping @Sendable () -> UIImage?) async -> UIImage? {
            let (q, gen, givenUp) = snapshot()
            if givenUp { return nil }
            return await withCheckedContinuation { (k: CheckedContinuation<UIImage?, Never>) in
                let once = Once(k)
                q.async { once.resume(work()) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.timeout) {
                    guard once.resume(nil) else { return }
                    self.lock.lock()
                    var replaced = false
                    if self.generation == gen {   // first timeout on this queue: replace it
                        self.generation += 1
                        self.stuck += 1
                        self.queue = DispatchQueue(label: "org.gruenschloss.izzymap.refphotos.\(self.generation)", qos: .userInitiated)
                        replaced = true
                    }
                    let n = self.stuck
                    self.lock.unlock()
                    RefPhotoDecoder.log.error("refphoto \(file, privacy: .public): no answer within \(Int(self.timeout)) s\(replaced ? " — decode queue replaced (\(n) stuck)" : "", privacy: .public)")
                }
            }
        }
    }

    /// Resumes a continuation once; true for the call that did.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var k: CheckedContinuation<UIImage?, Never>?
        init(_ k: CheckedContinuation<UIImage?, Never>) { self.k = k }
        @discardableResult func resume(_ v: UIImage?) -> Bool {
            lock.lock()
            let k = self.k
            self.k = nil
            lock.unlock()
            k?.resume(returning: v)
            return k != nil
        }
    }
}

/// A reference photo, square-filled at `side`, drawn once it is decoded; a
/// stand-in's caption ("Herbarium specimen") over its lower edge from
/// tile size up (a list thumbnail is too small to carry it).
private struct PhotoRequest: Equatable {
    let url: URL
    let revision: Int
}

struct RefPhotoImage: View {
    let photo: PlantIDRefPhoto
    let side: CGFloat
    var showsCaption = true
    /// The class, for the name plate shown when the photo can't be decoded.
    var label: PlantIDLabel?
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if failed {
                NamePlate(label: label, side: side)
            } else {
                Rectangle().fill(Color(uiColor: .tertiarySystemFill))
            }
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
            if showsCaption, side >= 80, !failed, let caption = photo.caption {
                PhotoTag(text: caption, compact: side < 140)
            }
        }
        // again for a new index (a pack update), and a failed decode twice
        // more (one that timed out behind a busy moment) before the plate
        .task(id: PhotoRequest(url: photo.url, revision: PlantIDRefPhotos.shared.revision)) {
            var img: UIImage?
            for pause in [0, 1, 3] {
                if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                guard !Task.isCancelled else { return }
                img = await PlantIDRefPhotos.image(photo, pixels: Int(side * scale))
                if img != nil { break }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = img
                failed = img == nil
            }
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
