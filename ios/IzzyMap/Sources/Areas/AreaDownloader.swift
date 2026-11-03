import Foundation
import IzzyKit
import os

/// Where one layer's download stands, for the row and the system progress.
nonisolated struct AreaLayerProgress: Sendable, Equatable {
    var layer: AreaLayer
    /// Tiles answered (stored + absent) and planned.
    var done: Int
    var planned: Int
    var stored: Int
    var bytes: Int64
    /// Writing the archive at the end: 0…1 (nil while tiles arrive).
    var saving: Double?
}

/// Why a layer stopped short. Everything is resumable: the tiles that
/// arrived stay in the layer's work file and journal.
nonisolated enum AreaStop: Error, Sendable, Equatable {
    /// Cancel, Delete, or the system ending the background task.
    case cancelled
    /// No network path (after ~30 s of tries).
    case offline
    /// A tile kept failing for ~30 s, or tile after tile answered with
    /// something that isn't an image (a Wi-Fi login page).
    case failed(String)
    /// The rest arrived, but `n` tiles kept answering with something that
    /// isn't a map tile: Resume tries them again (after three runs they
    /// count as absent). Tile-specific: the queue carries on.
    case skipped(Int)
    /// Even z13–15 are more than `AreaPlan.maxTilesPerLayer` (never from a
    /// framed box; a deeper level over the cap is kept to what fits instead).
    case tooLarge(Int)
    /// Writing to the device failed (full disk, …).
    case storage(String)

    /// The row's note.
    var note: String {
        switch self {
        case .cancelled: "Paused"
        case .offline: "No connection — tap Resume when there's reception"
        case let .failed(why): "Connection lost (\(why)) — tap Resume to carry on"
        case let .skipped(n): "\(n == 1 ? "1 tile" : "\(n.formatted()) tiles") didn't come — tap Resume to try again"
        case let .tooLarge(n): "Too large for one download (\(n.formatted()) tiles) — pick less detail"
        case let .storage(why): "Couldn't save the area (\(why))"
        }
    }

    /// The rest of the queue would stop the same way (no connection for this
    /// area is none for the next): it is dropped, each with `queuedNote`.
    var endsQueue: Bool {
        switch self {
        case .offline, .failed, .storage: true
        case .cancelled, .skipped, .tooLarge: false
        }
    }

    /// The note of an area that was waiting when the one before it stopped.
    var queuedNote: String {
        switch self {
        case .offline: "Didn't start: no connection — tap Resume when there's reception"
        case .failed: "Didn't start: the connection was lost — tap Resume to carry on"
        case .storage: "Didn't start: the area before it couldn't be saved — tap Resume"
        default: "Didn't start — tap Resume"
        }
    }
}

/// Tiles that answered with something that isn't a map tile, per run they
/// did (`<layer>.strikes`, JSON {tile id: runs}): after
/// `AreaPlan.strikesToGiveUp` runs a tile counts as absent, so one odd tile
/// can't stall Resume for ever.
nonisolated struct TileStrikes {
    let url: URL
    private(set) var counts: [UInt64: Int]

    init(url: URL) {
        self.url = url
        let raw = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        counts = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UInt64(k).map { ($0, v) } })
    }

    func count(_ tile: TileID) -> Int { counts[PMTiles.tileID(z: tile.z, x: tile.x, y: tile.y)] ?? 0 }

    /// One more run held against each; the tiles that reached the limit.
    mutating func strike(_ tiles: [TileID]) -> [TileID] {
        var out: [TileID] = []
        for t in tiles {
            let id = PMTiles.tileID(z: t.z, x: t.x, y: t.y)
            counts[id, default: 0] += 1
            if counts[id]! >= AreaPlan.strikesToGiveUp {
                counts[id] = nil
                out.append(t)
            }
        }
        return out
    }

    func save() {
        if counts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let raw = Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) })
        try? JSONEncoder().encode(raw).write(to: url, options: .atomic)
    }
}

