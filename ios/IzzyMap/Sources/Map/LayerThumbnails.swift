import CryptoKit
import IzzyKit
import MapLibre
import os
import SwiftUI
import UIKit

/// What a Layers-sheet tile shows.
nonisolated enum ThumbnailSubject: Hashable, Sendable {
    case base(BaseMap)
    case overlay(Overlay)
    case relief
    case trees

    /// The layer state drawn for this tile, derived from the current one so
    /// the tile previews what tapping it would show: bases bare (no overlay),
    /// overlays over the current base at the current strength, relief over
    /// the bare base, trees over the bare base.
    func state(from current: LayerState) -> LayerState {
        var s = current
        s.relief = false
        s.trees = false
        switch self {
        case let .base(base): s.base = base; s.overlay = .none
        case let .overlay(overlay): s.overlay = overlay
        case .relief: s.overlay = .none; s.relief = true
        case .trees: s.overlay = .none; s.trees = true
        }
        // fields the tile doesn't draw don't vary its key
        if s.overlay == .none { s.strength = LayerState.default.strength }
        if s.base != .seasons { s.season = LayerState.default.season }
        return s
    }

    /// The archive without which the tile would show nothing of its own.
    var requiredArchive: Archive? {
        switch self {
        case let .base(base): base.archive
        case let .overlay(overlay): overlay.archive
        case .relief: .relief
        case .trees: nil
        }
    }

    /// One fixed place for every tile, so the differences read; trees need
    /// Hobart's CBD instead.
    var camera: (latitude: Double, longitude: Double, zoom: Double) {
        switch self {
        case .trees: ThumbnailSubject.treesPlace
        default: ThumbnailSubject.place
        }
    }

    /// Picked by rendering candidates side by side (2026-11-03: Ben Lomond,
    /// Mt Roland, kunanyi, Cradle, Mt Field, Mt Arthur): the slopes of Mt
    /// Arthur east of Launceston at z12 — all land; topo roads and streams on
    /// paper white, dark forest on the photos, the 1:100k sheet's greens on
    /// the paper map, shaded spurs on relief, and a LIST flying-project
    /// edge across the frame, so "By season" shows its patchwork (photo
    /// one side, topo the other) instead of repeating "Aerial". Found by
    /// scanning the packs for steep z15 tiles on a season coverage edge.
    static let place = debugPlace("thumbnailPlace") ?? (latitude: -41.3438, longitude: 147.5024, zoom: 12.0)
    /// The densest run of register trees (the Queens Domain), at z15.3:
    /// single discs (clusters end at z15), not a count.
    static let treesPlace = debugPlace("thumbnailTreesPlace") ?? (latitude: -42.8674, longitude: 147.3333, zoom: 15.3)

    /// DEBUG `-thumbnailPlace "lat,lon,zoom"`: try another framing.
    private static func debugPlace(_ key: String) -> (latitude: Double, longitude: Double, zoom: Double)? {
        #if DEBUG
        // a leading "@" keeps a negative latitude from reading as a flag
        let text = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let v = text.split(separator: ",").compactMap { Double($0) }
        if v.count == 3 { return (v[0], v[1], v[2]) }
        #endif
        return nil
    }
}

/// Layer thumbnails for the Layers sheet, rendered on the device from the
/// local packs with MapLibre's supported `MLNMapSnapshotter` — never bundled:
/// the aerial and Tasmap rasters are CC BY-NC-ND, so they're only ever drawn
/// on the device, like the map itself.
///
/// - One render at a time, in request order, de-duplicated by key. A tile
///   that leaves the screen (or whose state changes) withdraws its request;
///   work nobody waits for is dropped before it starts, and a running
///   snapshot is cancelled.
/// - Rendered from the packs only (the style without live sources, pack z15
///   stretched as offline): deterministic and cached on disk
///   (Caches/LayerThumbnails) under a key of the tile's layer state, the
///   identity of every pack, the app build and the bundled tables, the size
///   and the scale. A pack that appears, changes or goes away changes the
///   key. The map is always a light printed sheet: appearance isn't in it.
/// - A tile whose own pack is missing renders from live LIST tiles only
///   while online (kept in memory, never on disk); offline it keeps its
///   placeholder and renders when the network comes back.
/// - Memory: at most `memoryLimit` images plus the last one per tile;
///   a memory warning drops all but the last ones.
@MainActor
@Observable
final class LayerThumbnails {
    /// Rendered size in points (4:3).
    nonisolated static let size = CGSize(width: 120, height: 90)
    /// Bump to re-render every cached thumbnail after a style change.
    nonisolated static let renderVersion = 5
    nonisolated static let memoryLimit = 40

