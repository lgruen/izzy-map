import BackgroundTasks
import Foundation
import Testing
@testable import IzzyMap

/// The pack download queue over `FakePackSystem`: ONE call in flight (never
/// two, whatever path ended the last wait), retries with backoff, nothing
/// failed by a background interruption or being offline, the system's
/// word winning over a stale state, the checkpointed queue and the
/// continued-processing task. (Field report, iPhone 16e / iOS 27.2,
/// 2026-11-04: "Get all" left most seasons "Didn't finish"; an app switch
/// did too; a stale "Didn't finish" went installed on Retry at once.)
/// Timing-based: serialized, and every store is shut down at the end.
@MainActor
@Suite(.serialized)
struct PackQueueTests {
    static let tuning = PackStore.Tuning(
        retryDelays: [.milliseconds(20), .milliseconds(20), .milliseconds(20)],
        stallAfter: .milliseconds(250), pausedStallAfter: .milliseconds(400), watchInterval: .milliseconds(40),
        unreadableRechecks: [.milliseconds(40)], freeReattaches: 2,
        staleAfter: .milliseconds(60), pausedStaleAfter: .milliseconds(120), pollInterval: .milliseconds(10),
        heartbeat: .seconds(30), abandonGrace: .seconds(1), removalTimeout: .seconds(2),
        offlineRecheck: .milliseconds(10))

    /// A short grace period, for the abandon paths.
    static var quickAbandon: PackStore.Tuning {
        var t = tuning
        t.abandonGrace = .milliseconds(150)
        return t
    }

