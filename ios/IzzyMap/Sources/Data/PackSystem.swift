import BackgroundAssets
import Foundation
import Synchronization
import System
import os

/// What `PackStore` needs from Background Assets — the real
/// `AssetPackManager` (`ApplePackSystem`), or a fake (`FakePackSystem`: unit
/// tests, and the DEBUG `-fakePacks` store the UI tests and screenshots use).
/// Packs are named by ID: `AssetPack` values can't be made outside the
/// framework, and the store never needs one.
nonisolated protocol PackSystem: AnyObject, Sendable {
    /// Every download event, for every pack (one subscriber: the store).
    func events() async -> AsyncStream<PackSystemEvent>
    /// The server's packs (iOS 27 `manifest`).
    func manifest() async throws -> [PackManifestEntry]
    /// `checkForUpdates`: the server's latest information, unconditionally.
    func checkForUpdates() async throws -> (updating: Set<String>, removed: Set<String>)
    /// `ensureLocalAvailability`: schedules the download if the pack isn't
    /// local, returns once it is (throws otherwise).
    func ensureLocalAvailability(_ id: String) async throws
    func remove(_ id: String) async throws
    /// `localStatus` (no server round trip).
    func localStatus(_ id: String) async -> PackSystemStatus
    /// Which packs are local and where each file resolves NOW — synchronous
    /// file-system work: call it off the main thread. Never cached across
    /// launches (`url(for:)`'s URL must not outlive the process; iOS 27
    /// moved the files from `Staging/` to `Staging/Unlocalized/`).
    func resolve() -> PackResolution
}

/// One status event of the system's downloads.
nonisolated struct PackSystemEvent: Sendable {
    nonisolated enum Kind: Sendable {
        case began, paused, finished
        case downloading(Double)
        case failed(any Error)
    }
    let id: String
    let kind: Kind
}

nonisolated struct PackManifestEntry: Sendable, Equatable {
    let id: String
    let version: Int
    let downloadSize: Int
}

/// The system's local view of one pack (`AssetPack.Status`, the two flags
/// the store acts on, plus the raw value for Diagnostics).
nonisolated struct PackSystemStatus: Sendable, Equatable {
    var downloading = false
    var downloaded = false
    var raw: UInt = 0
}

/// What `PackSystem.resolve()` found.
nonisolated struct PackResolution: Sendable {
    var location: DataLocation
    /// On the device with every file readable.
    var installed: Set<Pack>
    /// The system says it's on the device (`assetPackIsAvailableLocally`).
    var systemLocal: Set<Pack>
    var plantID: URL?
}

// MARK: - The real manager