    private(set) var images: [String: UIImage] = [:]
    /// The last image per tile, shown while its new state renders (a
    /// strength change re-renders the overlay tiles; no placeholder flash).
    private var latest: [ThumbnailSubject: UIImage] = [:]

    @ObservationIgnored private var recency: [String] = []
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var requests: [String: Request] = [:]
    @ObservationIgnored private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// Renders that needed the network while offline: retried when it returns.
    @ObservationIgnored private var deferred: [String: Request] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var running: RenderJob?
    @ObservationIgnored private var identity: (data: DataLocation, text: String)?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var connectivity: Connectivity.Subscription?
    @ObservationIgnored private var memoryWarning: (any NSObjectProtocol)?
    #if DEBUG
    @ObservationIgnored private var dumpedExtras = false
    #endif
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Thumbnails")

    /// The snapshot being rendered. `MLNMapSnapshotter.cancel()` never
    /// calls the completion handler (MapLibre Native 7.0.0 just resets the
    /// core snapshotter), so the job holds the continuation's resume: the
    /// completion and a withdrawal both go through `complete`, which resumes
    /// exactly once — a cancelled render no longer leaks its continuation and
    /// stalls the worker for good.
    private final class RenderJob {
        let key: String
        let snapshotter: MLNMapSnapshotter
        private var finish: ((UIImage?) -> Void)?
        /// Withdrawn while rendering (the worker re-queues the key if a new
        /// waiter arrived meanwhile).
        private(set) var cancelled = false

        init(key: String, snapshotter: MLNMapSnapshotter) {
            self.key = key
            self.snapshotter = snapshotter
        }

        func onFinish(_ body: @escaping (UIImage?) -> Void) { finish = body }

        func complete(_ image: UIImage?) {
            guard let body = finish else { return }
            finish = nil
            body(image)
        }

        func cancel() {
            cancelled = true
            snapshotter.cancel()
            complete(nil)
        }
    }

    private struct Request {
        let subject: ThumbnailSubject
        let state: LayerState
        let data: DataLocation
        let tables: MapTables
        let scale: CGFloat
        /// Live LIST sources in the style (the tile's own pack is missing).
        let streams: Bool
        let file: URL
        /// Tests: render this style instead of the layer state's.
        var styleJSON: String?
        /// Tests: never written to disk.
        var transient = false
    }

