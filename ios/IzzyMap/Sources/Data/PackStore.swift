import BackgroundAssets
import Foundation
import Observation
import System
import os

/// The offline map archives on this device and the state of every
/// Apple-hosted Background Assets pack (docs/NATIVE_PLAN.md §2 "Pack facts").
///
/// - Release builds (and DEBUG without `-dataDir`): the packs the system
///   downloads. `vector` (essential) and `topo`/`relief` (prefetch) arrive
///   with the install; the rest come from `fetch(_:)` — one tap each.
/// - DEBUG `-dataDir <path>`: the developer's `data/` directory, read in
///   place; Background Assets is never touched.
/// - Tests and previews: a fixed location.
///
/// `location` is observable: the style (via `AppModel.data`) and everything
/// else that reads it follows pack installs and removals. Non-SwiftUI code
/// that must react (the thumbnail cache) uses `observe(_:)`.
@MainActor
@Observable
final class PackStore {
    nonisolated enum Mode: Equatable, Sendable {
        case assetPacks
        case debugDirectory(URL)
        case fixed
        #if DEBUG
        /// `-fakePacks <spec>` (UI tests, screenshots; `FakePacks`): pack
        /// states from the spec, fetch and remove simulated. With `-dataDir`
        /// an installed pack's archives come from that directory, so the map
        /// really restyles as fake packs arrive and leave.
        case fake
        #endif
    }

    let mode: Mode
    /// The archives that are readable right now.
    private(set) var location: DataLocation
    /// Per-pack state (Background Assets mode); every pack has an entry.
    private(set) var states: [Pack: PackState]
    /// Download sizes from the server manifest, once it has been read.
    private(set) var downloadSizes: [Pack: Int] = [:]
    /// Readers of the local season packs, for the coverage caption (rebuilt
    /// with `location`, so a removed pack's file is never held open).
    private(set) var seasonProbes: SeasonProbes
    /// False until the packs on the device have been looked up (Background
    /// Assets mode: ~0.2–0.3 s after launch, see `launch`). Until then an
    /// empty `location` means "not known yet", not "nothing on the device".
    private(set) var isResolved = true
    /// Installed packs the system is updating in the background (a new
    /// version on the server): the fraction so far (0 until the first
    /// report). The pack stays `.installed` — its old version keeps serving
    /// the map until the new one is in place — so nothing shows it as a
    /// fresh download (no Stop, no Layers badge, the gauge keeps its bytes).
    private(set) var updates: [Pack: Double] = [:]

    @ObservationIgnored private var handlers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var fetches: [Pack: Task<Void, Never>] = [:]
    /// Which fetch task is the live one per pack: a task whose token was
    /// replaced (Resume) or dropped (Stop/Remove) leaves `states` alone.
    @ObservationIgnored private var fetchTokens: [Pack: UUID] = [:]
    /// Packs stopped from Storage: status events still in flight for them
    /// (`downloading`, `paused`, `failed`) are ignored until a new fetch,
    /// so a stopped row can't flip back to "Downloading".
    @ObservationIgnored private var stopped: Set<Pack> = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var manifest: [Pack: AssetPack] = [:]
    /// Set at launch when the process can't use Background Assets (no app
    /// group in its signature): no packs, and the manager is never touched.
    private(set) var backgroundAssetsUnavailable = false
    #if DEBUG
    @ObservationIgnored private var fake: FakePacks?
    #endif
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Packs")

    private init(mode: Mode, location: DataLocation, states: [Pack: PackState]) {
        self.mode = mode
        self.location = location
        self.states = states
        self.seasonProbes = SeasonProbes(location: location)
    }

    /// Tests and previews: these archives, no Background Assets.
    convenience init(fixed location: DataLocation) {
        self.init(mode: .fixed, location: location, states: Self.states(for: location))
    }