/// Downloads ONE layer of an area into `<folder>/<layer>.pmtiles`:
/// - candidates level by level, shallowest first (AreaPlan): a season's
///   deeper levels only under the z15 tiles that came back with photos in
///   this very download (z13–15 are part of the area anyway, and LIST's
///   live answer is fresher than the installed pack — the incomplete
///   2025–26 season's newly flown places included). A z15 tile that can't
///   be had stops the layer before any of its children are planned —
///   unreachable coverage is never read as "not flown";
/// - over the per-layer cap, the deepest level that fits is kept instead
///   (`cappedAt`, said in the row) and the queue carries on;
/// - `AreaPlan.concurrency` requests in flight; a failing tile is tried
///   again with exponential backoff for ~30 s before the layer stops; 404,
///   LIST's 200-with-an-ArcGIS-404-body and its fully transparent "no
///   imagery" PNGs are absent (`<layer>.absent`); a tile that keeps
///   answering with something that isn't a JPEG or PNG is skipped for the
///   run (`TileStrikes`), never stored;
/// - tiles go into a `PMTilesWriter` (verbatim bytes, journalled after an
///   fsync): a killed or stopped download resumes where it was;
/// - the last tile in, the writer writes the archive with the layer's name
///   and attribution and renames it into place atomically (progress keeps
///   coming while it writes). An archive found at the start with no work
///   files beside it was finished before the registry heard of it: complete.
///
/// Runs off the main actor; the writer never leaves this task.
nonisolated struct AreaLayerDownload: Sendable {
    let area: AreaRecord
    let layer: AreaLayer
    let folder: URL
    let transport: any AreaTransport
    /// The first wait between tries of one tile (then ×2… — AreaPlan.retryFactors).
    var backoff: Duration = .milliseconds(500)
    /// How often progress is reported.
    var reportEvery: Duration = .milliseconds(250)
    /// Tiles per layer (tests lower it).
    var cap = AreaPlan.maxTilesPerLayer

    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Areas")

    var archiveURL: URL { folder.appending(path: "\(layer.rawValue).pmtiles") }
    var absentURL: URL { folder.appending(path: "\(layer.rawValue).absent") }
    var strikesURL: URL { folder.appending(path: "\(layer.rawValue).strikes") }

    /// One tile's answer after its tries.
    enum Outcome: Sendable {
        case image(Data)
        case absent
        /// Kept answering with something that isn't a map tile.
        case bad
        case stop(AreaStop)
    }

    /// The layer's record once done (complete), or why it stopped and where
    /// it got to.
    @concurrent func run(progress: @escaping @Sendable (AreaLayerProgress) -> Void) async -> (AreaLayerRecord, AreaStop?) {
        var record = area[layer] ?? AreaLayerRecord(layer: layer)
        let fm = FileManager.default
        if record.complete, fm.fileExists(atPath: archiveURL.path(percentEncoded: false)) || record.stored == 0 {
            return (record, nil)
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return (record, .storage(error.localizedDescription))
        }
        // finished, but killed before the registry was saved: the archive
        // is only ever renamed into place whole
        if let reader = try? PMTilesReader(url: archiveURL) {
            for name in AreaLayerRecord.fileNames(layer) where name != record.archiveName {
                try? fm.removeItem(at: folder.appending(path: name))
            }
            record.complete = true
            record.stored = Int(reader.header.addressedTiles)
            record.done = max(record.done, record.planned, record.stored)
            record.planned = record.done
            if reader.maxZoom < AreaPlan.zooms(layer, detail: area.detail).upperBound, record.cappedAt == nil, !layer.isSeason {
                record.cappedAt = reader.maxZoom
            }
            record.bytes = Int64((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            record.stopped = nil
            progress(progressOf(record))
            return (record, nil)
        }
        let writer: PMTilesWriter
        let absent: TileIDLog
        do {
            writer = try PMTilesWriter(destination: archiveURL, tileType: layer.tileType, resume: true)
            absent = try TileIDLog(url: absentURL)
        } catch {
            return (record, .storage(String(describing: error)))
        }
        defer { absent.close() }
        if writer.droppedOnResume > 0 {
            Self.logger.notice("area \(area.id, privacy: .public) \(layer.rawValue, privacy: .public): \(writer.droppedOnResume) journalled tiles failed their digest, fetched again")
        }
        var strikes = TileStrikes(url: strikesURL)
        /// Skipped this run (tile-specific bad answers).
        var skipped: [TileID] = []

        func have(_ t: TileID) -> Bool { writer.contains(z: t.z, x: t.x, y: t.y) || absent.contains(t) }
        func snapshot(saving: Double? = nil) -> AreaLayerProgress {
            AreaLayerProgress(layer: layer, done: writer.tileCount + absent.count, planned: record.planned,
                              stored: writer.tileCount, bytes: Int64(writer.storedBytes), saving: saving)
        }
        func update(_ p: AreaLayerProgress) {
            record.done = p.done
            record.stored = p.stored
            record.bytes = p.bytes
        }
        /// The tiles skipped this run get a strike each; those at the limit
        /// count as absent from now on. Returns how many are still owed.
        func settleSkipped() -> Int {
            guard !skipped.isEmpty else { return 0 }
            let gaveUp = strikes.strike(skipped)
            for t in gaveUp {
                try? absent.append(t)
                Self.logger.error("area \(area.id, privacy: .public) \(layer.rawValue, privacy: .public) \(t.description, privacy: .public): no map tile in \(AreaPlan.strikesToGiveUp) runs — counted as absent")
            }
            strikes.save()
            let left = skipped.count - gaveUp.count
            skipped = []
            return left
        }
        /// Ends the run short: what arrived is synced, strikes recorded.
        func stopped(_ stop: AreaStop, strike: Bool = true) -> (AreaLayerRecord, AreaStop?) {
            if strike { _ = settleSkipped() }
            try? writer.sync()
            update(snapshot())
            progress(snapshot())
            return (record, stop)
        }

        let requested = AreaPlan.zooms(layer, detail: area.detail)
        /// A season's deeper levels go only under z15 tiles with a photo.
        func isCandidate(_ tile: TileID) -> Bool {
            guard layer.isSeason, tile.z > AreaPlan.packMaxZoom else { return true }
            let p = AreaPlan.packParent(tile)
            return writer.contains(z: p.z, x: p.x, y: p.y)
        }
        /// Requests at one level: every tile, or (a season below z15, once
        /// its z15 answers are in) those under a stored z15 tile.
        func levelCount(_ z: Int) -> Int {
            if layer.isSeason, z > AreaPlan.packMaxZoom,
               AreaPlan.tiles(area.box, zoom: AreaPlan.packMaxZoom).allSatisfy(have) {
                return AreaPlan.tiles(area.box, zoom: z).count(where: isCandidate)
            }
            return AreaPlan.count(area.box, zoom: z)
        }
        func plannedCount(depth: Int) -> Int {
            (requested.lowerBound ... depth).reduce(0) { $0 + levelCount($1) }
        }

        // a season's plan is an upper bound until its z15 answers are in
        // (the cap is checked again then)
        var depth = requested.upperBound
        if !layer.isSeason || AreaPlan.tiles(area.box, zoom: AreaPlan.packMaxZoom).allSatisfy(have) {
            guard let fits = AreaPlan.depth(requested: requested.upperBound, cap: cap, count: levelCount) else {
                record.planned = plannedCount(depth: requested.upperBound)
                return (record, .tooLarge(record.planned))
            }
            depth = fits
        } else if AreaPlan.depth(requested: AreaPlan.packMaxZoom, cap: cap, count: levelCount) == nil {
            record.planned = plannedCount(depth: AreaPlan.packMaxZoom)
            return (record, .tooLarge(record.planned))
        }
        record.cappedAt = depth < requested.upperBound ? depth : nil
        record.planned = plannedCount(depth: depth)
        var last = ContinuousClock.now
        progress(snapshot())
        let delays = AreaPlan.retryDelays(base: backoff)

        for z in requested where z <= depth {
            // a season's z15 coverage is known now: the exact plan and the cap
            if layer.isSeason, z == AreaPlan.packMaxZoom + 1 {
                // a z15 tile that couldn't be had: its children can't be planned
                let owed = settleSkipped()
                if owed > 0 { return stopped(.skipped(owed), strike: false) }
                if let fits = AreaPlan.depth(requested: requested.upperBound, cap: cap, count: levelCount) {
                    depth = fits
                }
                record.cappedAt = depth < requested.upperBound ? depth : nil
                record.planned = plannedCount(depth: depth)
                if z > depth { break }
            }
            let level = AreaPlan.tiles(area.box, zoom: z).filter { !have($0) && isCandidate($0) }
            if level.isEmpty { continue }
            var badRun = 0
            let outcome: AreaStop? = await withTaskGroup(of: (TileID, Outcome).self) { group in
                var next = 0
                var failure: AreaStop?
                var portal: [TileID] = []
                func launch() {
                    let tile = level[next]
                    next += 1
                    group.addTask { [transport, layer] in
                        (tile, await Self.fetch(layer.tileURL(tile), transport: transport, delays: delays))
                    }
                }
                while next < min(AreaPlan.concurrency, level.count) { launch() }
                while let (tile, result) = await group.next() {
                    do {
                        switch result {
                        case let .image(data) where !(layer.isSeason && TileImage.isBlank(data)):
                            try writer.add(z: tile.z, x: tile.x, y: tile.y, data: data)
                            badRun = 0
                        case .image, .absent:
                            try absent.append(tile)
                            badRun = 0
                        case .bad:
                            badRun += 1
                            portal.append(tile)
                            if badRun >= AreaPlan.badRun {
                                // tile after tile: a login page, not odd tiles
                                failure = failure ?? .failed("not a map tile — a Wi-Fi login page?")
                            }
                        case let .stop(stop):
                            failure = failure ?? stop
                        }
                        // odd tiles (not a run of them) are skipped for this run
                        if badRun == 0, !portal.isEmpty {
                            skipped += portal
                            portal = []
                        }
                    } catch {
                        failure = failure ?? .storage(String(describing: error))
                    }
                    if failure != nil || Task.isCancelled {
                        group.cancelAll()
                        failure = failure ?? .cancelled
                        continue
                    }
                    if next < level.count { launch() }
                    if last.duration(to: .now) >= reportEvery {
                        last = .now
                        progress(snapshot())
                    }
                }
                // a short run of bad answers at the end of a level: odd tiles too
                if failure == nil { skipped += portal }
                return failure
            }
            if let outcome {
                // a run of login pages holds nothing against the tiles
                return stopped(outcome, strike: badRun < AreaPlan.badRun)
            }
        }
        let owed = settleSkipped()
        if owed > 0 { return stopped(.skipped(owed), strike: false) }

        // every candidate answered
        try? fm.removeItem(at: strikesURL)
        let final = snapshot()
        update(final)
        record.planned = max(record.planned, final.done)
        if writer.tileCount == 0 {
            // nothing here (a season not flown inside the frame): no archive
            writer.cancel()
            try? fm.removeItem(at: absentURL)
            record.complete = true
            record.bytes = 0
            progress(progressOf(record))
            return (record, nil)
        }
        do {
            let b = area.box
            let planned = record.planned, done = final.done, stored = final.stored, bytes = final.bytes
            try writer.finish(
                name: "IzzyMap detailed area: \(area.name) — \(layer.title)",
                attribution: layer.attributionText,
                metadata: [
                    "description": "Tiles from theLIST (\(layer.service)), fetched by this device for personal, non-commercial use and kept byte for byte.",
                    "format": layer.tileType == .png ? "png" : "jpg",
                ],
                bounds: b.bounds,
                center: (b.centre.longitude, b.centre.latitude, min(depth, layer.maxZoom)),
                progress: { f in
                    progress(AreaLayerProgress(layer: layer, done: done, planned: planned, stored: stored, bytes: bytes, saving: f))
                }
            )
        } catch {
            return (record, .storage(String(describing: error)))
        }
        try? fm.removeItem(at: absentURL)
        record.complete = true
        record.bytes = Int64((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int(record.bytes))
        progress(progressOf(record))
        Self.logger.notice("area \(area.id, privacy: .public) \(layer.rawValue, privacy: .public): \(record.stored) tiles, \(record.bytes) bytes, \(record.done - record.stored) absent\(record.cappedAt.map { ", capped at z\($0)" } ?? "", privacy: .public)")
        return (record, nil)
    }

    private func progressOf(_ r: AreaLayerRecord) -> AreaLayerProgress {
        AreaLayerProgress(layer: layer, done: r.done, planned: r.planned, stored: r.stored, bytes: r.bytes)
    }

    /// One tile with retries: its bytes, absent, kept-not-a-tile, or why it
    /// can't be had now. A failure (or no connection) is tried again after
    /// each of `delays` (~30 s in all); a body that isn't a map tile only
    /// `AreaPlan.badBodyAttempts` times.
    static func fetch(_ url: URL, transport: any AreaTransport, delays: [Duration]) async -> Outcome {
        var why = "no answer"
        var offline = false
        var badBodies = 0
        for attempt in 0 ... delays.count {
            if Task.isCancelled { return .stop(.cancelled) }
            switch await transport.fetch(url) {
            case let .body(data):
                if TileImage.isImage(data) { return .image(data) }
                if let code = TileImage.arcGISErrorCode(data) {
                    // LIST's 200 with an error body: a 404 inside is a miss
                    if code == 404 { return .absent }
                    why = "theLIST error \(code)"
                    offline = false
                } else {
                    badBodies += 1
                    if badBodies >= AreaPlan.badBodyAttempts { return .bad }
                }
            case .absent: return .absent
            case .offline:
                why = "no connection"
                offline = true
            case .cancelled: return .stop(.cancelled)
            case let .failed(reason):
                why = reason
                offline = false
            }
            if attempt < delays.count {
                do { try await Task.sleep(for: delays[attempt]) } catch { return .stop(.cancelled) }
            }
        }
        return .stop(offline ? .offline : .failed(why))
    }
}