    /// What the system said on 27.2 when several requests ran at once.
    static let unavailable = NSError(domain: "AssetPackManagerError", code: 0,
                                     userInfo: [NSLocalizedDescriptionKey: "The asset pack is unavailable."])

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "PackQueueTests-\(UUID().uuidString)")!
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func status(_ store: PackStore, _ pack: Pack) -> PackRowStatus {
        StorageModel(packs: store, trees: nil).status(pack)
    }

    private func isFailed(_ state: PackState) -> Bool { if case .failed = state { true } else { false } }

    // MARK: One at a time

    @Test func queuedRowsSayTheirPlace() {
        #expect(PackRowStatus.of(.notInstalled, pack: .tasmap, canFetch: true, queued: 1) == .queued(1))
        #expect(PackRowStatus.of(.failed("x"), pack: .tasmap, canFetch: true, queued: 3) == .queued(3))
        #expect(PackRowStatus.of(.paused, pack: .tasmap, canFetch: true, queued: 2) == .queued(2))
        // the system already moving its bytes: that's what the row shows
        #expect(PackRowStatus.of(.downloading(0.4), pack: .tasmap, canFetch: true, queued: 2) == .downloading(0.4))
        #expect(PackRowStatus.of(.installed, pack: .tasmap, canFetch: true, queued: 2) == .onDevice)
        #expect(PackRowStatus.queued(1).text(bytes: 3_240_000_000, device: "iPhone") == "Queued · next · 3.24\u{00A0}GB")
        #expect(PackRowStatus.queued(4).text(bytes: 3_240_000_000, device: "iPhone") == "Queued · 4 in line · 3.24\u{00A0}GB")
        #expect(PackRowStatus.queued(4).isBusy && !PackRowStatus.queued(4).offersGet && PackRowStatus.queued(4).progress == nil)
    }

    @Test func getAllQueuesNewestSeasonFirstOneAtATime() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        let model = StorageModel(packs: store, trees: nil)
        let missing = model.missing(.seasons)
        #expect(missing == [.season2026, .season2025, .season2024, .season2023, .season2022, .season2021, .season2020])
        store.fetch(missing)
        // the rest wait their turn, numbered — not all "Waiting to start"
        #expect(model.status(.season2020) == .queued(missing.count - 1) || model.status(.season2020) == .queued(missing.count))
        #expect(model.status(.season2020).text(bytes: 1_000_000, device: "iPhone").hasPrefix("Queued · "))
        #expect(model.status(.season2020).isBusy)
        #expect(await eventually { missing.allSatisfy { store.state($0).isInstalled } && store.current == nil })
        #expect(system.maxInFlight == 1)
        #expect(system.requests == missing.map(\.rawValue))
        #expect(store.queue.isEmpty)
    }

    @Test func coreFetchesJumpTheQueue() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025, .season2024])
        #expect(await eventually { store.current == .season2026 })
        store.fetch(.plantid)
        #expect(await eventually { [Pack.season2026, .season2025, .season2024, .plantid].allSatisfy { store.state($0).isInstalled } })
        // the first was already in flight; plant ID went next
        #expect(system.requests == ["season-2026", "plantid", "season-2025", "season-2024"])
        #expect(system.maxInFlight == 1)
    }

    @Test func stoppingAQueuedPackSkipsIt() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.1)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025, .season2024])
        await store.remove(.season2025)
        #expect(await eventually { store.state(.season2024).isInstalled })
        #expect(!system.requests.contains("season-2025"))
        #expect(store.state(.season2025) == .notInstalled)
        #expect(system.maxInFlight == 1)
    }

    /// Stop on the pack in flight: the next one is asked for only once the
    /// system is done with the removal and the stopped call has returned.
    @Test func stoppingTheCurrentPackHoldsTheNextUntilTheSystemIsDone() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        await store.remove(.season2026)
        #expect(await eventually { store.state(.season2025).isInstalled })
        #expect(system.calls == ["season-2026", "-season-2026", "season-2025"])
        #expect(system.maxInFlight == 1)
        #expect(store.state(.season2026) == .notInstalled)
    }

    // MARK: Retries

    @Test func transientErrorsAreRetriedBeforeFailing() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2023, .init(failures: [Self.unavailable, Self.unavailable]))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch(.season2023)
        #expect(await eventually { store.state(.season2023).isInstalled })
        #expect(system.requests == ["season-2023", "season-2023", "season-2023"])
        #expect(store.errorLog[.season2023]?.count == 2)
        #expect(store.retries[.season2023] == nil)
        #expect(system.maxInFlight == 1)
    }

    @Test func giveUpAfterTheLastRetryAndCarryOn() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2023, .init(failures: Array(repeating: Self.unavailable, count: 4)))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch([.season2023, .season2022])
        #expect(await eventually { store.state(.season2022).isInstalled })
        #expect(system.requests.filter { $0 == "season-2023" }.count == 4)
        #expect(status(store, .season2023) == .failed)
        // Retry: asked again from scratch (the next request succeeds)
        store.fetch(.season2023)
        #expect(await eventually { store.state(.season2023).isInstalled })
    }

    // MARK: Lifecycle and connectivity

    @Test func aRequestCutOffInTheBackgroundDoesNotFail() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.tasmap, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch(.tasmap)
        #expect(await eventually { system.inFlight == 1 })
        // she switches apps; the suspended request comes back cut off
        store.appEnteredBackground()
        system.fail(.tasmap, CancellationError(), keepsDownloading: false)
        #expect(await eventually { store.parkedFor == .background })
        #expect(status(store, .tasmap).isBusy, "\(status(store, .tasmap))")
        #expect(!isFailed(store.state(.tasmap)))
        #expect(store.retries[.tasmap] ?? 0 == 0)
        #expect(system.requests == ["tasmap"])
        // back: the request goes again by itself and the pack arrives
        store.appBecameActive()
        #expect(await eventually { store.state(.tasmap).isInstalled })
        #expect(system.requests == ["tasmap", "tasmap"])
        #expect(system.maxInFlight == 1)
    }

    /// Kept running in the background (the areas' task): a failure there
    /// is a real one — retried with backoff, not parked.
    @Test func aFailureWhileKeptAliveIsReal() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2022, .init(failures: [Self.unavailable]))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning, keptAlive: { true })
        defer { store.shutdown() }
        store.appEnteredBackground()
        store.fetch(.season2022)
        #expect(await eventually { store.state(.season2022).isInstalled })
        #expect(system.requests == ["season-2022", "season-2022"])
        #expect(store.parkedFor == nil)
    }

    /// Offline (a launch in the bush with a checkpointed queue): no retry
    /// is used, nothing dropped from the checkpoint, and the request goes
    /// again when a path comes back.
    @Test func offlineFailuresWaitForAConnection() async {
        let defaults = defaults()
        defaults.set(["season-2025"], forKey: PackStore.queueKey)
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2025, .init(failures: [Self.unavailable]))
        system.setManifestFails(true)
        let store = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning, online: false)
        defer { store.shutdown() }
        #expect(await eventually { store.parkedFor == .offline })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(system.requests == ["season-2025"], "no retries while offline")
        #expect(store.retries[.season2025] ?? 0 == 0)
        #expect(!isFailed(store.state(.season2025)))
        #expect(defaults.stringArray(forKey: PackStore.queueKey) == ["season-2025"])
        store.simulateConnectivity(true)
        #expect(await eventually { store.state(.season2025).isInstalled && store.current == nil })
        #expect(defaults.stringArray(forKey: PackStore.queueKey) == nil)
    }

    /// A catalogue refresh that can't read the manifest keeps the old one
    /// (no pack turns "unpublished" for the session).
    @Test func aFailedManifestReloadKeepsTheManifest() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.manifestVersions.count == Pack.allCases.count)
        system.setManifestFails(true)
        system.script(.aerial, .init(failures: [ManagedBackgroundAssetsErrorProbe.notFound(.aerial)]))
        store.fetch(.aerial)
        #expect(await eventually { store.state(.aerial).isInstalled })
        #expect(store.manifestVersions.count == Pack.allCases.count)
        #expect(store.catalogueLog.count == 1)
    }

    @Test func aStaleDownloadIsAskedForAgainOnReturn() async {
        // the system was downloading it at launch, then lost it (local status [])
        let system = FakePackSystem(installed: [.vector], downloading: [.tasmap: 0.79], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(status(store, .tasmap).isBusy)
        system.drop(.tasmap)
        try? await Task.sleep(for: .milliseconds(100))
        store.appBecameActive()
        #expect(await eventually { store.state(.tasmap).isInstalled })
        #expect(system.requests == ["tasmap"])
    }

    @Test func aStalePauseIsAskedForAgainToo() async {
        let system = FakePackSystem(installed: [.vector], downloading: [.aerial: 0.3], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        system.pause(.aerial)
        #expect(await eventually { store.state(.aerial) == .paused })
        system.drop(.aerial)
        try? await Task.sleep(for: .milliseconds(80))
        await store.resync()
        #expect(store.state(.aerial) == .paused, "younger than the paused threshold: left alone")
        try? await Task.sleep(for: .milliseconds(100))
        await store.resync()
        #expect(await eventually { store.state(.aerial).isInstalled })
        #expect(system.requests == ["aerial"])
    }

    /// The request hangs and the system has nothing for it: the watchdog
    /// ends the lost call (removal of nothing) — never a second call beside it.
    @Test func aLostRequestIsEndedThenAskedForAgain() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2021, .init(hangs: 1, silent: true))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch(.season2021)
        #expect(await eventually { store.state(.season2021).isInstalled })
        #expect(system.calls == ["season-2021", "-season-2021", "season-2021"])
        #expect(system.maxInFlight == 1)
        #expect(store.errorLog[.season2021]?.contains { $0.text.contains("stalled") } == true)
    }

    /// A lost call that even `remove` doesn't release: after the grace
    /// period it is abandoned and the queue goes on — two calls at most.
    @Test func aCallThatNeverReturnsIsAbandonedAfterTheGracePeriod() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2021, .init(hangs: 1, silent: true, ignoresRemove: true))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.quickAbandon)
        defer { store.shutdown() }
        store.fetch([.season2021, .season2020])
        #expect(await eventually { store.state(.season2020).isInstalled })
        #expect(store.state(.season2021).isInstalled)
        #expect(system.calls == ["season-2021", "-season-2021", "season-2021", "season-2020"])
        #expect(system.maxInFlight == 2)
        #expect(store.abandonedCall == .season2021 && store.abandonedCount == 1)
        #expect(store.errorLog[.season2021]?.contains { $0.text.contains("abandoned") } == true)
        // it finally returns: the slot clears
        system.fail(.season2021, Self.unavailable)
        #expect(await eventually { store.abandonedCall == nil })
    }

    /// A second lost call while one is abandoned: no third call — the queue
    /// waits until the abandoned one returns, then abandons the second.
    @Test func aSecondLostCallWaitsForTheAbandonedOne() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1, silent: true, ignoresRemove: true))
        system.script(.season2025, .init(hangs: 1, silent: true, ignoresRemove: true))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.quickAbandon)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { store.state(.season2026).isInstalled && store.current == .season2025 })
        #expect(await eventually { store.errorLog[.season2025]?.contains { $0.text.contains("stalled") } == true })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(system.requests == ["season-2026", "season-2026", "season-2025"], "waits: no third call")
        #expect(system.inFlight == 2 && store.abandonedCall == .season2026)
        #expect(!store.state(.season2025).isInstalled)
        // the abandoned one returns: the second is abandoned in turn, asked again
        system.fail(.season2026, Self.unavailable)
        #expect(await eventually { store.state(.season2025).isInstalled })
        #expect(system.maxInFlight == 2)
        #expect(store.abandonedCount == 2)
    }

    /// Probe (round-2 review): a lost call that `remove` doesn't release,
    /// then Stop — the attempt settles early with the call still out. The
    /// per-call grace period still abandons it; the next pack goes.
    @Test func stoppingALostCallStillLetsTheQueueGoOn() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1, silent: true, ignoresRemove: true))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.quickAbandon)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        await store.remove(.season2026)
        #expect(await eventually { store.state(.season2025).isInstalled })
        #expect(store.abandonedCall == .season2026)
        #expect(system.maxInFlight == 2)
    }

    /// Probe: the call hangs, the pack arrives without a word, a re-sync
    /// finds it — the attempt settles early; the queue still goes on.
    @Test func aPackFoundInstalledWhileItsCallHangsLetsTheQueueGoOn() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.quickAbandon)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        system.installSilently(.season2026)
        await store.resync()
        #expect(store.state(.season2026).isInstalled)
        #expect(await eventually { store.state(.season2025).isInstalled })
        #expect(system.maxInFlight == 2)
    }

    /// A Stop whose `remove` iOS never answers holds the queue for
    /// `removalTimeout` at most.
    @Test func aRemovalThatNeverReturnsTimesOut() async {
        var tuning = Self.quickAbandon
        tuning.removalTimeout = .milliseconds(150)
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1, silent: true, ignoresRemove: true, removeHangs: true))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        Task { await store.remove(.season2026) }
        #expect(await eventually { store.state(.season2025).isInstalled })
        #expect(system.maxInFlight == 2)
    }

    /// The offline error arrives before the path monitor's word: the
    /// re-check after a moment parks it instead of spending a retry.
    @Test func anOfflineWordArrivingLateSpendsNoRetry() async {
        var tuning = Self.tuning
        tuning.offlineRecheck = .milliseconds(300)
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2022, .init(failures: [Self.unavailable]))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning)
        defer { store.shutdown() }
        store.fetch(.season2022)
        #expect(await eventually { store.errorLog[.season2022]?.isEmpty == false })
        store.simulateConnectivity(false)
        #expect(await eventually { store.parkedFor == .offline })
        #expect(store.retries[.season2022] ?? 0 == 0)
        store.simulateConnectivity(true)
        #expect(await eventually { store.state(.season2022).isInstalled })
    }

    /// A flapping connection never adds up to "Didn't finish": retries
    /// start over when the path comes back.
    @Test func retriesStartOverOnReconnect() async {
        var tuning = Self.tuning
        tuning.retryDelays = [.milliseconds(20), .milliseconds(20), .milliseconds(200)]
        let system = FakePackSystem(installed: [.vector], seconds: 0.02, returnDelay: 0)
        system.script(.season2022, .init(failures: Array(repeating: Self.unavailable, count: 4)))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning)
        defer { store.shutdown() }
        store.fetch(.season2022)
        #expect(await eventually { store.retries[.season2022] == 3 })
        store.simulateConnectivity(false)
        store.simulateConnectivity(true)
        #expect(store.retries[.season2022] == 0)
        #expect(await eventually { store.state(.season2022).isInstalled })
        #expect(!isFailed(store.state(.season2022)))
    }

    /// Paused by the system, then lost (local status []): the longer paused
    /// threshold, then the same — the queue moves on.
    @Test func aPausedThenLostRequestDoesNotHoldTheQueueForEver() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2024, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch([.season2024, .season2023])
        #expect(await eventually { system.inFlight == 1 })
        system.pause(.season2024)
        #expect(await eventually { store.state(.season2024) == .paused })
        system.drop(.season2024)
        #expect(await eventually { store.state(.season2023).isInstalled })
        #expect(store.state(.season2024).isInstalled)
        #expect(system.calls == ["season-2024", "-season-2024", "season-2024", "season-2023"])
        #expect(system.maxInFlight == 1)
    }

    /// Resume on the paused pack in flight: the row moves at once, and no
    /// second call goes beside the first however often she taps.
    @Test func resumingThePausedCurrentPackNeverDoublesTheCall() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch(.season2026)
        #expect(await eventually { system.inFlight == 1 })
        system.pause(.season2026)
        #expect(await eventually { store.state(.season2026) == .paused })
        store.resume(.season2026)
        #expect(store.state(.season2026) == .downloading(nil), "Resume shows at once")
        store.resume(.season2026)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(system.maxInFlight == 1)
        #expect(system.requests == ["season-2026"])
        system.finish(.season2026)
        #expect(await eventually { store.state(.season2026).isInstalled })
    }

    /// Resume while the current pack waits for its retry: it goes at once
    /// (a tap before the wait began counts too).
    @Test func resumeCutsARetryWaitShort() async {
        var tuning = Self.tuning
        tuning.retryDelays = [.seconds(30)]
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2020, .init(failures: [Self.unavailable]))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning)
        defer { store.shutdown() }
        store.fetch(.season2020)
        #expect(await eventually { store.retryAt != nil })
        store.resume(.season2020)
        #expect(await eventually(2) { store.state(.season2020).isInstalled })
    }

    @Test func theCheckpointedQueueResumesAtLaunch() async {
        let defaults = defaults()
        defaults.set(["season-2025", "season-2024", "vector"], forKey: PackStore.queueKey)
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(await eventually { store.state(.season2024).isInstalled && store.current == nil })
        #expect(system.requests == ["season-2025", "season-2024"])
        #expect(defaults.stringArray(forKey: PackStore.queueKey) == nil)
    }

    // MARK: System truth wins

    /// Leo, 2026-11-04: "Didn't finish"; Retry → installed at once. Our
    /// request threw (or was cut off), the system finished anyway.
    @Test func aFailedRequestTheSystemFinishedShowsInstalledByItself() async {
        var tuning = Self.tuning
        tuning.retryDelays = []
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2020, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning)
        defer { store.shutdown() }
        store.fetch(.season2020)
        #expect(await eventually { system.inFlight == 1 })
        system.fail(.season2020, Self.unavailable)
        #expect(await eventually { status(store, .season2020) == .failed })
        // later the system has it — with a `finished` event…
        system.finish(.season2020)
        #expect(await eventually { store.state(.season2020).isInstalled })
        #expect(status(store, .season2020) == .onDevice)

        // …or silently: Storage's re-sync (on appear, every 10 s) finds it
        system.script(.season2021, .init(hangs: 1))
        store.fetch(.season2021)
        #expect(await eventually { system.inFlight == 1 })
        system.fail(.season2021, Self.unavailable)
        #expect(await eventually { status(store, .season2021) == .failed })
        system.installSilently(.season2021)
        await store.resync()
        #expect(status(store, .season2021) == .onDevice)
    }

    @Test func aRequestThatThrowsAfterTheDownloadIsNoFailure() async {
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.aerial, .init(throwsAfterInstalling: Self.unavailable))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch(.aerial)
        #expect(await eventually { store.state(.aerial).isInstalled })
        #expect(system.requests == ["aerial"])
    }

    /// The vector pack: "files couldn't be opened" in our state while the
    /// system said downloaded and every file resolved.
    @Test func unreadableFilesRecoverOnTheirOwn() async {
        let system = FakePackSystem(installed: [.vector, .topo], seconds: 0.02)
        system.setUnreadable(.vector, true)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.state(.vector) == .failed(PackStore.unreadable))
        #expect(store.state(.topo) == .installed)
        system.setUnreadable(.vector, false)
        // the scheduled second look, no tap
        #expect(await eventually { store.state(.vector) == .installed })
        await store.resync()
        #expect(store.state(.vector) == .installed)
    }

    /// Retry on a local-but-unreadable pack: one call (it returns at once),
    /// no retries spent, the unreadable state and a second look.
    @Test func retryingAnUnreadablePackSpendsNoRetries() async {
        let system = FakePackSystem(installed: [.vector, .aerial], seconds: 0.02)
        system.setUnreadable(.aerial, true)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        store.fetch(.aerial)
        #expect(await eventually { store.current == nil && store.queue.isEmpty })
        #expect(store.state(.aerial) == .failed(PackStore.unreadable))
        #expect(system.requests == ["aerial"])
        system.setUnreadable(.aerial, false)
        #expect(await eventually { store.state(.aerial) == .installed })
    }

    /// An older plant-ID pack on the device (v1 files, no v2 head): an
    /// update on its way, never "couldn't be opened"; a Get returns at once
    /// without a failure; the new version arriving installs it.
    @Test func anOlderPlantIDPackIsAnUpdateOnItsWay() async {
        let system = FakePackSystem(installed: [.vector], outdated: [.plantid], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning, autoFetchCore: true)
        defer { store.shutdown() }
        #expect(store.outdated == [.plantid])
        #expect(store.state(.plantid) == .downloading(nil))
        #expect(await eventually { store.state(.relief).isInstalled })
        store.fetch(.plantid)
        #expect(await eventually { store.current == nil && store.queue.isEmpty })
        #expect(store.state(.plantid) == .downloading(nil))
        #expect(store.plantIDDirectory == nil)
        system.finish(.plantid)
        #expect(await eventually { store.state(.plantid) == .installed })
        #expect(store.outdated.isEmpty)
    }

    @Test func filesUnreadableInTheBackgroundDontUninstallAPack() async {
        let system = FakePackSystem(installed: [.vector, .aerial], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.state(.aerial) == .installed)
        store.appEnteredBackground()
        system.setUnreadable(.aerial, true)
        await store.resync()
        #expect(store.state(.aerial) == .installed)
        store.appBecameActive()
        #expect(await eventually { store.state(.aerial) == .failed(PackStore.unreadable) })
        system.setUnreadable(.aerial, false)
        await store.resync()
        #expect(store.state(.aerial) == .installed)
    }

    @Test func aCorePackTheSystemIsDownloadingIsNotQueuedAtLaunch() async {
        let system = FakePackSystem(installed: [.vector], downloading: [.topo: 0.3], seconds: 0.02)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning, autoFetchCore: true)
        defer { store.shutdown() }
        #expect(await eventually { store.state(.relief).isInstalled && store.state(.plantid).isInstalled })
        #expect(!system.requests.contains("topo"))
        #expect(status(store, .topo).isBusy)
    }

    // MARK: Continued processing

    /// Parked offline: no ticks (nothing to report); parked offline in the
    /// background: the task ends (the checkpoint resumes the queue).
    @Test func aTaskParkedOfflineIsNotKeptAlive() async {
        var tuning = Self.tuning
        tuning.heartbeat = .milliseconds(20)
        let task = FakeContinuedWork()
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(failures: [Self.unavailable]))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning, background: task, online: false)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(task.begun.count == 1)
        #expect(await eventually { store.parkedFor == .offline })
        let before = task.updates.last?.done ?? -1
        try? await Task.sleep(for: .milliseconds(200))
        #expect((task.updates.last?.done ?? -1) == before, "no ticks while parked")
        #expect(task.ended == nil)

        let task2 = FakeContinuedWork()
        let system2 = FakePackSystem(installed: [.vector], seconds: 0.02)
        system2.script(.season2024, .init(hangs: 1))
        let store2 = await PackStore.testing(system: system2, defaults: defaults(), tuning: tuning, background: task2, online: false)
        defer { store2.shutdown() }
        store2.fetch([.season2024, .season2023])
        #expect(await eventually { system2.inFlight == 1 })
        store2.appEnteredBackground()
        system2.fail(.season2024, Self.unavailable)
        #expect(await eventually { task2.ended == false })
        #expect(store2.parkedFor == .offline)
    }

    @Test func ticksAreCappedPerPack() async {
        var tuning = Self.tuning
        tuning.heartbeat = .milliseconds(20)
        tuning.maxTicksPerPack = 2
        let task = FakeContinuedWork()
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning, background: task)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect((task.updates.last?.done ?? 0) <= 2)
    }

    @Test func aLongQueueRunsInABackgroundTask() async {
        let task = FakeContinuedWork()
        let system = FakePackSystem(installed: [.vector], seconds: 0.03)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning, background: task)
        defer { store.shutdown() }
        store.fetch(.season2021)
        #expect(await eventually { store.state(.season2021).isInstalled && store.current == nil })
        #expect(task.begun.isEmpty, "one small pack: no system task")
        store.fetch([.season2026, .season2025])
        #expect(task.begun.first?.title == "Downloading maps")
        #expect(task.begun.first?.subtitle.contains("photos") == true)
        #expect(await eventually { task.ended != nil })
        #expect(task.ended == true)
        let total = (PackSizes.nominal[.season2026] ?? 0) + (PackSizes.nominal[.season2025] ?? 0)
        #expect(task.updates.last.map { $0.total >= total && $0.done == $0.total } == true)
        let done = task.updates.map(\.done)
        #expect(done == done.sorted(), "progress only grows")
        // one big pack gets one too
        let big = FakeContinuedWork()
        let store2 = await PackStore.testing(system: FakePackSystem(installed: [.vector], seconds: 0.02), defaults: defaults(),
                                             tuning: Self.tuning, background: big)
        defer { store2.shutdown() }
        store2.fetch(.tasmap)
        #expect(big.begun.count == 1)
    }

    /// A pause and a fresh "began" never take bytes off the bar; a Stop
    /// isn't counted as the task failing.
    @Test func backgroundProgressNeverGoesBackAndAStopIsNoFailure() async {
        let task = FakeContinuedWork()
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning, background: task)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        system.progress(.season2026, 0.5)
        #expect(await eventually { store.state(.season2026) == .downloading(0.5) })
        system.pause(.season2026)
        #expect(await eventually { store.state(.season2026) == .paused })
        await store.resync()
        await store.remove(.season2026)
        #expect(await eventually { task.ended != nil })
        #expect(task.ended == true, "the stopped pack is no part of the run")
        let done = task.updates.map(\.done)
        #expect(done == done.sorted(), "\(done)")
    }

    @Test func aQuietTaskStillHearsFromUs() async {
        var tuning = Self.tuning
        tuning.heartbeat = .milliseconds(30)
        let task = FakeContinuedWork()
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning, background: task)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        let before = task.updates.last?.done ?? 0
        #expect(await eventually { (task.updates.last?.done ?? 0) > before })
        #expect(task.subtitles.last?.contains("waiting to start") == true, "\(task.subtitles.last ?? "")")
    }

    /// She ends "Downloading maps" (or the system does): the queue carries
    /// on without it; returning to the app never asks for a new one — only
    /// her next Get does.
    @Test func anEndedBackgroundTaskIsNotAskedForAgainByItself() async {
        let task = FakeContinuedWork()
        let defaults = defaults()
        let system = FakePackSystem(installed: [.vector], seconds: 0.02)
        system.script(.season2026, .init(hangs: 1))
        let store = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning, background: task)
        defer { store.shutdown() }
        store.fetch([.season2026, .season2025])
        #expect(await eventually { system.inFlight == 1 })
        store.appEnteredBackground()
        task.expire()
        #expect(defaults.stringArray(forKey: PackStore.queueKey) == ["season-2026", "season-2025"])
        #expect(!isFailed(store.state(.season2026)))
        store.appBecameActive()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(task.begun.count == 1, "no new task on didBecomeActive")
        system.finish(.season2026)
        #expect(await eventually { store.state(.season2025).isInstalled })
        // her next Get all: a new one
        store.fetch([.season2024, .season2023])
        #expect(task.begun.count == 2)
        #expect(await eventually { task.ended == true })
    }

    /// The real task class: a refused submit (iOS answers through the
    /// handler, later) leaves it not running.
    @Test func aRefusedSubmitClearsTheTask() async {
        let scheduler = RefusingScheduler()
        let task = AreaBackgroundTask(prefix: "org.gruenschloss.izzymap.packs", scheduler: scheduler)
        #expect(task.begin(title: "Downloading maps", subtitle: "x"))
        #expect(task.isRunning, "awaited until iOS answers")
        #expect(await eventually { !task.isRunning })
        #expect(scheduler.registered.count == 1 && scheduler.registered[0].hasPrefix("org.gruenschloss.izzymap.packs."))
        #expect(!AreaBackgroundTask.anyRunning)
    }
}