/// `AssetPackManager.shared`. Constructing this touches nothing: the
/// manager connects to its helper service on first use (0.2–0.27 s), so the
/// store calls in off the main thread.
nonisolated final class ApplePackSystem: PackSystem {
    /// The catalogue's packs by ID (`ensureLocalAvailability` takes the value).
    private let known = Mutex<[String: AssetPack]>([:])
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Packs")

    func events() async -> AsyncStream<PackSystemEvent> {
        let updates = await AssetPackManager.shared.statusUpdates
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates {
                    switch update {
                    case let .began(p): continuation.yield(.init(id: p.id, kind: .began))
                    case let .paused(p): continuation.yield(.init(id: p.id, kind: .paused))
                    case let .downloading(p, progress): continuation.yield(.init(id: p.id, kind: .downloading(progress.fractionCompleted)))
                    case let .finished(p): continuation.yield(.init(id: p.id, kind: .finished))
                    case let .failed(p, error): continuation.yield(.init(id: p.id, kind: .failed(error)))
                    @unknown default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func manifest() async throws -> [PackManifestEntry] {
        let packs = try await AssetPackManager.shared.manifest.assetPacks
        known.withLock { map in for p in packs { map[p.id] = p } }
        return packs.map { PackManifestEntry(id: $0.id, version: $0.version, downloadSize: $0.downloadSize) }
    }

    func checkForUpdates() async throws -> (updating: Set<String>, removed: Set<String>) {
        let (updating, removed) = try await AssetPackManager.shared.checkForUpdates()
        known.withLock { $0 = [:] }
        return (updating, removed)
    }

    func ensureLocalAvailability(_ id: String) async throws {
        let assetPack: AssetPack
        if let cached = known.withLock({ $0[id] }) {
            assetPack = cached
        } else {
            guard let found = try await AssetPackManager.shared.manifest.assetPack(withID: id) else {
                throw ManagedBackgroundAssetsError.assetPackNotFound(withID: id)
            }
            known.withLock { $0[id] = found }
            assetPack = found
        }
        try await AssetPackManager.shared.ensureLocalAvailability(of: assetPack, requireLatestVersion: false)
    }

    func remove(_ id: String) async throws {
        try await AssetPackManager.shared.remove(assetPackWithID: id)
    }

    func localStatus(_ id: String) async -> PackSystemStatus {
        let s = await AssetPackManager.shared.localStatus(ofAssetPackWithID: id)
        return PackSystemStatus(downloading: s.contains(.downloading), downloaded: s.contains(.downloaded), raw: UInt(s.rawValue))
    }

    /// Which packs are local, and the file URL of each of their archives.
    /// `url(for:)` is the documented way to get a path for code that opens
    /// files itself (MapLibre's `pmtiles://file://`); its URL must not be
    /// persisted beyond this process. A pack counts as installed only when
    /// every one of its archives is readable.
    func resolve() -> PackResolution {
        let manager = AssetPackManager.shared
        let fileManager = FileManager.default
        var archives: [Archive: URL] = [:]
        var installed: Set<Pack> = []
        var systemLocal: Set<Pack> = []
        var plantID: URL?
        for pack in Pack.allCases {
            guard manager.assetPackIsAvailableLocally(withID: pack.rawValue) else { continue }
            systemLocal.insert(pack)
            var found: [Archive: URL] = [:]
            for archive in pack.archives {
                let url = try? manager.url(for: FilePath(archive.fileName))
                let readable = url.map { fileManager.isReadableFile(atPath: $0.path(percentEncoded: false)) } ?? false
                Self.logger.debug("\(pack.rawValue, privacy: .public)/\(archive.fileName, privacy: .public): \(url?.path(percentEncoded: false) ?? "no URL", privacy: .public) readable=\(readable)")
                if let url, readable { found[archive] = url }
            }
            guard found.count == pack.archives.count else { continue }
            let folder = Self.otherFilesFolder(pack, manager: manager, fileManager: fileManager)
            guard pack.otherFiles.isEmpty || folder != nil else { continue }
            archives.merge(found) { a, _ in a }
            installed.insert(pack)
            if pack == .plantid { plantID = folder }
        }
        return PackResolution(location: DataLocation(origin: .assetPacks, archives: archives), installed: installed,
                              systemLocal: systemLocal, plantID: plantID)
    }

    /// The one folder holding all of a pack's `otherFiles`, when every one
    /// is there (files readable, directories present). `url(for:)` may not
    /// resolve a directory, so a directory is also looked for beside the
    /// pack's files.
    private static func otherFilesFolder(_ pack: Pack, manager: AssetPackManager, fileManager: FileManager) -> URL? {
        guard !pack.otherFiles.isEmpty else { return nil }
        var folder: URL?
        for path in pack.otherFiles where !path.hasSuffix("/") {
            guard let url = try? manager.url(for: FilePath(path)),
                  fileManager.isReadableFile(atPath: url.path(percentEncoded: false))
            else {
                logger.debug("\(pack.rawValue, privacy: .public)/\(path, privacy: .public): not readable")
                return nil
            }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if let folder, folder != parent {
                logger.fault("\(pack.rawValue, privacy: .public): files in two folders (\(folder.path(percentEncoded: false), privacy: .public), \(parent.path(percentEncoded: false), privacy: .public))")
                return nil
            }
            folder = parent
        }
        for path in pack.otherFiles where path.hasSuffix("/") {
            let name = String(path.dropLast())
            let leaf = String(name.split(separator: "/").last ?? Substring(name))
            let candidates = [(try? manager.url(for: FilePath(name))), folder?.appending(path: leaf, directoryHint: .isDirectory)]
            let found = candidates.compactMap { $0 }.first { url in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
            }
            guard let found, found.deletingLastPathComponent().standardizedFileURL == folder ?? found.deletingLastPathComponent().standardizedFileURL else {
                logger.debug("\(pack.rawValue, privacy: .public)/\(path, privacy: .public): no such folder")
                return nil
            }
            folder = folder ?? found.deletingLastPathComponent().standardizedFileURL
        }
        logger.debug("\(pack.rawValue, privacy: .public): files in \(folder?.path(percentEncoded: false) ?? "?", privacy: .public)")
        return folder
    }
}

#if DEBUG
// MARK: - The fake

/// A scriptable stand-in for Background Assets: the DEBUG `-fakePacks`
/// store (a request "downloads" over `seconds`) and the unit tests (per-pack
/// scripts: failures, hangs, out-of-band completion; it records how many
/// requests were in flight at once).
nonisolated final class FakePackSystem: PackSystem {
    nonisolated struct Script: Sendable {
        /// Errors the next requests throw, in order (then it downloads).
        var failures: [any Error] = []
        /// The next this many requests never return by themselves
        /// (`finish`/`fail` end them).
        var hangs = 0
        /// A hanging request leaves nothing downloading in the system (a
        /// lost request: local status []).
        var silent = false
        /// `remove` doesn't make a hanging request return (it never does).
        var ignoresRemove = false
        /// `remove` itself never returns.
        var removeHangs = false
        /// It throws this after the download "finished" in the system
        /// (the request failed, yet the pack is here).
        var throwsAfterInstalling: (any Error)?
    }

    private struct Inner {
        var installed: Set<String> = []
        var downloading: [String: Double] = [:]
        /// Local per the system, yet its files don't resolve.
        var unreadable: Set<String> = []
        var unpublished: Set<String> = []
        var scripts: [String: Script] = [:]
        var requests: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var hung: [String: [CheckedContinuation<Void, any Error>]] = [:]
        var removedDuring: Set<String> = []
        /// Requests ("id") and removals ("-id"), in order.
        var log: [String] = []
        var manifestFails = false
        var subscriber: AsyncStream<PackSystemEvent>.Continuation?
    }

    private let inner: Mutex<Inner>
    let seconds: Double
    let directory: URL?
    /// How long a call takes to return after its outcome (finished, failed,
    /// removed) — real calls answer a moment later, and the store must
    /// still not start the next one before.
    let returnDelay: Double

    init(installed: Set<Pack> = [], downloading: [Pack: Double] = [:], unpublished: Set<Pack> = [],
         seconds: Double = 0.05, directory: URL? = nil, returnDelay: Double = 0.2) {
        var i = Inner()
        i.installed = Set(installed.map(\.rawValue))
        i.downloading = Dictionary(uniqueKeysWithValues: downloading.map { ($0.key.rawValue, $0.value) })
        i.unpublished = Set(unpublished.map(\.rawValue))
        inner = Mutex(i)
        self.seconds = seconds
        self.directory = directory
        self.returnDelay = returnDelay
    }

    // test controls and observations
    func script(_ pack: Pack, _ script: Script) { inner.withLock { $0.scripts[pack.rawValue] = script } }
    var requests: [String] { inner.withLock { $0.requests } }
    var log: [String] { inner.withLock { $0.log } }
    /// The log without the return marks ("<id"): calls and removals.
    var calls: [String] { log.filter { !$0.hasPrefix("<") } }
    /// The manifest can't be read (offline).
    func setManifestFails(_ on: Bool) { inner.withLock { $0.manifestFails = on } }
    var maxInFlight: Int { inner.withLock { $0.maxInFlight } }
    var inFlight: Int { inner.withLock { $0.inFlight } }
    func isInstalled(_ pack: Pack) -> Bool { inner.withLock { $0.installed.contains(pack.rawValue) } }
    func setUnreadable(_ pack: Pack, _ on: Bool) {
        inner.withLock { if on { $0.unreadable.insert(pack.rawValue) } else { $0.unreadable.remove(pack.rawValue) } }
    }

    /// The system finishes the download by itself (a hung request returns).
    func finish(_ pack: Pack) {
        let waiters = inner.withLock { i -> [CheckedContinuation<Void, any Error>] in
            i.installed.insert(pack.rawValue)
            i.downloading[pack.rawValue] = nil
            return i.hung.removeValue(forKey: pack.rawValue) ?? []
        }
        emit(pack.rawValue, .finished)
        for w in waiters { w.resume() }
    }

    /// The pack arrives without any event (seen only by asking).
    func installSilently(_ pack: Pack) {
        inner.withLock { i in
            i.installed.insert(pack.rawValue)
            i.downloading[pack.rawValue] = nil
        }
    }

    /// The system forgets a download (local status []), no event.
    func drop(_ pack: Pack) {
        _ = inner.withLock { $0.downloading.removeValue(forKey: pack.rawValue) }
    }

    /// The system pauses the download (no network, Low Power Mode, …).
    func pause(_ pack: Pack) { emit(pack.rawValue, .paused) }

    /// The system reports progress by itself.
    func progress(_ pack: Pack, _ fraction: Double) {
        inner.withLock { $0.downloading[pack.rawValue] = fraction }
        emit(pack.rawValue, .downloading(fraction))
    }

    /// A hung request throws (the system keeps or drops the download as `keepsDownloading` says).
    func fail(_ pack: Pack, _ error: any Error, keepsDownloading: Bool = false) {
        let waiters = inner.withLock { i -> [CheckedContinuation<Void, any Error>] in
            if !keepsDownloading { i.downloading[pack.rawValue] = nil }
            return i.hung.removeValue(forKey: pack.rawValue) ?? []
        }
        for w in waiters { w.resume(throwing: error) }
    }

    private func emit(_ id: String, _ kind: PackSystemEvent.Kind) {
        let sub = inner.withLock { $0.subscriber }
        sub?.yield(PackSystemEvent(id: id, kind: kind))
    }

    func events() async -> AsyncStream<PackSystemEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PackSystemEvent.self)
        inner.withLock { $0.subscriber = continuation }
        return stream
    }

    func manifest() async throws -> [PackManifestEntry] {
        let (unpublished, fails) = inner.withLock { ($0.unpublished, $0.manifestFails) }
        if fails { throw URLError(.notConnectedToInternet) }
        return Pack.allCases.filter { !unpublished.contains($0.rawValue) }
            .map { PackManifestEntry(id: $0.rawValue, version: 1, downloadSize: PackSizes.nominal[$0] ?? 0) }
    }

    func checkForUpdates() async throws -> (updating: Set<String>, removed: Set<String>) { ([], []) }

    func ensureLocalAvailability(_ id: String) async throws {
        let (script, unpublished, start) = inner.withLock { i -> (Script, Bool, Double) in
            i.requests.append(id)
            i.log.append(id)
            i.inFlight += 1
            i.maxInFlight = max(i.maxInFlight, i.inFlight)
            i.removedDuring.remove(id)
            var s = i.scripts[id] ?? Script()
            let script = s
            if !s.failures.isEmpty { s.failures.removeFirst() } else if s.hangs > 0 { s.hangs -= 1 }
            s.throwsAfterInstalling = nil
            i.scripts[id] = s
            return (script, i.unpublished.contains(id), i.downloading[id] ?? 0)
        }
        let result: Result<Void, any Error>
        do {
            try await body(id, script: script, unpublished: unpublished, start: start)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // like the real call, it returns a while after the system's
        // `finished` (or a `remove`): it counts as in flight until then, so
        // a store that started the next call early shows up as an overlap
        if returnDelay > 0 { try? await Task.sleep(for: .seconds(returnDelay)) }
        inner.withLock { i in
            i.inFlight -= 1
            i.log.append("<" + id)
        }
        try result.get()
    }

    private func body(_ id: String, script: Script, unpublished: Bool, start: Double) async throws {
        if unpublished { throw ManagedBackgroundAssetsError.assetPackNotFound(withID: id) }
        if inner.withLock({ $0.installed.contains(id) }) { return }
        if let error = script.failures.first {
            try await Task.sleep(for: .milliseconds(5))
            throw error
        }
        if script.hangs > 0 {
            if !script.silent {
                inner.withLock { $0.downloading[id] = $0.downloading[id] ?? 0 }
                emit(id, .began)
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                inner.withLock { $0.hung[id, default: []].append(c) }
            }
            return
        }
        inner.withLock { $0.downloading[id] = start }
        emit(id, .began)
        let steps = 20
        for i in 1 ... steps {
            try await Task.sleep(for: .seconds(seconds / Double(steps)))
            if inner.withLock({ $0.removedDuring.contains(id) }) {
                throw CancellationError()
            }
            let f = start + (1 - start) * Double(i) / Double(steps)
            inner.withLock { $0.downloading[id] = f }
            emit(id, .downloading(f))
        }
        // removed while it ran: gone, never installed (one step with the check)
        let removed = inner.withLock { i -> Bool in
            if i.removedDuring.contains(id) { return true }
            i.installed.insert(id)
            i.downloading[id] = nil
            return false
        }
        if removed { throw CancellationError() }
        emit(id, .finished)
        if let error = script.throwsAfterInstalling { throw error }
    }

    func remove(_ id: String) async throws {
        if inner.withLock({ $0.scripts[id]?.removeHangs == true }) {
            inner.withLock { $0.log.append("-" + id) }
            try await Task.sleep(for: .seconds(3600))
            return
        }
        let waiters = inner.withLock { i -> [CheckedContinuation<Void, any Error>] in
            i.installed.remove(id)
            i.downloading[id] = nil
            i.removedDuring.insert(id)
            i.log.append("-" + id)
            if i.scripts[id]?.ignoresRemove == true { return [] }
            return i.hung.removeValue(forKey: id) ?? []
        }
        for w in waiters { w.resume(throwing: CancellationError()) }
    }

    func localStatus(_ id: String) async -> PackSystemStatus {
        inner.withLock { i in
            PackSystemStatus(downloading: i.downloading[id] != nil, downloaded: i.installed.contains(id),
                             raw: (i.downloading[id] != nil ? 32 : 0) | (i.installed.contains(id) ? 64 : 0))
        }
    }

    func resolve() -> PackResolution {
        let (installed, unreadable) = inner.withLock { ($0.installed, $0.unreadable) }
        let scanned = directory.map { DataLocator.scan(directory: $0) }
        var archives: [Archive: URL] = [:]
        var have: Set<Pack> = []
        var local: Set<Pack> = []
        for pack in Pack.allCases where installed.contains(pack.rawValue) {
            local.insert(pack)
            guard !unreadable.contains(pack.rawValue) else { continue }
            have.insert(pack)
            for archive in pack.archives { archives[archive] = scanned?.url(for: archive) }
        }
        return PackResolution(location: DataLocation(origin: .assetPacks, archives: archives), installed: have,
                              systemLocal: local, plantID: nil)
    }
}
#endif
