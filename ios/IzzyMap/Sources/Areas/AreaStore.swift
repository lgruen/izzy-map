import Foundation
import IzzyKit
import Observation
import os

/// The detailed areas on this device: the registry (`areas.json` in
/// Application Support/Areas, excluded from backup — the tiles can be
/// fetched again, and NC-ND tiles have no business in iCloud), one folder
/// per area holding one PMTiles archive per finished layer (plus a running
/// layer's work files), and the one download queue.
///
/// Downloads run one area at a time, one layer at a time, in the order she
/// asked for them; a `BGContinuedProcessingTask` carries the queue on in the
/// background with the system's progress UI. Pause and Delete stop a
/// running download and wait for it (a writer holds the files open).
///
/// The queue is a list of entries with tokens: the running entry belongs to
/// the job that runs it, and only that job removes it — a Resume tapped
/// while a stopped job is still winding down queues a NEW entry, which the
/// old job's ending can't take with it.
@MainActor
@Observable
final class AreaStore {
    /// The app's store (Application Support). Tests make their own.
    static let shared = AreaStore.launch()

    /// nil: memory only (unit-test hosts, previews).
    let directory: URL?
    private(set) var areas: [AreaRecord] = []
    /// The layer downloading now, live.
    private(set) var running: (areaID: String, progress: AreaLayerProgress)?
    /// Areas waiting their turn (the running one first, unless it is being stopped).
    private(set) var queue: [QueueEntry] = []
    /// The registry couldn't be read (shown in Storage; nothing is overwritten).
    private(set) var loadError: String?
    /// Bytes in the areas folder that no readable registry accounts for
    /// (counted in the Storage gauge until removed).
    private(set) var orphanBytes: Int64 = 0
    /// Measured tile sizes per layer kind: the estimates' ranges.
    private(set) var calibration: [String: AreaCalibration] = [:]

    nonisolated struct QueueEntry: Equatable, Sendable {
        let id: String
        let token: Int
    }

    @ObservationIgnored var transport: any AreaTransport
    @ObservationIgnored var backoff: Duration = .milliseconds(500)
    /// Tiles per layer (tests lower it).
    @ObservationIgnored var cap = AreaPlan.maxTilesPerLayer
    /// The job running the queue's first entry.
    @ObservationIgnored private var current: (entry: QueueEntry, task: Task<Void, Never>)?
    @ObservationIgnored private var tokens = 0
    @ObservationIgnored private let background = AreaBackgroundTask()
    @ObservationIgnored private var lastSave = ContinuousClock.now
    /// This run of the queue (one system task): which areas, whether
    /// everything asked for arrived, how far the system's bar got.
    @ObservationIgnored private(set) var run = RunTally()
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Areas")

    nonisolated struct RunTally: Equatable, Sendable {
        var areaIDs: [String] = []
        /// A layer stopped short for any reason but Pause / Delete.
        var failed = false
        /// The system bar's fraction: only ever grows, < 1 until the end.
        var fraction = 0.0
    }

    /// False in unit tests: no system task.
    @ObservationIgnored private let usesBackgroundTask: Bool

    init(directory: URL?, transport: any AreaTransport = LiveAreaTransport.shared, backgroundTask: Bool = true) {
        self.directory = directory
        self.transport = transport
        usesBackgroundTask = backgroundTask
        background.onExpire = { [weak self] in self?.stopAll(note: "iOS stopped the download — tap Resume to carry on") }
        load()
    }