/// "No such asset pack", as Background Assets throws it.
enum ManagedBackgroundAssetsErrorProbe {
    static func notFound(_ pack: Pack) -> any Error {
        NSError(domain: "BAManagedErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: "No asset pack \(pack.rawValue)"])
    }
}

/// Registers, then refuses every request (asynchronously, like iOS).
nonisolated final class RefusingScheduler: ContinuedTaskScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var registered: [String] { lock.withLock { ids } }

    func register(_ id: String, launch: @escaping (BGTask) -> Void) -> Bool {
        lock.withLock { ids.append(id) }
        return true
    }

    func submit(_ request: BGContinuedProcessingTaskRequest, completion: @escaping @Sendable ((any Error)?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            completion(NSError(domain: "BGTaskSchedulerErrorDomain", code: 1))
        }
    }
}

/// Records what the store asks of the system's progress UI.
@MainActor
final class FakeContinuedWork: ContinuedWork {
    var onExpire: (() -> Void)?
    private(set) var isRunning = false
    private(set) var begun: [(title: String, subtitle: String)] = []
    private(set) var updates: [(done: Int, total: Int)] = []
    private(set) var subtitles: [String] = []
    private(set) var ended: Bool?

    func begin(title: String, subtitle: String) -> Bool {
        begun.append((title, subtitle))
        isRunning = true
        ended = nil
        return true
    }

    func update(done: Int, total: Int, title: String, subtitle: String) {
        updates.append((done, total))
        subtitles.append(subtitle)
    }

    func end(success: Bool) {
        isRunning = false
        ended = success
    }

    func expire() {
        onExpire?()
        isRunning = false
    }
}