    /// The store for this launch. In Background Assets mode the packs on the
    /// device are looked up OFF the main thread: the first touch of
    /// `AssetPackManager.shared` connects to the system's helper service and
    /// took 0.2–0.27 s on the 27.2 simulator (2026-11-03) — too long to block
    /// launch. The map starts without packs and restyles when they're known
    /// (same frame budget as tiles loading). Downloads and the server
    /// manifest are followed from then on.
    static func launch(defaults: UserDefaults = .standard) -> PackStore {
        #if DEBUG
        if let spec = defaults.string(forKey: FakePacks.key), !spec.isEmpty {
            let dir = defaults.string(forKey: DataLocator.dataDirectoryKey).flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(filePath: $0, directoryHint: .isDirectory) }
            let seconds = defaults.double(forKey: "fakePackSeconds")
            return PackStore(fake: FakePacks(spec: spec, directory: dir, seconds: seconds > 0 ? seconds : 4))
        }
        if let path = defaults.string(forKey: DataLocator.dataDirectoryKey), !path.isEmpty {
            let location = DataLocator.locate(debugDirectory: path)
            let dir = URL(filePath: path, directoryHint: .isDirectory)
            // `-dataDirArrivesAfter <seconds>`: start empty, then "install"
            // the directory's archives — a pack arriving while the app runs
            // (exercises the style and thumbnail hooks without Background Assets)
            let delay = defaults.double(forKey: "dataDirArrivesAfter")
            guard delay > 0 else {
                return PackStore(mode: .debugDirectory(dir), location: location, states: states(for: location))
            }
            let empty = DataLocation(origin: .debugDirectory(dir), archives: [:])
            let store = PackStore(mode: .debugDirectory(dir), location: empty, states: states(for: empty))
            Task { [weak store] in
                try? await Task.sleep(for: .seconds(delay))
                store?.states = states(for: location)
                store?.publish(location)
            }
            return store
        }
        #endif
        let store = PackStore(mode: .assetPacks, location: DataLocation(origin: .assetPacks, archives: [:]),
                              states: Dictionary(uniqueKeysWithValues: Pack.allCases.map { ($0, .notInstalled) }))
        store.isResolved = false
        Task { [weak store] in
            let start = ContinuousClock.now
            // Background Assets traps (kills the app) when the app group named
            // by BAAppGroupID isn't in the signature — an unsigned build
            // (`CODE_SIGNING_ALLOWED=NO`; CI crashed on launch this way,
            // 2026-11-03). Without the group there are no packs: run with none.
            guard await Self.appGroupIsAccessibleOffMain() else {
                logger.fault("Background Assets unavailable: the app group isn't accessible (unsigned build?)")
                store?.backgroundAssetsUnavailable = true
                store?.isResolved = true
                return
            }
            // first: nothing on the main actor may touch the manager before this
            await store?.refresh()
            guard let store else { return }
            store.isResolved = true
            logger.info("launch: \(store.states.filter { $0.value.isInstalled }.keys.map(\.rawValue).sorted(), privacy: .public) installed (\(start.duration(to: .now), privacy: .public))")
            store.start(defaults: defaults)
        }
        return store
    }

    func state(_ pack: Pack) -> PackState { states[pack] ?? .notInstalled }

    /// Whether `fetch`/`remove` do anything here (Background Assets, or the
    /// DEBUG fake). A developer's `-dataDir` folder is read as it is.
    var canFetch: Bool {
        #if DEBUG
        if mode == .fake { return true }
        #endif
        return managesPacks
    }

    /// Background Assets mode with a usable manager.
    private var managesPacks: Bool { mode == .assetPacks && !backgroundAssetsUnavailable }

    // MARK: Observation for non-SwiftUI code

    /// Calls `handler` after every change of `location` (main actor). Keep
    /// the token alive; dropping it ends the subscription.
    func observe(_ handler: @escaping @MainActor () -> Void) -> Connectivity.Subscription {
        let id = UUID()
        handlers[id] = handler
        return Connectivity.Subscription { [weak self] in self?.handlers[id] = nil }
    }

    private func publish(_ new: DataLocation) {
        guard new != location else { return }
        location = new
        seasonProbes = SeasonProbes(location: new)
        Self.logger.info("archives now: \(new.archives.keys.map(\.rawValue).sorted(), privacy: .public)")
        for handler in handlers.values { handler() }
    }

    // MARK: Fetch and remove

    /// Downloads an on-demand pack (or retries a core pack): the system
    /// schedules it and it keeps going in the background; `states` follows.
    func fetch(_ pack: Pack) {
        #if DEBUG
        if mode == .fake { return fakeFetch(pack) }
        #endif
        guard managesPacks, fetches[pack] == nil, !state(pack).isInstalled else { return }
        start(pack)
    }

    /// A paused download, asked for again (the row's Resume): a fresh
    /// `ensureLocalAvailability` — the system's own download carries on
    /// where it was; the old request's outcome is ignored.
    func resume(_ pack: Pack) {
        #if DEBUG
        if mode == .fake {
            fetches[pack]?.cancel()
            fetches[pack] = nil
            return fakeFetch(pack)
        }
        #endif
        guard managesPacks, !state(pack).isInstalled else { return }
        fetches[pack]?.cancel()
        start(pack)
    }

    private func start(_ pack: Pack) {
        let token = UUID()
        fetchTokens[pack] = token
        stopped.remove(pack)
        if case .downloading = states[pack] {} else { states[pack] = .downloading(nil) }
        fetches[pack] = Task { [weak self] in
            // a tap in the first moments after launch: let the lookup finish
            // (it initialises the manager off the main thread)
            while self?.isResolved == false { try? await Task.sleep(for: .milliseconds(50)) }
            do {
                guard let assetPack = try await self?.assetPack(pack) else { return }
                try await Self.ensureLocalAvailability(of: assetPack)
                Self.logger.info("\(pack.rawValue, privacy: .public): available locally")
                guard !Task.isCancelled, let self, self.fetchTokens[pack] == token else { return }
                await self.refresh()
                // available, yet its archives aren't readable: say so (with a
                // Retry) rather than leave the row waiting for ever
                if self.fetchTokens[pack] == token, !self.state(pack).isInstalled {
                    Self.logger.error("\(pack.rawValue, privacy: .public): available but its archives aren't readable")
                    self.states[pack] = .failed(Self.unreadable)
                }
            } catch {
                // stopped or superseded: whoever did that owns the state now
                guard !Task.isCancelled, let self, self.fetchTokens[pack] == token else { return }
                Self.logger.error("\(pack.rawValue, privacy: .public): fetch failed: \(String(describing: error), privacy: .public)")
                self.states[pack] = .failed(error.localizedDescription)
            }
            guard let self, self.fetchTokens[pack] == token else { return }
            self.fetches[pack] = nil
            self.fetchTokens[pack] = nil
        }
    }

    nonisolated static let unreadable = "The download finished, but its files couldn't be opened."

    /// Removes an on-demand pack. Its archives leave the style FIRST, so
    /// MapLibre and the season probes let go of the files, then the system
    /// deletes them.
    func remove(_ pack: Pack) async {
        #if DEBUG
        if mode == .fake { return await fakeRemove(pack) }
        #endif
        guard managesPacks, pack.isRemovable else { return }
        // Stop as much as Remove: late events of this download are ignored
        stopped.insert(pack)
        fetches[pack]?.cancel()
        fetches[pack] = nil
        fetchTokens[pack] = nil
        updates[pack] = nil
        var shown = location.archives
        for archive in pack.archives { shown[archive] = nil }
        publish(DataLocation(origin: location.origin, archives: shown))
        // one run-loop turn: the style rebuild drops the source first
        try? await Task.sleep(for: .milliseconds(300))
        do {
            try await AssetPackManager.shared.remove(assetPackWithID: pack.rawValue)
            Self.logger.info("\(pack.rawValue, privacy: .public): removed")
        } catch {
            Self.logger.error("\(pack.rawValue, privacy: .public): remove failed: \(String(describing: error), privacy: .public)")
        }
        await refresh()
        // a download stopped from Storage: `refresh` only clears installed
        // packs, and a stopped one's late events are ignored
        if !state(pack).isInstalled, fetchTokens[pack] == nil { states[pack] = .notInstalled }
    }

    // MARK: Background Assets

    private func start(defaults: UserDefaults) {
        statusTask = Task { [weak self] in
            let updates = await AssetPackManager.shared.statusUpdates
            for await update in updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
        Task { [weak self] in
            #if DEBUG
            // simulated offline: the manifest refresh would go to Apple's servers
            if DebugNetwork.simulatedOffline { return }
            #endif
            await self?.loadManifest()
            guard let self else { return }
            // Core packs are the system's job, but "network dropouts or other
            // uncommon issues can prevent the system from downloading [even
            // an essential pack] until you call ensureLocalAvailability"
            // (Apple, "Downloading Apple-hosted asset packs").
            for pack in Pack.allCases where pack.policy != .onDemand && !self.state(pack).isInstalled
                && self.manifest[pack] != nil {
                self.fetch(pack)
            }
            // test hook (all builds; only reachable through launch
            // arguments): `-fetchPacks season-2021,aerial`, `-removePacks …`
            for id in Self.ids(defaults.string(forKey: "removePacks")) { await self.remove(id) }
            for id in Self.ids(defaults.string(forKey: "fetchPacks")) { self.fetch(id) }
        }
    }

    private static func ids(_ list: String?) -> [Pack] {
        (list ?? "").split(separator: ",").compactMap { Pack(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    private func handle(_ update: AssetPackManager.DownloadStatusUpdate) async {
        switch update {
        case let .began(assetPack):
            set(assetPack, .downloading(nil))
        case let .paused(assetPack):
            set(assetPack, .paused)
        case let .downloading(assetPack, progress):
            set(assetPack, .downloading(progress.fractionCompleted))
        case let .finished(assetPack):
            Self.logger.info("\(assetPack.id, privacy: .public): download finished")
            if let pack = Pack(rawValue: assetPack.id) { updates[pack] = nil }
            await refresh()
            // a system download (core pack, update) whose files can't be
            // read: a Retry, never a row stuck "Waiting" (a fetch of ours
            // reports this itself when `ensureLocalAvailability` returns)
            if let pack = Pack(rawValue: assetPack.id), !state(pack).isInstalled,
               fetchTokens[pack] == nil, !stopped.contains(pack) {
                states[pack] = .failed(Self.unreadable)
            }
        case let .failed(assetPack, error):
            Self.logger.error("\(assetPack.id, privacy: .public): download failed: \(String(describing: error), privacy: .public)")
            set(assetPack, .failed(error.localizedDescription))
        @unknown default:
            await refresh()
        }
    }

    private func set(_ assetPack: AssetPack, _ state: PackState) {
        guard let pack = Pack(rawValue: assetPack.id), !stopped.contains(pack) else { return }
        if self.state(pack).isInstalled {
            // an installed pack downloading again = a new version arriving
            // in the background; the installed one keeps serving
            switch state {
            case let .downloading(f):
                let new = f ?? 0
                if let old = updates[pack], Int(new * 100) == Int(old * 100) { return }
                updates[pack] = new
            case .failed:
                updates[pack] = nil
            default:
                if updates[pack] == nil { updates[pack] = 0 }
            }
            return
        }
        guard states[pack] != state else { return }
        // progress is reported often: the row only shows whole percents
        if case let .downloading(new?) = state, case let .downloading(old?) = states[pack],
           Int(new * 100) == Int(old * 100) { return }
        states[pack] = state
    }

    /// Re-reads which packs are on the device (off the main thread).
    private func refresh() async {
        let (location, installed) = await Self.resolveInstalledOffMain()
        for pack in Pack.allCases {
            if installed.contains(pack) {
                states[pack] = .installed
            } else if states[pack] == .installed {
                states[pack] = .notInstalled
                updates[pack] = nil
            }
        }
        publish(location)
    }

    private func loadManifest() async {
        do {
            let packs: Set<AssetPack>
            if #available(iOS 27, *) {
                packs = try await AssetPackManager.shared.manifest.assetPacks
            } else {
                packs = try await AssetPackManager.shared.allAssetPacks
            }
            for assetPack in packs {
                guard let pack = Pack(rawValue: assetPack.id) else {
                    Self.logger.notice("server has an unknown pack \(assetPack.id, privacy: .public)")
                    continue
                }
                manifest[pack] = assetPack
                downloadSizes[pack] = assetPack.downloadSize
            }
            Self.logger.info("manifest: \(packs.map { "\($0.id) v\($0.version) \($0.downloadSize)" }.sorted(), privacy: .public)")
        } catch {
            // offline, or no packs uploaded yet: sizes stay unknown
            Self.logger.notice("manifest unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func assetPack(_ pack: Pack) async throws -> AssetPack {
        if let known = manifest[pack] { return known }
        let assetPack: AssetPack
        if #available(iOS 27, *) {
            guard let found = try await AssetPackManager.shared.manifest.assetPack(withID: pack.rawValue) else {
                throw ManagedBackgroundAssetsError.assetPackNotFound(withID: pack.rawValue)
            }
            assetPack = found
        } else {
            assetPack = try await AssetPackManager.shared.assetPack(withID: pack.rawValue)
        }
        manifest[pack] = assetPack
        downloadSizes[pack] = assetPack.downloadSize
        return assetPack
    }

    nonisolated private static func ensureLocalAvailability(of assetPack: AssetPack) async throws {
        if #available(iOS 26.4, *) {
            try await AssetPackManager.shared.ensureLocalAvailability(of: assetPack, requireLatestVersion: false)
        } else {
            try await AssetPackManager.shared.ensureLocalAvailability(of: assetPack)
        }
    }

    // MARK: Resolving files

    @concurrent nonisolated private static func resolveInstalledOffMain() async -> (DataLocation, Set<Pack>) {
        resolveInstalled()
    }

    /// Whether this process can use the app group Background Assets
    /// coordinates through (Info.plist BAAppGroupID): `containerURL` is nil
    /// when the signature doesn't carry it.
    @concurrent nonisolated private static func appGroupIsAccessibleOffMain() async -> Bool {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BAAppGroupID") as? String else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }

    /// Which packs are local, and the file URL of each of their archives.
    /// `url(for:)` is the documented way to get a path for code that opens
    /// files itself (MapLibre's `pmtiles://file://`); its URL must not be
    /// persisted beyond this process. A pack counts as installed only when
    /// every one of its archives is readable.
    nonisolated private static func resolveInstalled(fileManager: FileManager = .default) -> (DataLocation, Set<Pack>) {
        let manager = AssetPackManager.shared
        var archives: [Archive: URL] = [:]
        var installed: Set<Pack> = []
        for pack in Pack.allCases {
            if #available(iOS 26.4, *) {
                guard manager.assetPackIsAvailableLocally(withID: pack.rawValue) else { continue }
            }
            var found: [Archive: URL] = [:]
            for archive in pack.archives {
                let url = try? manager.url(for: FilePath(archive.fileName))
                let readable = url.map { fileManager.isReadableFile(atPath: $0.path(percentEncoded: false)) } ?? false
                logger.debug("\(pack.rawValue, privacy: .public)/\(archive.fileName, privacy: .public): \(url?.path(percentEncoded: false) ?? "no URL", privacy: .public) readable=\(readable)")
                if let url, readable { found[archive] = url }
            }
            guard found.count == pack.archives.count else { continue }
            // pre-26.4 has no availability call: an empty pack can't be told apart
            if pack.archives.isEmpty, #unavailable(iOS 26.4) { continue }
            archives.merge(found) { a, _ in a }
            installed.insert(pack)
        }
        return (DataLocation(origin: .assetPacks, archives: archives), installed)
    }

    private static func states(for location: DataLocation) -> [Pack: PackState] {
        Dictionary(uniqueKeysWithValues: Pack.allCases.map { pack in
            let have = !pack.archives.isEmpty && pack.archives.allSatisfy { location.url(for: $0) != nil }
            return (pack, have ? .installed : .notInstalled)
        })
    }
}

#if DEBUG
// MARK: - DEBUG fake store

/// The DEBUG stand-in for Background Assets (the real `AssetPackManager`
/// has no packs in tests or a plain simulator run). Launch argument
/// `-fakePacks <spec>`: comma-separated `pack[=state]`, state one of
/// `installed` (the default), `downloading:<0…1>`, `paused`, `failed`,
/// `updating:<0…1>` (installed, a new version arriving); every other pack
/// is not installed. `mixed` is a preset for screenshots.
/// A fetch "downloads" over `-fakePackSeconds` (default 4 s).
nonisolated struct FakePacks: Sendable {
    static let key = "fakePacks"
    static let mixed = "vector,topo=updating:0.4,relief,aerial,season-2023,season-2024,season-2025=downloading:0.62,season-2026=paused"

    var states: [Pack: PackState]
    var updates: [Pack: Double] = [:]
    var directory: URL?
    var seconds: Double

    init(spec: String, directory: URL? = nil, seconds: Double = 4) {
        let spec = spec == "mixed" ? Self.mixed : spec
        var states = Dictionary(uniqueKeysWithValues: Pack.allCases.map { ($0, PackState.notInstalled) })
        var updates: [Pack: Double] = [:]
        for part in spec.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = pair.first, let pack = Pack(rawValue: first) else { continue }
            let value = pair.count > 1 ? pair[1] : "installed"
            switch value {
            case "paused": states[pack] = .paused
            case "failed": states[pack] = .failed("The download didn't finish.")
            case let v where v.hasPrefix("updating"):
                states[pack] = .installed
                updates[pack] = Double(v.split(separator: ":").last ?? "").map { min(max($0, 0), 1) } ?? 0
            case let v where v.hasPrefix("downloading"):
                states[pack] = .downloading(Double(v.split(separator: ":").last ?? "").map { min(max($0, 0), 1) })
            default: states[pack] = .installed
            }
        }
        self.states = states
        self.updates = updates
        self.directory = directory
        self.seconds = seconds
    }

    /// The archives of the installed packs (from `directory` when given).
    func location() -> DataLocation {
        guard let directory else { return DataLocation(origin: .assetPacks, archives: [:]) }
        let scanned = DataLocator.scan(directory: directory)
        var archives: [Archive: URL] = [:]
        for (pack, state) in states where state == .installed {
            for archive in pack.archives { archives[archive] = scanned.url(for: archive) }
        }
        return DataLocation(origin: .assetPacks, archives: archives)
    }
}

extension PackStore {
    convenience init(fake: FakePacks) {
        self.init(mode: .fake, location: fake.location(), states: fake.states)
        self.fake = fake
        updates = fake.updates
        downloadSizes = PackSizes.nominal
    }

    fileprivate func fakeFetch(_ pack: Pack) {
        guard fetches[pack] == nil, !state(pack).isInstalled, let seconds = fake?.seconds else { return }
        let start: Double = if case let .downloading(f?) = state(pack) { f } else { 0 }
        states[pack] = .downloading(start)
        fetches[pack] = Task { [weak self] in
            let steps = 20
            for i in 1 ... steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard let self, !Task.isCancelled else { return }
                self.states[pack] = .downloading(start + (1 - start) * Double(i) / Double(steps))
            }
            guard let self, !Task.isCancelled, var updated = self.fake else { return }
            updated.states[pack] = .installed
            self.fake = updated
            self.states[pack] = .installed
            self.fetches[pack] = nil
            self.publish(updated.location())
        }
    }

    fileprivate func fakeRemove(_ pack: Pack) async {
        guard pack.isRemovable, var fake else { return }
        fetches[pack]?.cancel()
        fetches[pack] = nil
        fake.states[pack] = .notInstalled
        fake.updates[pack] = nil
        self.fake = fake
        states[pack] = .notInstalled
        updates[pack] = nil
        publish(fake.location())
    }
}
#endif