    init() {
        directory = URL.cachesDirectory.appending(path: "LayerThumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        connectivity = Connectivity.shared.observe { [weak self] online in
            if online { self?.retryDeferred() }
        }
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeMemory() }
        }
    }

    /// Milestone 5 hook: packs were installed or removed. Disk entries carry
    /// the packs' identity in their key, so only memory needs clearing.
    func packsChanged() {
        images.removeAll()
        latest.removeAll()
        recency.removeAll()
        identity = nil
    }

    /// The image for a tile, nil while rendering or when there is nothing
    /// honest to show (placeholder). Cheap: called from view bodies.
    func image(_ subject: ThumbnailSubject, state: LayerState, data: DataLocation, scale: CGFloat) -> UIImage? {
        images[key(subject, state: subject.state(from: state), data: data, scale: scale)] ?? latest[subject]
    }

    /// Ensures a tile's image is loaded or rendered (call from `.task`; a
    /// cancelled task withdraws its request).
    func load(_ subject: ThumbnailSubject, current: LayerState, data: DataLocation, tables: MapTables, scale: CGFloat) async {
        #if DEBUG
        // dump mode also renders the tiles below the fold
        if UserDefaults.standard.string(forKey: "dumpThumbnails") != nil, !dumpedExtras {
            dumpedExtras = true
            for extra in [ThumbnailSubject.relief, .trees] {
                Task { await load(extra, current: current, data: data, tables: tables, scale: scale) }
            }
        }
        #endif
        let state = subject.state(from: current)
        let key = key(subject, state: state, data: data, scale: scale)
        guard images[key] == nil else { return touch(key) }
        let missing = subject.requiredArchive.map { data.url(for: $0) == nil } ?? false
        let streams = missing && Self.streamsAtThumbnailZoom(state, data: data, camera: subject.camera)
        let request = Request(subject: subject, state: state, data: data, tables: tables, scale: scale,
                              streams: streams, file: directory.appending(path: Self.hash(key) + ".png"))
        if missing {
            // nothing local to draw: live tiles while online (a base), else
            // the placeholder — an overlay or relief has no live source
            guard streams else { return }
            guard Connectivity.shared.online else {
                deferred[key] = request
                return
            }
        } else if let cached = await Self.read(request.file, scale: scale) {
            store(cached, key: key, subject: subject)
            return
        }
        guard !Task.isCancelled, images[key] == nil else { return }
        await wait(for: key, request: request)
    }

    // MARK: Queue

    private func wait(for key: String, request: Request) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if requests[key] == nil {
                    requests[key] = request
                    queue.append(key)
                }
                waiters[key, default: [:]][id] = continuation
                startWorker()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(key, waiter: id) }
        }
    }

    /// A tile no longer wants `key`: resume it; drop the work if nobody else does.
    private func withdraw(_ key: String, waiter: UUID) {
        waiters[key]?.removeValue(forKey: waiter)?.resume()
        guard waiters[key]?.isEmpty ?? true else { return }
        waiters[key] = nil
        if let job = running, job.key == key {
            job.cancel()
        } else if deferred[key] == nil {
            requests[key] = nil
            queue.removeAll { $0 == key }
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let key = self.nextKey() {
                guard let request = self.requests[key] else { continue }
                let (image, cancelled) = await self.render(request, key: key)
                if image == nil, cancelled, !(self.waiters[key]?.isEmpty ?? true) {
                    // withdrawn mid-render, then asked for again before the
                    // cancel landed: render it afresh (the request stays)
                    self.queue.insert(key, at: 0)
                    continue
                }
                self.requests[key] = nil
                if let image {
                    self.store(image, key: key, subject: request.subject)
                    if !request.streams, !request.transient { await Self.write(image, to: request.file) }
                }
                for continuation in (self.waiters.removeValue(forKey: key) ?? [:]).values { continuation.resume() }
            }
            self?.worker = nil
        }
    }

    /// The next key someone still waits for (or a network retry).
    private func nextKey() -> String? {
        while !queue.isEmpty {
            let key = queue.removeFirst()
            if !(waiters[key]?.isEmpty ?? true) { return key }
            if let retry = deferred.removeValue(forKey: key) {
                requests[key] = retry
                return key
            }
            requests[key] = nil
        }
        return nil
    }

    /// The network is back: render the tiles that waited for it (their
    /// views observe `images`, so they update without asking again).
    private func retryDeferred() {
        guard !deferred.isEmpty else { return }
        for key in deferred.keys where images[key] == nil && !queue.contains(key) {
            queue.append(key)
        }
        startWorker()
    }

    private func store(_ image: UIImage, key: String, subject: ThumbnailSubject) {
        #if DEBUG
        // `-dumpThumbnails <dir>`: every rendered tile as a PNG (framing review)
        if let dir = UserDefaults.standard.string(forKey: "dumpThumbnails") {
            try? image.pngData()?.write(to: URL(filePath: dir).appending(path: "\(subject).png"))
        }
        #endif
        images[key] = image
        latest[subject] = image
        touch(key)
        while recency.count > Self.memoryLimit {
            images[recency.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func purgeMemory() {
        images.removeAll()
        recency.removeAll()
    }

    // MARK: Rendering

    /// The image (nil on failure or cancel) and whether it was withdrawn.
    private func render(_ r: Request, key: String) async -> (UIImage?, cancelled: Bool) {
        // packs only, unless the tile's own pack is missing (then live, and
        // only while online — checked when the request was made)
        let json = r.styleJSON ?? StyleBuilder.json(state: r.state, data: r.data, tables: r.tables, online: r.streams)
        let styleFile = directory.appending(path: "style-\(Self.hash(json)).json")
        do { try Data(json.utf8).write(to: styleFile) } catch { return (nil, false) }
        defer { try? FileManager.default.removeItem(at: styleFile) }

        let camera = r.subject.camera
        let options = MLNMapSnapshotOptions(
            styleURL: styleFile,
            camera: MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
                                 altitude: 0, pitch: 0, heading: 0),
            size: Self.size)
        options.zoomLevel = camera.zoom
        options.scale = r.scale
        options.showsLogo = false
        options.showsAttribution = false
        let snapshotter = MLNMapSnapshotter(options: options)
        let job = RenderJob(key: key, snapshotter: snapshotter)
        running = job
        defer { running = nil }
        // The completion handler is imported @Sendable (MapLibre's headers
        // carry no concurrency annotations, and Swift treats an ObjC
        // completion block as Sendable): it captures only Sendable values —
        // the main-actor job, a Logger, a String. `start` calls it on the
        // main queue (MLNMapSnapshotter.mm), hence `assumeIsolated`. The
        // snapshotter stays alive through the job.
        let subject = String(describing: r.subject)
        let logger = Self.logger
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            job.onFinish { continuation.resume(returning: $0) }
            snapshotter.start { snapshot, error in
                if let error {
                    logger.debug("thumbnail \(subject, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                let image = snapshot?.image
                MainActor.assumeIsolated { job.complete(image) }
            }
        }
        return (image, job.cancelled)
    }

    #if DEBUG
    /// Tests: the key being rendered now.
    var renderingKey: String? { running?.key }
    /// Tests: whether `key` has an image in memory.
    func hasImage(_ key: String) -> Bool { images[key] != nil }

    /// Tests: render `styleJSON` at the default place through the queue
    /// under `key` (memory only), as a tile's `.task` would.
    func loadForTesting(key: String, styleJSON: String) async {
        guard images[key] == nil else { return }
        let request = Request(subject: .trees, state: .default, data: .none, tables: .empty, scale: 1,
                              streams: false, file: directory.appending(path: "test-\(Self.hash(key)).png"),
                              styleJSON: styleJSON, transient: true)
        await wait(for: key, request: request)
    }
    #endif

    /// Whether the tile's style streams a live LIST source at the zoom the
    /// snapshot draws its raster tiles at: 256 px tiles at map zoom z come
    /// from tile zoom round(z + 1) (MapLibre's covering zoom for 256 px
    /// tiles in its 512 px world), i.e. ceil(z + 0.5).
    nonisolated static func streamsAtThumbnailZoom(
        _ state: LayerState, data: DataLocation, camera: (latitude: Double, longitude: Double, zoom: Double)
    ) -> Bool {
        let tileZoom = coveringZoom(camera.zoom)
        let style = StyleBuilder.style(state: state, data: data, tables: .empty, online: true)
        let sources = style["sources"] as? [String: Any] ?? [:]
        return sources.values.contains { value in
            guard let source = value as? [String: Any], source["tiles"] != nil else { return false }
            let lo = source["minzoom"] as? Int ?? 0, hi = source["maxzoom"] as? Int ?? 22
            return (lo ... hi).contains(tileZoom)
        }
    }

    /// The tile zoom MapLibre draws 256 px raster tiles from at map zoom z.
    nonisolated static func coveringZoom(_ z: Double) -> Int { Int((z + 0.5).rounded(.up)) }

    // MARK: Keys and files

    /// subject + state + every local pack's identity + app build and bundled
    /// tables + size + scale. A plain string (hashed only for file names);
    /// the file-system part is computed once per data location.
    func key(_ subject: ThumbnailSubject, state: LayerState, data: DataLocation, scale: CGFloat) -> String {
        if identity?.data != data { identity = (data, Self.packIdentity(data) + "|" + Self.buildIdentity) }
        let s = state
        return "v\(Self.renderVersion)|\(subject)|\(s.base.rawValue),\(s.seasonYear ?? 0),\(s.overlay.rawValue),"
            + "\(s.strength.rawValue),\(s.relief),\(s.trees)|\(subject.camera)|\(identity!.text)|"
            + "\(Int(Self.size.width))x\(Int(Self.size.height))@\(Int(scale))"
    }

    /// Size and modification date of every local pack.
    nonisolated static func packIdentity(_ data: DataLocation) -> String {
        Archive.allCases.compactMap { archive -> String? in
            guard let url = data.url(for: archive) else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(archive.rawValue)=\(size)@\(Int(date))"
        }.joined(separator: ",")
    }

    /// The app version and build, the executable's date (every build, also
    /// in development where the build number stays put) and the bundled
    /// tables the style reads — colours, units, trees.
    nonisolated static let buildIdentity: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        var parts = ["\(info["CFBundleShortVersionString"] ?? "")-\(info["CFBundleVersion"] ?? "")"]
        var files = [Bundle.main.executableURL].compactMap { $0 }
        if let data = Bundle.main.url(forResource: "Data", withExtension: nil) {
            files += ["tasveg_communities.json", "geology_units.json", "pre1750_units.json", "trees.json"]
                .map { data.appending(path: $0) }
        }
        for file in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(file.lastPathComponent)=\(size)@\(Int(date))")
        }
        return parts.joined(separator: ",")
    }()

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent nonisolated private static func read(_ file: URL, scale: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data, scale: scale)
    }

    @concurrent nonisolated private static func write(_ image: UIImage, to file: URL) async {
        try? image.pngData()?.write(to: file, options: .atomic)
    }
}
