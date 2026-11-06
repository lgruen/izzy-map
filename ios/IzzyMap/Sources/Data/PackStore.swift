import BackgroundAssets
import Foundation
import IzzyKit
import Observation
import UIKit
import os

/// The offline map archives on this device and the state of every
/// Apple-hosted Background Assets pack (docs/NATIVE_PLAN.md §2 "Pack facts").
///
/// - Release builds (and DEBUG without `-dataDir`): the packs the system
///   downloads. `vector` (essential) and `topo`/`relief` (prefetch) arrive
///   with the install; the rest come from `fetch(_:)` — one tap each.
/// - DEBUG `-dataDir <path>`: the developer's `data/` directory, read in
///   place; Background Assets is never touched.
/// - DEBUG `-fakePacks <spec>`: the same store over `FakePackSystem`.
/// - Tests and previews: a fixed location.
///
/// **Requests are serial** (the download queue, see "Queue"): at most ONE
/// `ensureLocalAvailability` call is in flight, for any pack, and a new one
/// starts only after the previous call has RETURNED — not merely after the
/// store stopped waiting for it. On iOS 27.2 several at once made most fail
/// with "The asset pack … is unavailable" while each worked alone (field
/// report, iPhone 16e, 2026-11-04). The headers name no concurrency limit,
/// but the iOS 27 one for `ensureLocalAvailability(of:)` says "To download
/// multiple asset packs at the same time, use
/// ensureLocalAvailabilityOfAssetPacks:" (the `Set` form) — untried; the
/// serial queue stays until a device shows the batch form behaves. A lost
/// call is abandoned after a grace period (at most one at a time), so two
/// may overlap then — liveness over strictness. A failed
/// request is retried with backoff, one cut off by a suspension or made
/// offline is asked again without using a retry, and nothing is marked
/// failed before the system has been asked what it actually has: SYSTEM
/// TRUTH WINS — every refresh recomputes the states from `resolve()` (files)
/// and `localStatus` (downloads), on launch, on return to the foreground,
/// while Storage is open and after every event.
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
        /// states from the spec, downloads simulated by `FakePackSystem`. With
        /// `-dataDir` an installed pack's archives come from that directory,
        /// so the map really restyles as fake packs arrive and leave.
        case fake
        #endif
    }

    /// The queue's timing (tests shrink it).
    nonisolated struct Tuning: Sendable {
        /// Waits before the 1st, 2nd, 3rd retry of a failed request; after
        /// the last one the row says "Didn't finish · Retry".
        var retryDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
        /// A request whose pack the system neither downloads nor has, with
        /// no event for this long, is treated as lost (the watchdog).
        var stallAfter: Duration = .seconds(90)
        /// The same for a pack the system reported paused.
        var pausedStallAfter: Duration = .seconds(600)
        var watchInterval: Duration = .seconds(30)
        /// Re-reads after "local, but its files don't open" (a move in progress?).
        var unreadableRechecks: [Duration] = [.seconds(3), .seconds(15)]
        /// A request that failed while the system says it's still
        /// downloading is re-attached without using a retry, at most this often.
        var freeReattaches = 10
        /// `downloading` (or `paused`) with no event for this long, nobody
        /// asking, and the system has nothing: stale — asked for again.
        var staleAfter: Duration = .seconds(30)
        var pausedStaleAfter: Duration = .seconds(600)
        var pollInterval: Duration = .milliseconds(250)
        /// The continued-processing task hears from us at least this often.
        var heartbeat: Duration = .seconds(10)
        /// A lost call the watchdog ended (or, for a core pack, couldn't)
        /// that still hasn't returned after this long is ABANDONED: the
        /// queue goes on beside it. Liveness over strict one-at-a-time — at
        /// most one abandoned call at a time, so at most two overlap.
        var abandonGrace: Duration = .seconds(120)
        /// "Downloading" in the system but no event for this long: lost too.
        var silentDownloadAfter: Duration = .seconds(1800)
        /// A Stop/Remove the system doesn't answer holds the queue this long at most.
        var removalTimeout: Duration = .seconds(60)
        /// After a failure, a moment for the path monitor's word to arrive
        /// before a retry is spent (it hops to the main actor).
        var offlineRecheck: Duration = .seconds(1)
        /// Ticks the background task hears per pack while nothing moves.
        var maxTicksPerPack = 60
        /// A pack found damaged is looked at again after this long (same
        /// files, no system download or update running) before anything is
        /// removed: an in-place update may be mid-swap.
        var repairConfirmAfter: Duration = .seconds(20)
        /// Free space a repair needs beyond the pack's size.
        var repairMargin: Int64 = 1 << 30
    }

    /// One recorded error (Diagnostics).
    nonisolated struct ErrorRecord: Sendable, Equatable {
        let date: Date
        let stage: String
        let text: String
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
    /// The folder holding plant ID's files (`PlantIDFiles`) while the
    /// `plantid` pack is on the device and every one of them is readable.
    private(set) var plantIDDirectory: URL?
    /// Packs on the device in an older version than this build reads (plant
    /// ID's v1 model): shown as an update on its way (`.downloading`), never
    /// as a failure — the system replaces them by itself.
    private(set) var outdated: Set<Pack> = []
    /// Outdated packs the server was asked about once (`checkForUpdates`).
    @ObservationIgnored private var outdatedAsked: Set<Pack> = []

    // MARK: Queue state (observable: rows say "Queued · n")

    /// The pack the queue is working on (its call in flight, or waiting for
    /// a retry, the app, a connection or the previous call to return).
    private(set) var current: Pack?
    /// The packs waiting, in order.
    private(set) var queue: [Pack] = []
    /// Retries used by each pack since it was last asked for.
    private(set) var retries: [Pack: Int] = [:]
    /// When the current pack's next retry goes (Diagnostics).
    private(set) var retryAt: Date?
    /// The pack whose `ensureLocalAvailability` call hasn't returned yet —
    /// the in-flight marker (it may no longer be `current`: a Stop, or the
    /// system finishing first). No other call starts while it is set.
    private(set) var callInFlight: Pack?
    /// A lost call given up on (it never returned): the queue went on
    /// beside it. Cleared when it finally returns. At most one.
    private(set) var abandonedCall: Pack?
    /// Calls abandoned this launch (Diagnostics).
    private(set) var abandonedCount = 0
    /// Why the current request waits instead of being asked (nil: it isn't).
    private(set) var parkedFor: ParkReason?
    /// The app is in the foreground (`didBecomeActive` … `didEnterBackground`).
    private(set) var isActive = true
    /// The device has a network path (real launches follow `Connectivity`;
    /// the fakes have no network to lose).
    private(set) var online = true
    /// The last time the states were recomputed from the system.
    private(set) var lastSync: Date?

    nonisolated enum ParkReason: String, Sendable { case background = "waiting for the app", offline = "waiting for a connection" }

    @ObservationIgnored private var handlers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var system: (any PackSystem)?
    @ObservationIgnored private let tuning: Tuning
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var currentToken: UUID?
    @ObservationIgnored private var attempt: Attempt?
    /// Completes when the in-flight system call has returned.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var inFlightID: UUID?
    /// The abandoned call's task, kept so it is referenced until it returns
    /// (its attempt is already settled: settling is once only).
    @ObservationIgnored private var abandonedTask: Task<Void, Never>?
    @ObservationIgnored private var abandonedID: UUID?
    /// Stops/Removes the system hasn't finished (each gives up after
    /// `removalTimeout`): no call starts meanwhile.
    @ObservationIgnored private var removals: Set<UUID> = []
    /// Per-call grace timers (a call the store stopped waiting for).
    @ObservationIgnored private var graceTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var ticksThisPack = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Resume tapped while the current pack waits (a retry, the app): go now.
    @ObservationIgnored private var cutWait = false
    /// Bumped on every `didEnterBackground`: a call that spans one may have
    /// been cut off by the suspension.
    @ObservationIgnored private var backgroundEpoch = 0
    /// The process is kept running in the background by a
    /// continued-processing task (ours or the areas'): calls aren't cut off.
    @ObservationIgnored private var keptAlive: @MainActor () -> Bool = { AreaBackgroundTask.anyRunning }

    private func isKeptAlive() -> Bool { background?.isRunning == true || keptAlive() }
    @ObservationIgnored private var connectivity: Connectivity.Subscription?
    /// The last status event (or request) per pack, for staleness.
    @ObservationIgnored private var lastEvent: [Pack: ContinuousClock.Instant] = [:]
    /// What the system called local at the last refresh.
    @ObservationIgnored private var lastSystemLocal: Set<Pack> = []
    /// Packs stopped from Storage: status events still in flight for them
    /// (`downloading`, `paused`, `failed`) are ignored until a new fetch,
    /// so a stopped row can't flip back to "Downloading".
    @ObservationIgnored private var stopped: Set<Pack> = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var manifest: [Pack: PackManifestEntry] = [:]
    /// The system's progress UI for a long queue (`BGContinuedProcessingTask`).
    @ObservationIgnored private var background: (any ContinuedWork)?
    /// The packs the running background task covers, and those done.
    @ObservationIgnored private var run: (packs: [Pack], done: Set<Pack>) = ([], [])
    /// The task's progress never goes back (high-water mark, bytes) …
    @ObservationIgnored private var progressHigh = 0
    /// … and while nothing moves, it hears a tick (one byte each) so the
    /// scheduler doesn't take it for stalled.
    @ObservationIgnored private var progressTicks = 0
    @ObservationIgnored private var lastBeatValue = -1
    /// The checkpoint was read: before that, writing it would erase it.
    @ObservationIgnored private var queueRestored = false
    @ObservationIgnored private var refreshCount = 0
    @ObservationIgnored private var refreshApplied = 0
    /// The server's manifest was read (`manifest` is then the whole list).
    private(set) var manifestLoaded = false
    /// Why the manifest couldn't be read (Diagnostics).
    private(set) var manifestError: String?
    /// Each pack's recent errors, raw, with their time (Diagnostics).
    private(set) var errorLog: [Pack: [ErrorRecord]] = [:]
    /// The last integrity verdict of each pack the system has, when one was
    /// run this launch (a pass cached from an earlier launch has none).
    /// A damaged pack counts as missing: its archives never reach the map.
    private(set) var integrity: [Pack: PackIntegrity.Report] = [:]
    /// Damaged packs being replaced: removed from the system, then asked
    /// for again through the queue (the row: "Repairing — downloading again").
    private(set) var repairing: Set<Pack> = []
    /// Verdicts this launch, by input signature (path, size, date of each file).
    @ObservationIgnored private var verdicts: [String: PackIntegrity.Report] = [:]
    /// The failure (signature) each repair was started for: one repair per failure.
    @ObservationIgnored private var repairedFailures: [Pack: String] = [:]
    /// A repair refused for lack of space: the row says how much to free
    /// (until the files change or a Retry).
    private(set) var repairBlocked: [Pack: String] = [:]
    @ObservationIgnored private var blockedFailure: [Pack: String] = [:]
    /// The damaged packs now, by failure signature (from the last refresh).
    @ObservationIgnored private var damagedNow: [Pack: String] = [:]
    /// First damaged look per pack; a repair waits for a second one.
    @ObservationIgnored private var suspects: [Pack: Suspect] = [:]
    @ObservationIgnored private var confirmTasks: [Pack: Task<Void, Never>] = [:]
    /// Packs a tap asked to repair (past the automatic cap).
    @ObservationIgnored private var userRepairs: Set<Pack> = []
    /// Free space for a repair (tests inject it).
    @ObservationIgnored private var freeSpace: @Sendable () -> Int64? = {
        (try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
    /// Found damaged before the checkpointed queue was read (boot).
    @ObservationIgnored private var pendingRepairs: [Pack] = []
    /// Queue turns (tokens) that already removed their damaged pack.
    @ObservationIgnored private var repairRemoved: Set<UUID> = []
    /// The last resolution (Diagnostics re-checks its files).
    @ObservationIgnored private(set) var lastFound: PackResolution?
    /// Automatic repairs per pack and server version, across launches,
    /// before it shows as failed (a Retry, or a new version, resets it).
    static let maxRepairs = 2
    /// [pack ID: [server version (-1 unknown), repairs]] (UserDefaults).
    nonisolated static let repairsKey = "packRepairAttempts"
    /// Signatures that passed, per pack ID (UserDefaults): a pack version is checked once.
    nonisolated static let integrityKey = "packIntegrityPassed"
    /// Catalogue refreshes this launch (Diagnostics).
    private(set) var catalogueLog: [String] = []
    /// Set at launch when the process can't use Background Assets (no app
    /// group in its signature): no packs, and the manager is never touched.
    private(set) var backgroundAssetsUnavailable = false
    #if DEBUG
    @ObservationIgnored private var fake: FakePacks?
    #endif
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Packs")
    /// Where the queue is checkpointed (pack IDs, current first).
    nonisolated static let queueKey = "packQueue"
    /// The fake store's own key: a UI test's queue never reaches a real launch.
    @ObservationIgnored private var queueKey = PackStore.queueKey

    private init(mode: Mode, location: DataLocation, states: [Pack: PackState], system: (any PackSystem)? = nil,
                 tuning: Tuning = Tuning(), defaults: UserDefaults = .standard, background: (any ContinuedWork)? = nil) {
        self.mode = mode
        self.location = location
        self.states = states
        self.seasonProbes = SeasonProbes(location: location)
        self.system = system
        self.tuning = tuning
        self.defaults = defaults
        self.background = background
        background?.onExpire = { [weak self] in self?.backgroundExpired() }
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
            let store = PackStore(fake: FakePacks(spec: spec, directory: dir, seconds: seconds > 0 ? seconds : 4))
            store.observeLifecycle()
            return store
        }
        if let path = defaults.string(forKey: DataLocator.dataDirectoryKey), !path.isEmpty {
            let location = DataLocator.locate(debugDirectory: path)
            let dir = URL(filePath: path, directoryHint: .isDirectory)
            // `-dataDirArrivesAfter <seconds>`: start empty, then "install"
            // the directory's archives — a pack arriving while the app runs
            // (exercises the style and thumbnail hooks without Background Assets)
            let delay = defaults.double(forKey: "dataDirArrivesAfter")
            guard delay > 0 else {
                return PackStore(mode: .debugDirectory(dir), location: location, states: debugStates(location, dir: dir))
            }
            let empty = DataLocation(origin: .debugDirectory(dir), archives: [:])
            let store = PackStore(mode: .debugDirectory(dir), location: empty, states: states(for: empty))
            Task { [weak store] in
                try? await Task.sleep(for: .seconds(delay))
                store?.states = debugStates(location, dir: dir)
                store?.publish(location)
            }
            return store
        }
        #endif
        let store = PackStore(mode: .assetPacks, location: DataLocation(origin: .assetPacks, archives: [:]),
                              states: Dictionary(uniqueKeysWithValues: Pack.allCases.map { ($0, .notInstalled) }),
                              defaults: defaults, background: AreaBackgroundTask.forPacks())
        store.isResolved = false
        store.isActive = UIApplication.shared.applicationState != .background
        // offline: a failed request waits for a path instead of using its
        // retries (and being dropped from the checkpoint)
        store.online = Connectivity.shared.online
        store.connectivity = Connectivity.shared.observe { [weak store] up in store?.setOnline(up) }
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
                // a tap before this (Get all) may have begun the system task
                if store?.background?.isRunning == true { store?.background?.end(success: false) }
                store?.queue = []
                return
            }
            guard let store else { return }
            store.system = ApplePackSystem()
            store.observeLifecycle()
            await store.boot(autoFetchCore: true, restoreQueue: true, hooks: true) {
                logger.info("launch: \(store.states.filter { $0.value.isInstalled }.keys.map(\.rawValue).sorted(), privacy: .public) installed (\(start.duration(to: .now), privacy: .public))")
            }
        }
        return store
    }

    #if DEBUG
    /// Unit tests: the Background Assets store over a fake system, booted
    /// (states from the system, the checkpointed queue resumed).
    static func testing(system: FakePackSystem, defaults: UserDefaults, tuning: Tuning,
                        background: (any ContinuedWork)? = nil, autoFetchCore: Bool = false,
                        keptAlive: @escaping @MainActor () -> Bool = { false }, online: Bool = true,
                        freeSpace: @escaping @Sendable () -> Int64? = { 1 << 50 }) async -> PackStore {
        let store = PackStore(mode: .assetPacks, location: DataLocation(origin: .assetPacks, archives: [:]),
                              states: Dictionary(uniqueKeysWithValues: Pack.allCases.map { ($0, .notInstalled) }),
                              system: system, tuning: tuning, defaults: defaults, background: background)
        store.keptAlive = keptAlive
        store.freeSpace = freeSpace
        store.online = online
        store.isResolved = false
        await store.boot(autoFetchCore: autoFetchCore, restoreQueue: true, hooks: false)
        return store
    }

    /// Tests: the network path came or went.
    func simulateConnectivity(_ up: Bool) { setOnline(up) }
    #endif

    /// Ends everything the store runs (tests: one store per test). Not for
    /// the app's own store, which lives as long as the process.
    func shutdown() {
        statusTask?.cancel()
        for task in lifecycleTasks { task.cancel() }
        watchTask?.cancel()
        heartbeatTask?.cancel()
        recheckTask?.cancel()
        for task in confirmTasks.values { task.cancel() }
        confirmTasks = [:]
        for task in graceTasks { task.cancel() }
        runner?.cancel()
        queue = []
        current = nil
        currentToken = nil
        attempt?.settle(.failure(CancellationError()))
        connectivity = nil
        wake()
    }

    /// The first look at the system, the checkpointed queue (read before
    /// anything can write it), then the event stream and the manifest.
    private func boot(autoFetchCore: Bool, restoreQueue: Bool, hooks: Bool, resolved: () -> Void = {}) async {
        guard let system else { return }
        // first: nothing on the main actor may touch the manager before this
        await refresh()
        if restoreQueue { self.restoreQueue() } else { queueRestored = true }
        isResolved = true
        resolved()
        if !pendingRepairs.isEmpty {
            enqueue(pendingRepairs, user: false)
            pendingRepairs = []
        }
        // a reader found a pack damaged (the plant-ID load): look again now
        lifecycleTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: PackVerification.damagedNotification) {
                guard let id = note.object as? String, let pack = Pack(rawValue: id) else { continue }
                await self?.reportDamaged(pack)
            }
        })
        await syncDownloads()
        let stream = await system.events()
        statusTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        runQueue()
        #if DEBUG
        // simulated offline: the manifest refresh would go to Apple's servers
        if DebugNetwork.simulatedOffline, !(system is FakePackSystem) { return }
        #endif
        await loadManifest()
        // a pack we expect but the catalogue doesn't list: the device's
        // copy may predate an upload — ask the server once
        if manifestLoaded, let unknown = Pack.allCases.first(where: { manifest[$0] == nil }) {
            await refreshCatalogue(reason: "launch: \(unknown.rawValue) not in the catalogue")
        }
        // Core packs are the system's job, but "network dropouts or other
        // uncommon issues can prevent the system from downloading [even
        // an essential pack] until you call ensureLocalAvailability"
        // (Apple, "Downloading Apple-hosted asset packs").
        // One the system is downloading by itself isn't asked for: the queue
        // would hold every Get behind a 2 GB prefetch (if it stalls, the
        // stale-download check asks for it).
        if autoFetchCore {
            enqueue(Pack.allCases.filter {
                guard $0.policy != .onDemand, !state($0).isInstalled, manifest[$0] != nil else { return false }
                if case .downloading = state($0) { return false }
                return true
            }, user: false)
        }
        guard hooks else { return }
        // test hook (all builds; only reachable through launch
        // arguments): `-fetchPacks season-2021,aerial`, `-removePacks …`
        for id in Self.ids(defaults.string(forKey: "removePacks")) { await remove(id) }
        fetch(Self.ids(defaults.string(forKey: "fetchPacks")))
    }

    func state(_ pack: Pack) -> PackState { states[pack] ?? .notInstalled }

    /// Its place in the queue (1 = next), nil when it isn't waiting.
    func queuePosition(_ pack: Pack) -> Int? { queue.firstIndex(of: pack).map { $0 + 1 } }

    /// The server's version of each pack it offers (Diagnostics).
    var manifestVersions: [Pack: Int] { manifest.mapValues(\.version) }

    /// Whether this store talks to the real Background Assets (Diagnostics
    /// may then ask the system about each pack).
    var usesBackgroundAssets: Bool { mode == .assetPacks && system is ApplePackSystem && !backgroundAssetsUnavailable }

    /// Whether `fetch`/`remove` do anything here (Background Assets, or the
    /// DEBUG fake). A developer's `-dataDir` folder is read as it is.
    var canFetch: Bool { managesPacks }

    /// A system to ask (Background Assets with a usable manager, or the
    /// fake) — or about to be: a tap in the first moments after launch
    /// joins the queue, which runs once the system is known.
    private var managesPacks: Bool {
        !backgroundAssetsUnavailable && (system != nil || (mode == .assetPacks && !isResolved))
    }

    /// The running continued-processing task (Diagnostics).
    var backgroundTaskRunning: Bool { background?.isRunning ?? false }

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

    /// Downloads an on-demand pack (or retries a core pack) — a tap: it
    /// joins the queue (core packs at its front), the system downloads it
    /// and keeps going in the background; `states` follows.
    func fetch(_ pack: Pack) { fetch([pack]) }

    /// Several packs, in this order ("Get all": newest season first). A tap:
    /// a long queue gets the system's progress UI.
    func fetch(_ packs: [Pack]) { enqueue(packs, user: true) }

    /// `user`: asked for by a tap (only a tap may start a continued-processing
    /// task — she may have ended the last one herself).
    private func enqueue(_ packs: [Pack], user: Bool) {
        guard managesPacks else { return }
        // a tap on a damaged pack (Retry): repaired again, past the cap
        if user { for pack in packs where damagedNow[pack] != nil { resetRepair(pack) } }
        let wanted = packs.filter { !state($0).isInstalled && $0 != current && !queue.contains($0) }
        if user { considerBackgroundTask(adding: wanted) }
        guard !wanted.isEmpty else { return }
        for pack in wanted {
            stopped.remove(pack)
            retries[pack] = 0
        }
        let core = wanted.filter { $0.policy != .onDemand }
        queue.insert(contentsOf: core, at: 0)
        queue.append(contentsOf: wanted.filter { $0.policy == .onDemand })
        checkpoint()
        updateBackground()
        runQueue()
    }

    /// A paused or waiting download, asked for again (the row's Resume).
    /// The current pack: the row says so at once, and a request waiting for
    /// its retry (or the app) goes now — but a call still in flight is
    /// never doubled: the system carries that download on by itself.
    func resume(_ pack: Pack) {
        guard managesPacks, !state(pack).isInstalled else { return }
        retries[pack] = 0
        considerBackgroundTask(adding: owned(pack) ? [] : [pack])
        if pack == current {
            if case .paused = state(pack) { states[pack] = .downloading(nil) }
            // its own call still out: never doubled; otherwise (a retry
            // wait, parked) it goes now — once the gate is open
            if !(callInFlight == pack && attempt?.isPending == true) {
                cutWait = true
                wake()
            }
        } else if let i = queue.firstIndex(of: pack) {
            queue.remove(at: i)
            queue.insert(pack, at: 0)
            checkpoint()
        } else {
            stopped.remove(pack)
            queue.insert(pack, at: 0)
            checkpoint()
            runQueue()
        }
    }

    /// Removes an on-demand pack (or stops its download, or takes it out of
    /// the queue). Its archives leave the style FIRST, so MapLibre and the
    /// season probes let go of the files, then the system deletes them. No
    /// other request starts before the system is done with the removal.
    func remove(_ pack: Pack) async {
        guard managesPacks, pack.isRemovable else { return }
        // Stop as much as Remove: late events of this download are ignored
        stopped.insert(pack)
        queue.removeAll { $0 == pack }
        if current == pack {
            current = nil
            currentToken = nil
            attempt?.settle(.failure(CancellationError()))
        }
        retries[pack] = nil
        updates[pack] = nil
        // a stopped pack is no part of the background task's success
        run.packs.removeAll { $0 == pack }
        run.done.remove(pack)
        checkpoint()
        wake()
        let removalID = UUID()
        removals.insert(removalID)
        // the gate never waits for ever on a removal iOS doesn't answer
        graceTasks.append(Task { [weak self, tuning] in
            try? await Task.sleep(for: tuning.removalTimeout)
            guard !Task.isCancelled, let self, self.removals.contains(removalID) else { return }
            Self.logger.fault("\(pack.rawValue, privacy: .public): remove not answered; the queue goes on")
            self.removals.remove(removalID)
            self.wake()
        })
        let task = Task { [weak self] in await self?.removeFromSystem(pack) }
        await task.value
        removals.remove(removalID)
        wake()
        updateBackground()
        queueDrained()
    }

    private func removeFromSystem(_ pack: Pack) async {
        var shown = location.archives
        for archive in pack.archives { shown[archive] = nil }
        publish(DataLocation(origin: location.origin, archives: shown))
        // one run-loop turn: the style rebuild drops the source first
        try? await Task.sleep(for: .milliseconds(300))
        guard let system else { return }
        do {
            try await system.remove(pack.rawValue)
            Self.logger.info("\(pack.rawValue, privacy: .public): removed")
        } catch {
            Self.logger.error("\(pack.rawValue, privacy: .public): remove failed: \(String(describing: error), privacy: .public)")
        }
        await refresh()
        // a download stopped from Storage: `refresh` only clears installed
        // packs, and a stopped one's late events are ignored
        if !state(pack).isInstalled, !owned(pack) { states[pack] = .notInstalled }
    }

    // MARK: Queue

    /// One request at a time, in order: `process` each pack until it is
    /// here, failed for good, unpublished or stopped.
    private func runQueue() {
        guard runner == nil, system != nil, isResolved, current != nil || !queue.isEmpty else { return }
        runner = Task { [weak self] in
            while !Task.isCancelled, let store = self, let next = store.pickNext() {
                await store.process(next.pack, token: next.token)
            }
            self?.runner = nil
            self?.queueDrained()
        }
    }

    private func pickNext() -> (pack: Pack, token: UUID)? {
        if let current, let currentToken { return (current, currentToken) }
        guard !queue.isEmpty else { return nil }
        let pack = queue.removeFirst()
        let token = UUID()
        current = pack
        currentToken = token
        cutWait = false
        ticksThisPack = 0
        checkpoint()
        updateBackground()
        return (pack, token)
    }

    private func owns(_ pack: Pack, _ token: UUID) -> Bool { current == pack && currentToken == token }

    /// Ours to download: in flight or waiting.
    private func owned(_ pack: Pack) -> Bool { current == pack || queue.contains(pack) }

    /// The previous call (any pack) has returned and no removal is under
    /// way: only then may a call start.
    private func gateCalls() async {
        while inFlight != nil || !removals.isEmpty, !Task.isCancelled {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Runs the current pack's request until it settles one way or another.
    private func process(_ pack: Pack, token: UUID) async {
        var catalogueRefreshed = false
        var reattached = 0
        while owns(pack, token), !Task.isCancelled {
            await gateCalls()
            // the system's word first: maybe it's here already
            await refresh()
            guard owns(pack, token) else { return }
            if state(pack).isInstalled { return finish(pack, token) }
            // damaged files the system calls downloaded: removed first (a
            // request would return at once with the same files) — once per
            // turn; still there after that, iOS kept them: say so
            if let failure = damagedNow[pack], lastSystemLocal.contains(pack) {
                guard !repairRemoved.contains(token) else {
                    Self.logger.error("\(pack.rawValue, privacy: .public): damaged files still there after the removal")
                    states[pack] = .failed(Self.damaged)
                    return drop(pack, token)
                }
                // a second look first (the confirmation's refresh marks it)
                guard suspects[pack]?.signature == failure, suspects[pack]?.confirmed == true else {
                    await wait(tuning.repairConfirmAfter, pack, token)
                    continue
                }
                if !userRepairs.contains(pack), repairsUsed(pack) >= Self.maxRepairs {
                    states[pack] = .failed(Self.damaged)
                    return drop(pack, token)
                }
                // a download or update of it under way: not now
                if let system, await system.localStatus(pack.rawValue).downloading || updates[pack] != nil {
                    await wait(tuning.repairConfirmAfter, pack, token)
                    continue
                }
                guard owns(pack, token) else { return }
                // the removal frees its space only once the new copy can't
                // fit — never delete what can't be downloaded again
                let need = Int64(size(pack)) + tuning.repairMargin
                if let free = freeSpace(), free < need {
                    let message = "Not enough space to repair — free \(StorageText.size(Int(need - free)))"
                    Self.logger.error("\(pack.rawValue, privacy: .public): \(message, privacy: .public) (\(free) bytes free)")
                    blockedFailure[pack] = failure
                    repairBlocked[pack] = message
                    states[pack] = .failed(message)
                    return drop(pack, token)
                }
                repairRemoved.insert(token)
                repairedFailures[pack] = failure
                userRepairs.remove(pack)
                noteRepair(pack)
                if pack == .plantid {
                    // Core ML lets go of the model's files first
                    PlantIDRelease.releaseAll()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                await removeForRepair(pack)
                continue
            }
            switch states[pack] {
            case .downloading?, .paused?: break
            default: states[pack] = .downloading(nil)
            }
            lastEvent[pack] = .now
            let epoch = backgroundEpoch
            do {
                try await request(pack)
                guard owns(pack, token) else { return }
                await refresh()
                if state(pack).isInstalled { return finish(pack, token) }
                // downloaded again, and again cut short (the space ran out
                // again?): this turn ends; a new failure gets its own repair
                if damagedNow[pack] != nil, lastSystemLocal.contains(pack) {
                    Self.logger.error("\(pack.rawValue, privacy: .public): downloaded again, still damaged: \(self.integrity[pack]?.summary ?? "", privacy: .public)")
                    states[pack] = .failed(Self.damaged)
                    return drop(pack, token)
                }
                // "available" (the call returns at once for a local pack) but
                // its files don't open: retrying the call can't help — say
                // so, and look again shortly (a move in progress?)
                if outdated.contains(pack) {
                    // the call answers at once for the older version: the
                    // update arrives through the status stream
                    if case .downloading = states[pack] {} else { states[pack] = .downloading(nil) }
                    drop(pack, token)
                    return
                }
                if lastSystemLocal.contains(pack) {
                    Self.logger.error("\(pack.rawValue, privacy: .public): available but its archives aren't readable")
                    noteError(pack, PackStoreError.unreadable, stage: "request")
                    states[pack] = .failed(Self.unreadable)
                    drop(pack, token)
                    return scheduleRechecks()
                }
                throw PackStoreError.notLocal
            } catch {
                guard owns(pack, token) else { return }
                noteError(pack, error, stage: "request")
                // the system's word before any verdict: a request that
                // failed or was cut off may still have left the pack here
                await refresh()
                guard owns(pack, token) else { return }
                if state(pack).isInstalled { return finish(pack, token) }
                // offline (also "no such pack" offline: the catalogue can't be
                // asked): nothing failed — wait for a path, no retry used
                // the path monitor's "offline" may still be on its way
                if online { await wait(tuning.offlineRecheck, pack, token) }
                guard owns(pack, token) else { return }
                if !online {
                    Self.logger.notice("\(pack.rawValue, privacy: .public): offline; waiting for a connection")
                    await park(.offline, pack, token) { self.online }
                    continue
                }
                // cut off by a suspension (the app went to the background
                // during the call, nothing kept the process running): ask
                // again once she is back, no retry used
                if !isKeptAlive(), epoch != backgroundEpoch || !isActive {
                    Self.logger.notice("\(pack.rawValue, privacy: .public): interrupted in the background; asking again in the foreground")
                    await park(.background, pack, token) { self.isActive || self.isKeptAlive() }
                    continue
                }
                if Self.isNotFound(error) {
                    // "no such pack": the device's catalogue may predate the
                    // upload. Ask the server once (`checkForUpdates`, the
                    // documented way to get the latest asset-pack
                    // information unconditionally), then try again.
                    if !catalogueRefreshed {
                        catalogueRefreshed = true
                        await refreshCatalogue(reason: "\(pack.rawValue) not found")
                        continue
                    }
                    states[pack] = .unpublished
                    return drop(pack, token)
                }
                // still downloading in the system: attach again, no retry used
                if let system, reattached < tuning.freeReattaches, await system.localStatus(pack.rawValue).downloading {
                    reattached += 1
                    await wait(tuning.retryDelays.first ?? .seconds(2), pack, token)
                    continue
                }
                let used = retries[pack] ?? 0
                guard used < tuning.retryDelays.count else {
                    Self.logger.error("\(pack.rawValue, privacy: .public): giving up after \(used) retries: \(String(describing: error), privacy: .public)")
                    states[pack] = .failed(Self.message(error))
                    return drop(pack, token)
                }
                retries[pack] = used + 1
                let delay = tuning.retryDelays[used]
                retryAt = Date.now.addingTimeInterval(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
                Self.logger.notice("\(pack.rawValue, privacy: .public): retry \(used + 1) in \(delay, privacy: .public)")
                await wait(delay, pack, token)
                retryAt = nil
            }
        }
    }

    /// Sleeps `delay` unless the pack stops being the current one, or a
    /// Resume cuts it short (one tapped before the wait began counts too).
    private func wait(_ delay: Duration, _ pack: Pack, _ token: UUID) async {
        let end = ContinuousClock.now + delay
        while owns(pack, token), !cutWait, !Task.isCancelled, ContinuousClock.now < end {
            try? await Task.sleep(for: min(tuning.pollInterval, ContinuousClock.now.duration(to: end)))
        }
        cutWait = false
    }

    /// Waits (no polling) until `ready`, a Stop, or a Resume.
    private func park(_ reason: ParkReason, _ pack: Pack, _ token: UUID, until ready: () -> Bool) async {
        parkedFor = reason
        updateBackground()
        // offline in the background: nothing will move — the system task
        // ends now (the checkpoint resumes the queue), never kept alive
        if reason == .offline, !isActive, let background, background.isRunning {
            Self.logger.notice("offline in the background: ending the pack task")
            background.end(success: false)
            endRun()
            checkpoint()
        }
        while owns(pack, token), !ready(), !cutWait, !Task.isCancelled {
            await withCheckedContinuation { waiters.append($0) }
        }
        cutWait = false
        parkedFor = nil
    }

    private func wake() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }

    /// One `ensureLocalAvailability` call. The store may stop waiting for
    /// it early (Stop, the system's own `finished`), but the call stays THE
    /// in-flight one until it returns: `gateCalls` holds the next back. (A
    /// Swift cancellation doesn't reach the system's call, so it runs in a
    /// task of its own.)
    private func request(_ pack: Pack) async throws {
        guard let system else { throw CancellationError() }
        let attempt = Attempt()
        self.attempt = attempt
        defer { if self.attempt === attempt { self.attempt = nil } }
        let id = pack.rawValue
        let call = Task.detached { () -> Result<Void, any Error> in
            do {
                try await system.ensureLocalAvailability(id)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let callID = UUID()
        callInFlight = pack
        inFlightID = callID
        inFlight = Task { [weak self] in
            let result = await call.value
            attempt.settle(result)
            guard let self else { return }
            if self.inFlightID == callID {
                self.inFlight = nil
                self.inFlightID = nil
                self.callInFlight = nil
            }
            if self.abandonedID == callID {
                Self.logger.notice("\(pack.rawValue, privacy: .public): the abandoned call returned at last")
                self.abandonedTask = nil
                self.abandonedID = nil
                self.abandonedCall = nil
            }
            self.wake()
        }
        watch(pack, attempt)
        do {
            try await attempt.value()
        } catch {
            graceIfStillOut(callID)
            throw error
        }
        graceIfStillOut(callID)
        Self.logger.info("\(pack.rawValue, privacy: .public): available locally")
    }

    /// The store stopped waiting for a call that hasn't returned (Stop, the
    /// pack found installed, the watchdog): it stays THE in-flight call for
    /// `abandonGrace`, then it is abandoned — unless another abandoned call
    /// is still out, then it waits for that one first.
    private func graceIfStillOut(_ callID: UUID) {
        guard inFlightID == callID else { return }
        graceTasks.removeAll { $0.isCancelled }
        graceTasks.append(Task { [weak self, tuning] in
            try? await Task.sleep(for: tuning.abandonGrace)
            while !Task.isCancelled, let self, self.inFlightID == callID {
                if self.abandon(callID) { return }
                try? await Task.sleep(for: tuning.watchInterval)
            }
        })
    }

    /// The watchdog. A request whose pack the system neither downloads nor
    /// has, with no event for a while, is lost (Diagnostics showed
    /// "downloading 79 %" here while the system had nothing: local status
    /// []). The store stops waiting for it and asks again — after the lost
    /// call returned, or was abandoned (`graceIfStillOut`). To make it
    /// return, a pack the system has nothing of is removed (that loses
    /// nothing; a core pack can't be removed). Bounded in every case: paused
    /// packs after a longer threshold, "downloading" with no event for
    /// `silentDownloadAfter`, and "downloaded" whose files don't resolve
    /// like a lost call (never removed — its files are there).
    private func watch(_ pack: Pack, _ attempt: Attempt) {
        watchTask?.cancel()
        watchTask = Task { [weak self, tuning] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tuning.watchInterval)
                guard !Task.isCancelled, let self, attempt.isPending, let system = self.system else { return }
                guard self.isActive || self.isKeptAlive(), self.online else { continue }
                let status = await system.localStatus(pack.rawValue)
                if status.downloaded {
                    // here, whatever the call says (refresh settles it)
                    await self.refresh()
                    guard attempt.isPending else { return }
                }
                let limit: Duration
                if status.downloaded { limit = tuning.stallAfter }
                else if status.downloading { limit = tuning.silentDownloadAfter }
                else if self.state(pack) == .paused { limit = tuning.pausedStallAfter }
                else { limit = tuning.stallAfter }
                guard self.quiet(pack, for: limit), attempt.started.duration(to: .now) >= limit else { continue }
                let removable = pack.isRemovable && !status.downloading && !status.downloaded
                Self.logger.notice("\(pack.rawValue, privacy: .public): request lost (system: downloading \(status.downloading), downloaded \(status.downloaded)); asking again")
                if removable {
                    let id = pack.rawValue
                    Task.detached { try? await system.remove(id) }
                }
                attempt.settle(.failure(PackStoreError.stalled))
                return
            }
        }
    }

    /// Gives up on the in-flight call `callID` (see `Tuning.abandonGrace`).
    private func abandon(_ callID: UUID) -> Bool {
        guard inFlightID == callID, let inFlight, abandonedTask == nil else { return false }
        let pack = callInFlight
        Self.logger.fault("\(pack?.rawValue ?? "?", privacy: .public): call still not back after the grace period; abandoned — the queue goes on")
        abandonedTask = inFlight
        abandonedID = inFlightID
        abandonedCall = pack
        abandonedCount += 1
        self.inFlight = nil
        inFlightID = nil
        callInFlight = nil
        if let pack { noteError(pack, PackStoreError.abandoned, stage: "grace period") }
        wake()
        return true
    }

    private func quiet(_ pack: Pack, for duration: Duration) -> Bool {
        guard let last = lastEvent[pack] else { return true }
        return last.duration(to: .now) >= duration
    }

    private func finish(_ pack: Pack, _ token: UUID) {
        guard owns(pack, token) else { return }
        retries[pack] = nil
        repairing.remove(pack)
        repairRemoved.remove(token)
        run.done.insert(pack)
        current = nil
        currentToken = nil
        checkpoint()
        updateBackground()
    }

    private func drop(_ pack: Pack, _ token: UUID) {
        guard owns(pack, token) else { return }
        repairing.remove(pack)
        repairRemoved.remove(token)
        current = nil
        currentToken = nil
        checkpoint()
        updateBackground()
    }

    private func queueDrained() {
        guard current == nil, queue.isEmpty, let background, background.isRunning else { return }
        let all = run.packs.allSatisfy { state($0).isInstalled }
        background.end(success: all)
        endRun()
    }

    /// The queue as it stands, for the next launch (a kill, an expired
    /// background task): pack IDs, the current one first. Never before the
    /// last one was read.
    private func checkpoint() {
        guard queueRestored else { return }
        let ids = ([current].compactMap { $0 } + queue).map(\.rawValue)
        if ids.isEmpty { defaults.removeObject(forKey: queueKey) } else { defaults.set(ids, forKey: queueKey) }
    }

    private func restoreQueue() {
        defer {
            queueRestored = true
            checkpoint()
        }
        let ids = defaults.stringArray(forKey: queueKey) ?? []
        let packs = ids.compactMap(Pack.init(rawValue:)).filter { !state($0).isInstalled && state($0) != .unpublished }
        guard !packs.isEmpty else { return }
        Self.logger.info("resuming the queue: \(packs.map(\.rawValue), privacy: .public)")
        for pack in packs where !owned(pack) && !stopped.contains(pack) { queue.append(pack) }
    }

    // MARK: Background task

    /// A tap that leaves two or more packs to get, or one of 1 GB or more,
    /// runs the queue inside a `BGContinuedProcessingTask`, so it carries on
    /// while she uses other apps (the system's progress UI: "Downloading
    /// maps", the pack, the bytes across the queue). Only a tap starts one
    /// (it must come from the foreground, and she may have ended the last
    /// one herself); a running one takes the new packs in.
    private func considerBackgroundTask(adding new: [Pack]) {
        guard let background else { return }
        if background.isRunning {
            run.packs.append(contentsOf: new.filter { !run.packs.contains($0) })
            return
        }
        guard isActive else { return }
        let packs = [current].compactMap { $0 } + queue + new.filter { !owned($0) }
        guard packs.count >= 2 || packs.contains(where: { size($0) >= 1_000_000_000 }) else { return }
        run = (packs, [])
        progressHigh = 0
        progressTicks = 0
        lastBeatValue = -1
        guard background.begin(title: "Downloading maps", subtitle: subtitle()) else {
            run = ([], [])
            return
        }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, tuning] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tuning.heartbeat)
                guard !Task.isCancelled, let self, self.background?.isRunning == true else { return }
                self.beat()
            }
        }
    }

    private func subtitle() -> String {
        guard let pack = current ?? queue.first ?? run.packs.first(where: { !state($0).isInstalled }) else { return "" }
        var line = pack.storageTitle
        if current == pack {
            if let parkedFor { line += " · \(parkedFor == .offline ? "waiting for a connection" : "waiting")" }
            else if retryAt != nil { line += " · retrying soon" }
            else if state(pack) == .downloading(nil) { line += " · waiting to start" }
        }
        let more = Set(queue + run.packs.filter { !state($0).isInstalled && !run.done.contains($0) }).subtracting([pack]).count
        return more == 0 ? line : "\(line) · \(more) more"
    }

    private func size(_ pack: Pack) -> Int { downloadSizes[pack] ?? PackSizes.nominal[pack] ?? 0 }

    private func updateBackground() {
        guard let background, background.isRunning else { return }
        let total = run.packs.reduce(0) { $0 + size($1) }
        var done = run.packs.filter { run.done.contains($0) || state($0).isInstalled }.reduce(0) { $0 + size($1) }
        if let current, run.packs.contains(current), !run.done.contains(current), case let .downloading(f?) = state(current) {
            done += Int(Double(size(current)) * min(max(f, 0), 1))
        }
        // never backwards: a pause, a fresh "began", a give-up or a Stop
        // don't take bytes off the bar
        progressHigh = max(progressHigh, done)
        background.update(done: progressHigh + progressTicks, total: max(total, progressHigh) + progressTicks,
                          title: "Downloading maps", subtitle: subtitle())
    }

    /// Nothing moved since the last beat (a retry wait, the watchdog's
    /// window, "waiting to start"): a tick and the current words, so the
    /// task never looks stalled to the scheduler.
    private func beat() {
        // parked (offline, waiting for the app): no signal — no tick either
        guard parkedFor == nil else { return }
        if progressHigh == lastBeatValue, ticksThisPack < tuning.maxTicksPerPack {
            progressTicks += 1
            ticksThisPack += 1
        }
        lastBeatValue = progressHigh
        updateBackground()
    }

    private func endRun() {
        run = ([], [])
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// The system ends the task (time's up, or she stopped it from its
    /// Live Activity): the queue is checkpointed and carries on as usual —
    /// without the task; only her next Get / Get all / Resume asks for one.
    /// The system's download itself isn't ours to stop.
    private func backgroundExpired() {
        Self.logger.notice("pack task ended by the system; the queue carries on without it")
        endRun()
        checkpoint()
    }

    // MARK: App lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleTasks.append(Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didBecomeActiveNotification) {
                self?.appBecameActive()
            }
        })
        lifecycleTasks.append(Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.appEnteredBackground()
            }
        })
    }

    /// Back in the foreground: the states from the system again (it may
    /// have finished, or still be downloading, out of process), then the
    /// queue carries on. (No continued-processing task is asked for here:
    /// this also fires after Control Center, Face ID, a notification.)
    func appBecameActive() {
        isActive = true
        wake()
        Task { await resync() }
    }

    func appEnteredBackground() {
        isActive = false
        backgroundEpoch += 1
        checkpoint()
    }

    private func setOnline(_ up: Bool) {
        guard up != online else { return }
        online = up
        // a flapping connection never adds up to "Didn't finish"
        if up { for pack in [current].compactMap({ $0 }) + queue { retries[pack] = 0 } }
        wake()
        if up { Task { await resync() } }
    }

    // MARK: Background Assets

    private static func ids(_ list: String?) -> [Pack] {
        (list ?? "").split(separator: ",").compactMap { Pack(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    private func handle(_ event: PackSystemEvent) async {
        guard let pack = Pack(rawValue: event.id) else { return }
        lastEvent[pack] = .now
        switch event.kind {
        case .began:
            if case .downloading = state(pack) {} else { set(pack, .downloading(nil)) }
        case .paused:
            set(pack, .paused)
        case let .downloading(fraction):
            set(pack, .downloading(fraction))
            if pack == current { updateBackground() }
        case .finished:
            Self.logger.info("\(pack.rawValue, privacy: .public): download finished")
            updates[pack] = nil
            await refresh()
            if !state(pack).isInstalled, !owned(pack), !stopped.contains(pack), !outdated.contains(pack) {
                // a system download (core pack, update) whose files can't be
                // read: a Retry, never a row stuck "Waiting" — after a
                // second look (the files may still be moving into place)
                states[pack] = .failed(Self.unreadable)
                scheduleRechecks()
            }
        case let .failed(error):
            Self.logger.error("\(pack.rawValue, privacy: .public): download failed: \(String(describing: error), privacy: .public)")
            noteError(pack, error, stage: "status stream")
            // ours: the request reports it, retried and checked against the
            // system first; a pack we stopped stays as Stop left it
            guard !owned(pack), !stopped.contains(pack) else { return }
            await refresh()
            guard !state(pack).isInstalled, !owned(pack) else { return }
            if let system, await system.localStatus(pack.rawValue).downloading { return }
            set(pack, Self.isNotFound(error) ? .unpublished : .failed(Self.message(error)))
        }
    }

    private func set(_ pack: Pack, _ state: PackState) {
        guard !stopped.contains(pack) else { return }
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

    /// Re-reads which packs are on the device (off the main thread) and
    /// recomputes every state from it: installed wherever the files open,
    /// whatever we thought before.
    private func refresh() async {
        guard let system else { return }
        // refreshes overlap (events, the queue, Storage): a look taken
        // before a newer one never overwrites it
        refreshCount += 1
        let mine = refreshCount
        var found = await Self.resolveOffMain(system)
        let passed = defaults.dictionary(forKey: Self.integrityKey) as? [String: String] ?? [:]
        let verified = await Self.verifyOffMain(found, known: verdicts, passed: passed)
        // a damaged pack the system is downloading (an update mid-swap?) is not judged yet
        var busy: Set<Pack> = []
        for (pack, v) in verified where v.report?.isDamaged == true {
            if await system.localStatus(pack.rawValue).downloading { busy.insert(pack) }
        }
        guard mine > refreshApplied else { return }
        refreshApplied = mine
        lastFound = found
        // In the background (a status event while the phone is locked, a
        // continued-processing task) files can be unreadable for a while —
        // data protection, a move in progress. An installed pack is not
        // downgraded then: the foreground re-sync has the last word.
        if !isActive {
            for pack in Pack.allCases where states[pack] == .installed && found.systemLocal.contains(pack) && !found.installed.contains(pack) {
                found.installed.insert(pack)
                var archives = found.location.archives
                for archive in pack.archives { archives[archive] = location.url(for: archive) }
                found.location = DataLocation(origin: found.location.origin, archives: archives)
                if pack == .plantid { found.plantID = plantIDDirectory }
            }
        }
        // the integrity verdicts: a damaged pack is missing (its archives
        // leave the location, MapLibre never opens them) until repaired
        let damaged = applyIntegrity(verified, passed: passed, to: &found)
        damagedNow = damaged
        for pack in Pack.allCases where damaged[pack] == nil {
            suspects[pack] = nil
            if repairBlocked[pack] != nil { repairBlocked[pack] = nil }
            blockedFailure[pack] = nil
        }
        lastSystemLocal = found.systemLocal
        plantIDDirectory = found.plantID
        let older = found.outdated.subtracting(found.installed)
        if outdated != older { outdated = older }
        var unreadable = false
        var toRepair: [Pack] = []
        for pack in Pack.allCases {
            if found.installed.contains(pack) {
                if repairing.contains(pack) { repairing.remove(pack) }
                if states[pack] != .installed { states[pack] = .installed }
                if queue.contains(pack) {
                    queue.removeAll { $0 == pack }
                    checkpoint()
                }
            } else if let failure = damaged[pack] {
                let confirmed = confirm(pack, failure, busy: busy.contains(pack) || updates[pack] != nil)
                updates[pack] = nil
                func show(_ state: PackState) { if states[pack] != state { states[pack] = state } }
                if owned(pack) {
                    switch states[pack] {
                    case .downloading?, .paused?: break
                    default: states[pack] = .downloading(nil)
                    }
                } else if blockedFailure[pack] == failure, let message = repairBlocked[pack] {
                    show(.failed(message))
                } else if repairedFailures[pack] == failure || repairsUsed(pack) >= Self.maxRepairs || !managesPacks {
                    // repaired once already (this launch), or the cap across launches
                    if repairing.contains(pack) { repairing.remove(pack) }
                    show(.failed(Self.damaged))
                } else {
                    // hidden from the map now; removed only after a second
                    // look (`confirm`), then downloaded again
                    if !repairing.contains(pack) { repairing.insert(pack) }
                    switch states[pack] {
                    case .downloading?, .paused?: break
                    default: states[pack] = .downloading(nil)
                    }
                    if confirmed { toRepair.append(pack) }
                }
            } else if older.contains(pack) {
                // an older version (plant ID v1): the new one is on its way
                // — the system updates prefetch packs by itself; ask the
                // server once so it starts now
                switch states[pack] {
                case .downloading?, .paused?: break
                default: states[pack] = .downloading(nil)
                }
                updates[pack] = nil
                if outdatedAsked.insert(pack).inserted {
                    Self.logger.notice("\(pack.rawValue, privacy: .public): an older version on the device; checking for updates")
                    Task { await self.refreshCatalogue(reason: "\(pack.rawValue): older version on the device") }
                }
            } else if found.systemLocal.contains(pack) {
                // the system has it, but its files don't resolve: say so (a
                // Retry; Diagnostics shows each path), never "not here · Get"
                if !owned(pack), !stopped.contains(pack), states[pack] != .failed(Self.unreadable) {
                    states[pack] = .failed(Self.unreadable)
                    unreadable = true
                }
                updates[pack] = nil
            } else if states[pack] == .installed {
                states[pack] = .notInstalled
                updates[pack] = nil
            }
        }
        publish(found.location)
        lastSync = .now
        if unreadable { scheduleRechecks() }
        if !toRepair.isEmpty {
            if queueRestored { enqueue(toRepair, user: false) } else { pendingRepairs += toRepair }
        }
        // here, whatever our request says (it may return late, or never):
        // the queue moves on — the next CALL still waits for this one
        if let current, found.installed.contains(current) { attempt?.settle(.success(())) }
        updateBackground()
    }

    /// Records the verdicts, persists passes, and takes damaged packs out of
    /// `found` (installed, archives, plant-ID folder). Returns each damaged
    /// pack's failure signature.
    private func applyIntegrity(_ verified: [Pack: Verified], passed: [String: String], to found: inout PackResolution) -> [Pack: String] {
        var passed = passed
        var damaged: [Pack: String] = [:]
        for pack in Pack.allCases where !found.systemLocal.contains(pack) && integrity[pack] != nil { integrity[pack] = nil }
        for (pack, v) in verified {
            guard let report = v.report else { continue }   // passed in an earlier launch
            // an inconclusive look (a file unreadable for now) is retried next time
            if report.isDamaged || report.isConclusive { verdicts[v.signature] = report }
            if integrity[pack] != report { integrity[pack] = report }
            if report.isDamaged {
                damaged[pack] = v.signature
                passed[pack.rawValue] = nil
            } else if report.isConclusive {
                passed[pack.rawValue] = v.signature
            }
        }
        if passed != (defaults.dictionary(forKey: Self.integrityKey) as? [String: String] ?? [:]) {
            defaults.set(passed, forKey: Self.integrityKey)
        }
        guard !damaged.isEmpty else { return [:] }
        var archives = found.location.archives
        for pack in damaged.keys {
            found.installed.remove(pack)
            for archive in pack.archives { archives[archive] = nil }
            if pack == .plantid { found.plantID = nil }
            found.folders[pack] = nil
        }
        found.location = DataLocation(origin: found.location.origin, archives: archives)
        return damaged
    }

    /// One pack's first damaged look, and whether a second confirmed it.
    struct Suspect {
        let signature: String
        let since: ContinuousClock.Instant
        var confirmed = false
    }

    /// Whether the damage to `pack` is confirmed: the SAME files found
    /// damaged again at least `repairConfirmAfter` after the first look,
    /// re-read (not the cached verdict), with no download or update of the
    /// pack running. Until then a recheck is scheduled.
    private func confirm(_ pack: Pack, _ failure: String, busy: Bool) -> Bool {
        guard var suspect = suspects[pack], suspect.signature == failure else {
            suspects[pack] = Suspect(signature: failure, since: .now)
            Self.logger.error("\(pack.rawValue, privacy: .public): damaged (\(self.integrity[pack]?.summary ?? "", privacy: .public)); looking again in \(self.tuning.repairConfirmAfter, privacy: .public)")
            noteError(pack, PackStoreError.damaged(integrity[pack]?.summary ?? ""), stage: "integrity")
            scheduleConfirm(pack)
            return false
        }
        if suspect.confirmed { return true }
        guard suspect.since.duration(to: .now) >= tuning.repairConfirmAfter, !busy else {
            scheduleConfirm(pack)
            return false
        }
        suspect.confirmed = true
        suspects[pack] = suspect
        Self.logger.error("\(pack.rawValue, privacy: .public): damage confirmed")
        return true
    }

    private func scheduleConfirm(_ pack: Pack) {
        guard confirmTasks[pack] == nil else { return }
        confirmTasks[pack] = Task { [weak self, tuning] in
            try? await Task.sleep(for: tuning.repairConfirmAfter)
            guard !Task.isCancelled, let self else { return }
            self.confirmTasks[pack] = nil
            // read the files again, not the cached verdict
            self.verdicts = self.verdicts.filter { !$0.key.hasPrefix(pack.rawValue + "|") }
            await self.refresh()
        }
    }

    /// The server's version of the pack (-1 unknown).
    private func serverVersion(_ pack: Pack) -> Int { manifest[pack]?.version ?? -1 }

    /// Repairs of this pack's current version so far (persisted; a stored
    /// or current unknown version counts as the same one).
    private func repairsUsed(_ pack: Pack) -> Int {
        guard let entry = (defaults.dictionary(forKey: Self.repairsKey) as? [String: [Int]])?[pack.rawValue], entry.count == 2 else { return 0 }
        let now = serverVersion(pack)
        return entry[0] == now || entry[0] == -1 || now == -1 ? entry[1] : 0
    }

    private func noteRepair(_ pack: Pack) {
        var all = defaults.dictionary(forKey: Self.repairsKey) as? [String: [Int]] ?? [:]
        let used = repairsUsed(pack)
        let version = serverVersion(pack) == -1 ? (all[pack.rawValue]?.first ?? -1) : serverVersion(pack)
        all[pack.rawValue] = [version, used + 1]
        defaults.set(all, forKey: Self.repairsKey)
    }

    /// A tap: this pack's repair starts over (cap, the failure seen, space).
    private func resetRepair(_ pack: Pack) {
        var all = defaults.dictionary(forKey: Self.repairsKey) as? [String: [Int]] ?? [:]
        all[pack.rawValue] = nil
        defaults.set(all, forKey: Self.repairsKey)
        repairedFailures[pack] = nil
        blockedFailure[pack] = nil
        repairBlocked[pack] = nil
        userRepairs.insert(pack)
        if !repairing.contains(pack) { repairing.insert(pack) }
    }

    /// A reader found the pack's files damaged (the plant-ID load checks
    /// before Core ML sees them): its cached pass is forgotten and the
    /// store looks again — the repair starts from there.
    func reportDamaged(_ pack: Pack) async {
        var passed = defaults.dictionary(forKey: Self.integrityKey) as? [String: String] ?? [:]
        passed[pack.rawValue] = nil
        defaults.set(passed, forKey: Self.integrityKey)
        verdicts = verdicts.filter { !$0.key.hasPrefix(pack.rawValue + "|") }
        Self.logger.error("\(pack.rawValue, privacy: .public): reported damaged; checking again")
        await refresh()
    }

    /// A full check of one pack's files now (Diagnostics), off the main thread.
    func checkIntegrityNow(_ pack: Pack) async -> PackIntegrity.Report? {
        guard let found = lastFound else { return nil }
        return await Task.detached(priority: .utility) { PackVerification.check(pack, in: found) }.value
    }

    /// Removes a damaged pack from the system before it is asked for again
    /// (bounded: a removal iOS doesn't answer never holds the queue).
    private func removeForRepair(_ pack: Pack) async {
        guard let system else { return }
        Self.logger.notice("\(pack.rawValue, privacy: .public): removing the damaged files")
        let removalID = UUID()
        removals.insert(removalID)
        let done = Attempt()
        let id = pack.rawValue
        let call = Task.detached { () -> Result<Void, any Error> in
            do { try await system.remove(id); return .success(()) } catch { return .failure(error) }
        }
        Task { done.settle(await call.value) }
        Task { [tuning] in
            try? await Task.sleep(for: tuning.removalTimeout)
            done.settle(.failure(PackStoreError.stalled))
        }
        do {
            try await done.value()
            Self.logger.info("\(pack.rawValue, privacy: .public): damaged files removed")
        } catch {
            Self.logger.error("\(pack.rawValue, privacy: .public): removing the damaged files failed: \(String(describing: error), privacy: .public)")
            noteError(pack, error, stage: "repair remove")
        }
        removals.remove(removalID)
        // what arrives next is read afresh (a folder's signature covers its
        // index, not every photo)
        verdicts = verdicts.filter { !$0.key.hasPrefix(pack.rawValue + "|") }
        wake()
        await refresh()
    }

    /// Downloads the system runs by itself (a prefetch pack after the
    /// install, a request from before a relaunch) show as such; a row
    /// showing a download (or a pause) the system no longer has is asked
    /// for again.
    private func syncDownloads() async {
        guard let system else { return }
        for pack in Pack.allCases where !state(pack).isInstalled && !stopped.contains(pack) {
            let status = await system.localStatus(pack.rawValue)
            let limit: Duration
            switch state(pack) {
            case .notInstalled, .failed:
                if status.downloading, !state(pack).isInstalled {
                    states[pack] = .downloading(nil)
                    lastEvent[pack] = .now
                }
                continue
            case .downloading: limit = tuning.staleAfter
            case .paused: limit = tuning.pausedStaleAfter
            default: continue
            }
            if !status.downloading, !status.downloaded, !owned(pack), quiet(pack, for: limit),
               manifest[pack] != nil || !manifestLoaded {
                // stale: nobody downloads it — a request resumes it
                Self.logger.notice("\(pack.rawValue, privacy: .public): shown \(String(describing: self.state(pack)), privacy: .public), the system has nothing; asking again")
                enqueue([pack], user: false)
            }
        }
    }

    /// The states from the system now (return to the foreground, Storage
    /// open, Diagnostics): files, downloads, then the queue carries on.
    func resync() async {
        guard system != nil, !backgroundAssetsUnavailable, isResolved else { return }
        await refresh()
        await syncDownloads()
        runQueue()
    }

    /// "Local, but the files don't open" may be a move in progress (iOS 27
    /// moved pack files to `Staging/Unlocalized/`): look again shortly.
    private func scheduleRechecks() {
        guard recheckTask == nil else { return }
        recheckTask = Task { [weak self, tuning] in
            for delay in tuning.unreadableRechecks {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
            self?.recheckTask = nil
        }
    }

    /// The server's manifest. The known one is replaced only by a manifest
    /// that was read: a failed reload (offline) keeps it.
    private func loadManifest() async {
        guard let system else { return }
        do {
            let packs = try await system.manifest()
            var fresh: [Pack: PackManifestEntry] = [:]
            for entry in packs {
                guard let pack = Pack(rawValue: entry.id) else {
                    Self.logger.notice("server has an unknown pack \(entry.id, privacy: .public)")
                    continue
                }
                fresh[pack] = entry
                downloadSizes[pack] = entry.downloadSize
            }
            manifest = fresh
            manifestLoaded = true
            manifestError = nil
            Self.logger.info("manifest: \(packs.map { "\($0.id) v\($0.version) \($0.downloadSize)" }.sorted(), privacy: .public)")
            // what the server doesn't offer can't arrive: an honest state,
            // not "arriving" for ever or a Get that can't work
            for pack in Pack.allCases {
                switch (manifest[pack] != nil, states[pack] ?? .notInstalled) {
                case (false, .notInstalled), (false, .failed):
                    guard !owned(pack) else { break }
                    Self.logger.notice("\(pack.rawValue, privacy: .public): not in the server's manifest")
                    states[pack] = .unpublished
                case (true, .unpublished):
                    // published since: one tap (or the launch fetch) gets it
                    states[pack] = .notInstalled
                default: break
                }
            }
        } catch {
            // offline, or no packs uploaded yet: sizes stay unknown
            manifestError = String(describing: error)
            Self.logger.notice("manifest unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// The server's latest asset-pack information (`checkForUpdates`: it
    /// also starts updates and drops packs the server removed — the system
    /// does both by itself periodically anyway), then the manifest again.
    private func refreshCatalogue(reason: String) async {
        guard let system else { return }
        let time = Date.now.formatted(date: .omitted, time: .standard)
        do {
            let (updating, removed) = try await system.checkForUpdates()
            catalogueLog.append("\(time) checkForUpdates (\(reason)): updating \(updating.sorted()), removed \(removed.sorted())")
        } catch {
            catalogueLog.append("\(time) checkForUpdates (\(reason)) failed: \(Self.describe(error))")
        }
        await loadManifest()
    }

    private func noteError(_ pack: Pack, _ error: any Error, stage: String) {
        errorLog[pack, default: []].append(ErrorRecord(date: .now, stage: stage, text: Self.describe(error)))
        if errorLog[pack]!.count > 8 { errorLog[pack]!.removeFirst() }
    }

    /// "BAManagedErrorDomain 0: No asset pack …" (Diagnostics).
    nonisolated static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription) [\(String(describing: error))]"
    }

    nonisolated static func message(_ error: any Error) -> String {
        if case PackStoreError.unreadable? = error as? PackStoreError { return unreadable }
        if case PackStoreError.damaged? = error as? PackStoreError { return damaged }
        return error.localizedDescription
    }

    nonisolated static let unreadable = "The download finished, but its files couldn't be opened."
    nonisolated static let damaged = "Its files on this device are incomplete, and downloading them again didn't help."

    /// "No such asset pack" from Background Assets (the Swift error, or the
    /// bridged `BAManagedErrorCodeAssetPackNotFound`, code 0).
    nonisolated static func isNotFound(_ error: any Error) -> Bool {
        if let managed = error as? ManagedBackgroundAssetsError, case .assetPackNotFound = managed { return true }
        let ns = error as NSError
        return ns.domain.contains("BAManaged") && ns.code == 0
    }

    // MARK: Resolving files

    @concurrent nonisolated private static func resolveOffMain(_ system: any PackSystem) async -> PackResolution {
        system.resolve()
    }

    /// One pack's integrity verdict: `report` nil = passed in an earlier
    /// launch with the same files (not read again).
    nonisolated struct Verified: Sendable {
        let signature: String
        let report: PackIntegrity.Report?
    }

    /// The integrity check of every pack the system says is here (cheap:
    /// headers and sizes; a pass is cached per pack version, a verdict per
    /// launch).
    @concurrent nonisolated private static func verifyOffMain(_ found: PackResolution, known: [String: PackIntegrity.Report],
                                                              passed: [String: String]) async -> [Pack: Verified] {
        var out: [Pack: Verified] = [:]
        for pack in Pack.allCases where found.installed.contains(pack) {
            guard let signature = PackVerification.signature(pack, in: found) else { continue }
            if passed[pack.rawValue] == signature {
                out[pack] = Verified(signature: signature, report: nil)
            } else if let report = known[signature] {
                out[pack] = Verified(signature: signature, report: report)
            } else if let report = PackVerification.check(pack, in: found) {
                out[pack] = Verified(signature: signature, report: report)
            }
        }
        return out
    }

    /// Whether this process can use the app group Background Assets
    /// coordinates through (Info.plist BAAppGroupID): `containerURL` is nil
    /// when the signature doesn't carry it.
    @concurrent nonisolated private static func appGroupIsAccessibleOffMain() async -> Bool {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BAAppGroupID") as? String else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }

    #if DEBUG
    /// A developer's `data/` folder: its archives, and plant ID as
    /// build_packs.py staged it (`PlantIDSession.source` reads it there).
    private static func debugStates(_ location: DataLocation, dir: URL) -> [Pack: PackState] {
        var states = states(for: location)
        let head = PlantIDFiles.staged(in: dir).appending(path: PlantIDFiles.head)
        if FileManager.default.fileExists(atPath: head.path(percentEncoded: false)) { states[.plantid] = .installed }
        return states
    }
    #endif

    private static func states(for location: DataLocation) -> [Pack: PackState] {
        Dictionary(uniqueKeysWithValues: Pack.allCases.map { pack in
            let have = !pack.archives.isEmpty && pack.archives.allSatisfy { location.url(for: $0) != nil }
            return (pack, have ? .installed : .notInstalled)
        })
    }
}

/// The store's own reasons a request ends.
nonisolated enum PackStoreError: Error, Equatable, LocalizedError {
    /// Available, but its files didn't open.
    case unreadable
    /// The system says downloaded, the files are cut short (the integrity check).
    case damaged(String)
    /// The call returned, yet the system doesn't call the pack local.
    case notLocal
    /// The system had nothing for it for too long (the watchdog).
    case stalled
    /// The lost call never returned; the queue went on without it.
    case abandoned

    var errorDescription: String? {
        switch self {
        case .unreadable: PackStore.unreadable
        case let .damaged(why): "The files on this device are incomplete: \(why)"
        case .notLocal: "iOS said the download was done, but it isn't on the device."
        case .stalled: "The download stopped without a word from iOS."
        case .abandoned: "iOS never answered the request; asked again."
        }
    }
}

/// One request's outcome, settled once — by the system's call returning, or
/// earlier by the store (Stop, the system's `finished`).
@MainActor
private final class Attempt {
    let started = ContinuousClock.now
    private var outcome: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    var isPending: Bool { outcome == nil }

    func settle(_ result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func value() async throws {
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

/// The system's progress UI for long work (`AreaBackgroundTask`), as the
/// pack queue uses it (a fake in tests).
@MainActor
protocol ContinuedWork: AnyObject {
    var onExpire: (() -> Void)? { get set }
    var isRunning: Bool { get }
    @discardableResult func begin(title: String, subtitle: String) -> Bool
    func update(done: Int, total: Int, title: String, subtitle: String)
    func end(success: Bool)
}

#if DEBUG
// MARK: - DEBUG fake store

/// The DEBUG stand-in for Background Assets (the real `AssetPackManager`
/// has no packs in tests or a plain simulator run). Launch argument
/// `-fakePacks <spec>`: comma-separated `pack[=state]`, state one of
/// `installed` (the default), `downloading:<0…1>`, `paused`, `failed`,
/// `unpublished`, `updating:<0…1>` (installed, a new version arriving),
/// `outdated` (an older version local: plant ID v1 before v2 arrives);
/// every other pack is not installed. Presets for screenshots: `mixed`
/// (core packs arriving/updating — plant ID at 83 %), `settled` (every core
/// pack here: the folded summary row; extras in their other states).
/// A fetch "downloads" over `-fakePackSeconds` (default 4 s), one at a time
/// like the real queue (`FakePackSystem`).
nonisolated struct FakePacks: Sendable {
    static let key = "fakePacks"
    static let mixed = "vector,topo=updating:0.4,relief,refphotos,plantid=downloading:0.83,aerial,season-2023,season-2024,season-2025=downloading:0.62,season-2026=paused"
    static let settled = "vector,topo,relief,plantid,refphotos,aerial=failed,tasmap=downloading:0.41,season-2024,season-2025=paused"

    var states: [Pack: PackState]
    var updates: [Pack: Double] = [:]
    /// Packs local in an older version (`outdated`: plant ID v1).
    var outdated: Set<Pack> = []
    var directory: URL?
    var seconds: Double

    init(spec: String, directory: URL? = nil, seconds: Double = 4) {
        let spec = spec == "mixed" ? Self.mixed : spec == "settled" ? Self.settled : spec
        var states = Dictionary(uniqueKeysWithValues: Pack.allCases.map { ($0, PackState.notInstalled) })
        var updates: [Pack: Double] = [:]
        var outdated: Set<Pack> = []
        for part in spec.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = pair.first, let pack = Pack(rawValue: first) else { continue }
            let value = pair.count > 1 ? pair[1] : "installed"
            switch value {
            case "paused": states[pack] = .paused
            case "unpublished": states[pack] = .unpublished
            case "failed": states[pack] = .failed("The download didn't finish.")
            case "outdated": outdated.insert(pack)   // an older version local (plant ID v1)
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
        self.outdated = outdated
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

    /// The system side of the spec: installed and downloading packs.
    func system() -> FakePackSystem {
        var downloading: [Pack: Double] = [:]
        for (pack, state) in states { if case let .downloading(f) = state { downloading[pack] = f ?? 0 } }
        return FakePackSystem(installed: Set(states.filter { $0.value == .installed }.keys), downloading: downloading,
                              unpublished: Set(states.filter { $0.value == .unpublished }.keys),
                              outdated: outdated, seconds: seconds, directory: directory, returnDelay: 0)
    }
}

extension PackStore {
    /// The `-fakePacks` store: the spec's states at once (no lookup), then
    /// the same queue, events and refreshes as the real one.
    convenience init(fake: FakePacks) {
        // the system's progress UI would cover the app in UI tests
        let background = UserDefaults.standard.bool(forKey: "fakePackBackgroundTask") ? AreaBackgroundTask.forPacks() : nil
        self.init(mode: .fake, location: fake.location(), states: fake.states, system: fake.system(), background: background)
        self.fake = fake
        queueKey = "packQueueFake"
        updates = fake.updates
        downloadSizes = PackSizes.nominal
        Task { [weak self] in await self?.boot(autoFetchCore: false, restoreQueue: false, hooks: false) }
    }
}
#endif