    private static func launch() -> AreaStore {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return AreaStore(directory: nil) }
        var dir = support.appending(path: "Areas", directoryHint: .isDirectory)
        #if DEBUG
        // UI tests: start with no areas
        if UserDefaults.standard.bool(forKey: "resetAreas") { try? fm.removeItem(at: dir) }
        #endif
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        #if DEBUG
        if FakeAreaTransport.isOn { return AreaStore(directory: dir, transport: FakeAreaTransport.fromLaunchArguments()) }
        #endif
        return AreaStore(directory: dir)
    }

    var registryURL: URL? { directory?.appending(path: "areas.json") }

    /// An area's folder (a memory-only store keeps its files in the temporary directory).
    func folder(_ id: String) -> URL {
        (directory ?? FileManager.default.temporaryDirectory.appending(path: "IzzyMapAreas"))
            .appending(path: id, directoryHint: .isDirectory)
    }

    private func load() {
        guard let registryURL else { return }
        do {
            let registry = try AreaRegistry.load(from: registryURL)
            areas = registry.areas
            calibration = registry.calibration ?? [:]
            loadError = nil
            orphanBytes = 0
            sweep()
            refreshSources()
        } catch {
            loadError = "The list of detailed areas couldn't be read."
            orphanBytes = directory.map { Self.size(of: $0) } ?? 0
            Self.logger.fault("areas.json unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    /// At launch (nothing runs yet): folders no area owns, and files no
    /// layer of their area owns — an area deleted while the app was killed,
    /// a finished layer's leftover work files, a half-written archive.
    private func sweep() {
        guard let directory else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let byID = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0) })
        var swept = 0
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let area = byID[entry.lastPathComponent] else {
                try? fm.removeItem(at: entry)
                swept += 1
                continue
            }
            var keep: Set<String> = []
            for r in area.layers {
                if r.complete {
                    if r.stored > 0 { keep.insert(r.archiveName) }
                } else {
                    // a running layer's files, minus a half-written archive
                    keep.formUnion(AreaLayerRecord.fileNames(r.layer).filter { !$0.hasSuffix(".partial") })
                }
            }
            for name in (try? fm.contentsOfDirectory(atPath: entry.path(percentEncoded: false))) ?? [] where !keep.contains(name) {
                try? fm.removeItem(at: entry.appending(path: name))
                swept += 1
            }
        }
        if swept > 0 { Self.logger.notice("areas: swept \(swept) orphaned files or folders") }
    }

    /// Bytes under a folder (on-disk sizes).
    nonisolated static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// "Remove all detailed areas" when the registry can't be read: every
    /// file goes, and a new empty registry starts.
    func removeEverything() async {
        for entry in queue { await pause(entry.id) }
        if let current { current.task.cancel(); await current.task.value }
        guard let directory else { return }
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        areas = []
        loadError = nil
        orphanBytes = 0
        save()
    }

    private func save() {
        refreshSources()
        lastSave = .now
        guard let registryURL, loadError == nil else { return }
        do {
            try AreaRegistry(areas: areas, calibration: calibration.isEmpty ? nil : calibration).save(to: registryURL)
        } catch {
            Self.logger.error("areas.json not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func area(_ id: String) -> AreaRecord? { areas.first { $0.id == id } }

    var defaultName: String { AreaRegistry(areas: areas).defaultName() }

    /// Bytes of every area on the device (and of files nothing accounts for).
    var bytes: Int64 { areas.reduce(0) { $0 + $1.bytes } + orphanBytes }

    // MARK: Style

    /// Every finished layer with an archive, oldest area first (a newer
    /// area paints over an older one where they overlap). Its own stored
    /// property, set only when it changes: the map's style reads it, and
    /// progress (which rewrites `areas` four times a second) must not
    /// rebuild the style.
    private(set) var styleSources: [AreaStyleSource] = []

    private func refreshSources() {
        let now = finishedSources
        if now != styleSources { styleSources = now }
    }

    private var finishedSources: [AreaStyleSource] {
        areas.sorted { $0.created < $1.created }.flatMap { area -> [AreaStyleSource] in
            let folder = self.folder(area.id)
            return area.layers.filter { $0.complete && $0.stored > 0 }.map {
                AreaStyleSource(areaID: area.id, layer: $0.layer, url: folder.appending(path: $0.archiveName), box: area.box,
                                maxZoom: $0.maxZoom(detail: area.detail))
            }
        }
    }

    /// The frame of an area source (the credits sheet lists it only when it's in view).
    func box(ofSource id: String) -> AreaBox? {
        styleSources.first { $0.id == id }?.box
    }

    // MARK: Estimates

    /// The likely size range of a layer the nominal estimate puts at `bytes`.
    func range(_ layer: AreaLayer, nominal bytes: Int64) -> ClosedRange<Int64> {
        (calibration[layer.calibrationKey] ?? AreaCalibration()).range(nominal: bytes, nominalMean: layer.meanTileBytes)
    }

    // MARK: Downloads

    /// A new area, saved and queued.
    @discardableResult
    func add(name: String, box: AreaBox, detail: AreaDetail, layers: [AreaLayer]) -> AreaRecord {
        let cleaned = AreaRecord.cleanName(name)
        let record = AreaRecord(name: cleaned.isEmpty ? defaultName : cleaned, box: box, detail: detail, layers: layers)
        areas.append(record)
        save()
        start(record.id)
        return record
    }

    func isQueued(_ id: String) -> Bool { queue.contains { $0.id == id } }
    /// Its job is running (and it hasn't been stopped).
    func isRunning(_ id: String) -> Bool {
        guard let current, current.entry.id == id else { return false }
        return queue.first == current.entry
    }

    /// Queues an incomplete area (Download, Resume).
    func start(_ id: String) {
        guard let area = area(id), !area.isComplete, !isQueued(id) else { return }
        if current == nil, queue.isEmpty { run = RunTally() }
        if !run.areaIDs.contains(id) { run.areaIDs.append(id) }
        tokens += 1
        queue.append(QueueEntry(id: id, token: tokens))
        if current == nil { runQueue() }
    }

    /// Stops one area's download (it stays, incomplete) and waits for its
    /// job to let go of the files.
    func pause(_ id: String) async {
        queue.removeAll { $0.id == id }
        run.areaIDs.removeAll { $0 == id }
        if let current, current.entry.id == id {
            current.task.cancel()
            await current.task.value
        }
    }

    /// Stops every download (the background task expired).
    func stopAll(note: String) {
        let ids = queue.map(\.id)
        queue.removeAll()
        current?.task.cancel()
        run.failed = true
        for id in ids {
            guard let i = areas.firstIndex(where: { $0.id == id }) else { continue }
            for j in areas[i].layers.indices where !areas[i].layers[j].complete { areas[i].layers[j].stopped = note }
        }
        save()
    }

    /// Delete: stop its download and wait (even one already stopping),
    /// then remove it from the map and the registry, then its files.
    func delete(_ id: String) async {
        await pause(id)
        areas.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: folder(id))
    }

    private func runQueue() {
        guard current == nil else { return }
        guard let entry = queue.first else {
            // the system's banner says whether everything asked for arrived
            background.end(success: !run.failed)
            running = nil
            return
        }
        guard let area = area(entry.id) else {
            queue.removeFirst()
            runQueue()
            return
        }
        if usesBackgroundTask { background.begin(title: "Downloading \(area.name)", subtitle: "Detailed area") }
        let task = Task { [weak self] in
            await self?.download(entry)
            guard let self else { return }
            // only this job's own entry goes (a Resume meanwhile queued a new one)
            if self.current?.entry == entry { self.current = nil }
            if self.running?.areaID == entry.id { self.running = nil }
            self.queue.removeAll { $0 == entry }
            self.runQueue()
        }
        current = (entry, task)
    }

    /// One area, layer by layer. A stop for want of a connection (or room)
    /// ends the queue too — each dropped area says why; a tile-specific
    /// stop or a capped layer lets the rest carry on.
    private func download(_ entry: QueueEntry) async {
        let id = entry.id
        let folder = self.folder(id)
        // a fresh run: the last one's notes go
        if let i = areas.firstIndex(where: { $0.id == id }) {
            for j in areas[i].layers.indices where !areas[i].layers[j].complete { areas[i].layers[j].stopped = nil }
        }
        let layers = area(id)?.layers.filter { !$0.complete }.map(\.layer) ?? []
        for layer in layers {
            guard !Task.isCancelled, let area = area(id) else { return }
            let job = AreaLayerDownload(area: area, layer: layer, folder: folder, transport: transport, backoff: backoff, cap: cap)
            running = (id, AreaLayerProgress(layer: layer, done: area[layer]?.done ?? 0, planned: area[layer]?.planned ?? 0,
                                              stored: area[layer]?.stored ?? 0, bytes: area[layer]?.bytes ?? 0))
            let token = entry.token
            let (record, stop) = await job.run { [weak self] p in
                Task { @MainActor in self?.progressed(id, token: token, p) }
            }
            guard let i = areas.firstIndex(where: { $0.id == id }) else { return }   // deleted meanwhile
            var r = record
            r.stopped = stop.map { $0 == .cancelled ? (areas[i][layer]?.stopped ?? "Paused") : $0.note }
            let wasComplete = areas[i][layer]?.complete ?? false
            areas[i][layer] = r
            if r.complete, !wasComplete, r.stored > 0 {
                calibration[layer.calibrationKey, default: AreaCalibration()].add(tiles: r.stored, bytes: r.bytes)
            }
            save()
            progressed(id, token: token, AreaLayerProgress(layer: layer, done: r.done, planned: r.planned, stored: r.stored, bytes: r.bytes))
            guard let stop else { continue }
            Self.logger.notice("area \(id, privacy: .public) \(layer.rawValue, privacy: .public) stopped: \(stop.note, privacy: .public)")
            if stop == .cancelled { return }
            run.failed = true
            if stop.endsQueue {
                // the rest of the queue would stop the same way: each says why
                let rest = queue.filter { $0 != entry }
                queue.removeAll { rest.contains($0) }
                for other in rest {
                    guard let k = areas.firstIndex(where: { $0.id == other.id }) else { continue }
                    for j in areas[k].layers.indices where !areas[k].layers[j].complete {
                        areas[k].layers[j].stopped = stop.queuedNote
                    }
                }
                save()
                return
            }
        }
    }

    private func progressed(_ id: String, token: Int, _ p: AreaLayerProgress) {
        // a report from a job that has ended (they hop here in tasks of their own)
        guard let current, current.entry.token == token, let now = running, now.areaID == id else { return }
        // never step back
        if now.progress.layer == p.layer, p.saving == nil, now.progress.saving == nil,
           p.done < now.progress.done, p.planned == now.progress.planned { return }
        running = (id, p)
        guard let i = areas.firstIndex(where: { $0.id == id }) else { return }
        var r = areas[i][p.layer] ?? AreaLayerRecord(layer: p.layer)
        if !r.complete {
            r.done = p.done
            r.planned = p.planned
            r.stored = p.stored
            r.bytes = p.bytes
            areas[i][p.layer] = r
        }
        if lastSave.duration(to: .now) > .seconds(10) { save() }
        let area = areas[i]
        run.fraction = max(run.fraction, runFraction())
        let units = 10_000
        background.update(done: Int(run.fraction * Double(units)), total: units,
                          title: "Downloading \(area.name)",
                          subtitle: p.saving != nil ? "Saving \(p.layer.title.lowercased())…"
                              : "\(p.layer.title) · \(StorageText.size(Int(area.bytes)))")
    }

    /// Requests and their share of the run, over every layer of every area
    /// in it, planned up front (a layer not yet planned counts its
    /// estimate): the system's bar never runs back and never shows 100 %
    /// between layers. Writing a layer's archive counts as a twentieth more.
    func runFraction() -> Double {
        var total = 0.0, done = 0.0
        for id in run.areaIDs {
            guard let area = area(id) else { continue }
            for r in area.layers {
                let tiles = Double(r.planned > 0 ? max(r.planned, r.done)
                    : max(r.done, AreaPlan.estimate(area.box, layer: r.layer, detail: area.detail).tiles))
                let saving = max(1, tiles / 20)
                total += tiles + saving
                if r.complete {
                    done += tiles + saving
                } else {
                    done += Double(r.done)
                    if let p = running, p.areaID == id, p.progress.layer == r.layer, let f = p.progress.saving {
                        done += saving * f
                    }
                }
            }
        }
        guard total > 0 else { return 0 }
        return min(0.995, done / total)
    }

    // MARK: Status

    /// What an area's row says.
    nonisolated enum Status: Equatable, Sendable {
        case downloading(Double)
        case waiting
        case complete
        /// Stopped short: why, if known.
        case incomplete(String?)
    }

    func status(_ id: String) -> Status {
        guard let area = area(id) else { return .incomplete(nil) }
        if area.isComplete { return .complete }
        if isRunning(id) {
            let planned = max(area.planned, 1)
            return .downloading(min(1, Double(area.done) / Double(planned)))
        }
        if isQueued(id) { return .waiting }
        return .incomplete(area.layers.compactMap(\.stopped).first)
    }

    /// Free space a Resume needs (nil: it fits, or the free space is
    /// unknown): what is LEFT of each layer — the answers so far stand for
    /// the rest, so known absents and sea aren't counted again — plus the
    /// largest layer's whole archive written beside its work file.
    func shortfall(for area: AreaRecord, free: Int64? = VolumeSpace.current().free) -> Int64? {
        let remaining = area.layers.filter { !$0.complete }.map { r in
            AreaPlan.remaining(estimate: AreaPlan.estimate(area.box, layer: r.layer, detail: area.detail),
                               planned: r.planned, done: r.done, stored: r.stored, bytes: r.bytes,
                               meanTileBytes: calibration[r.layer.calibrationKey]?.meanTileBytes)
        }
        let need = AreaPlan.spaceNeeded(remaining: remaining)
        guard let free else { return nil }
        return free < need ? need : nil
    }
}
