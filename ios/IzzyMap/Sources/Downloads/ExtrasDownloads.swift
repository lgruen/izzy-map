import Foundation
import IzzyKit
import Observation
import os
import UIKit

/// The one-tap extras: every F2F chapter, every plant photo, every tree
/// data sheet. One job per kind, independent of any screen (the Storage
/// screen of milestone 5 shows them; reopening it finds the running job).
/// The rules are IzzyKit's `ExtrasBatch`; this applies them to what the
/// transport delivers and keeps the files.
///
/// - **Ownership.** Each batch run takes a fresh generation; its tasks are
///   tagged kind|generation|id and the run waits for exactly the tasks it
///   started (`Run.outstanding`). Anything else that completes — a
///   cancelled batch's straggler, a previous launch's background task — is
///   an orphan: kept if it is a valid file Delete hasn't retired, never
///   counted towards the running batch.
/// - **Windows.** At most `ExtrasPolicy.concurrency` files are in flight;
///   each completion refills the window. A previous launch's live tasks
///   are counted, not started twice.
/// - **Lanes.** In the foreground the window runs on an ordinary session
///   (no reception fails at once: "needs reception"); when the app leaves
///   the foreground the in-flight files move to the background session and
///   later windows follow there, each refilled when the system wakes the
///   app for the finished ones (slower — the system paces those wakes —
///   but the batch's concurrency stays honoured).
/// - **Delete** really deletes: retire the kind's generations (nothing
///   started before is kept from now on, taps included), cancel and wait
///   for the tasks, then remove the files, staged downloads and marks.
@MainActor @Observable
final class ExtrasDownloads {
    static let shared = ExtrasDownloads(storage: .shared, transport: SessionTransport.shared)

    /// What a row shows for one kind.
    struct Job: Equatable {
        var batch: ExtrasBatch
        var isRunning: Bool { batch.phase == .running }

        static func == (a: Job, b: Job) -> Bool {
            a.batch.phase == b.batch.phase && a.batch.done == b.batch.done && a.batch.skippedCount == b.batch.skippedCount
                && a.batch.goneCount == b.batch.goneCount
        }
    }

    private(set) var jobs: [ExtraKind: Job] = [:]

    /// One batch run: its generation and the tasks it waits for (file id →
    /// the task, lane included: a file moved to the background lane waits
    /// for the background task, not the cancelled foreground one).
    private struct Run {
        let generation: Int
        var outstanding: [String: TransportTask] = [:]
    }

    @ObservationIgnored let storage: ExtrasStorage
    @ObservationIgnored private let transport: any ExtrasTransport
    @ObservationIgnored private var runs: [ExtraKind: Run] = [:]
    /// Generations handed out in this launch (an orphan of one of these
    /// was already judged by its batch).
    @ObservationIgnored private var thisLaunch: Set<TransportTag.Generation> = []
    /// Server errors this session: skipped until the app opens again.
    @ObservationIgnored private var skipped: [ExtraKind: Set<String>] = [:]
    @ObservationIgnored private(set) var lane: TransportLane = .foreground
    @ObservationIgnored private var consumed = 0
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var lifecycle: [Task<Void, Never>] = []
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Extras")

    init(storage: ExtrasStorage, transport: any ExtrasTransport) {
        self.storage = storage
        self.transport = transport
        let stream = transport.completions
        listener = Task { [weak self] in
            for await completion in stream {
                guard let self else { return }
                self.handle(completion)
            }
        }
    }

    /// At launch, in this order: drop staged leftovers (no session exists
    /// yet, so none can belong to a live task), reconnect to the background
    /// session (a previous launch's finished tasks report as orphans), cancel
    /// tasks Delete retired, and follow the app between foreground and
    /// background. Call once, from `App.init`.
    func launch(connect: () -> Void) {
        guard listener != nil, lifecycle.isEmpty else { return }
        storage.sweepIncoming()
        connect()
        let storage = storage
        let transport = transport
        lifecycle.append(Task {
            await transport.cancel(lane: nil) { !storage.isLive($0.kind, generation: $0.generation) }
        })
        lifecycle.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.setLane(.background)
            }
        })
        lifecycle.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                self?.setLane(.foreground)
            }
        })
    }

    /// After a background wake: returns once every completion the transport
    /// delivered has been applied (and the next windows started), so the
    /// system's handler isn't called with work still queued here.
    func settle() async {
        for _ in 0 ..< 200 where consumed < transport.delivered {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The batch's items, from the bundled tables.
    static func items(_ kind: ExtraKind, data: BundledData?, catalog: PlantCatalog?, trees: TreesData?) -> [ExtraItem] {
        switch kind {
        case .f2f: (try? data?.f2fIndex()).map(ExtrasCatalog.f2f) ?? []
        case .photos: catalog.map { ExtrasCatalog.photos($0.plants) } ?? []
        case .sheets: trees.map(ExtrasCatalog.sheets) ?? []
        }
    }

    /// Where a kind stands without starting anything (present/gone/total).
    func status(_ kind: ExtraKind, items: [ExtraItem]) -> ExtrasBatch {
        if let job = jobs[kind] { return job.batch }
        return ExtrasBatch(kind: kind, items: items, present: storage.storedNames(kind),
                           gone: storage.goneMarks(kind), skippedThisSession: skipped[kind] ?? [])
    }

    // MARK: Running a batch

    /// Starts (or resumes) a kind's batch: files already on the device,
    /// gone, or failed this session are skipped; files a live task is
    /// already fetching are waited for, not fetched again.
    func start(_ kind: ExtraKind, items: [ExtraItem]) {
        guard jobs[kind]?.isRunning != true else { return }
        var batch = ExtrasBatch(kind: kind, items: items, present: storage.storedNames(kind),
                                gone: storage.goneMarks(kind), skippedThisSession: skipped[kind] ?? [])
        batch.preflight(freeBytes: storage.freeBytes)
        jobs[kind] = Job(batch: batch)
        guard batch.phase == .running else { return }
        let generation = storage.nextGeneration(kind)
        thisLaunch.insert(TransportTag.Generation(kind: kind, number: generation))
        runs[kind] = Run(generation: generation)
        let transport = transport
        Task { [weak self] in
            let live = await transport.live()
            self?.begin(kind, generation: generation, live: live)
        }
    }

    /// Counts a previous launch's live tasks of this kind as in flight,
    /// then fills the window. (Tasks of this launch's earlier runs are
    /// being cancelled — that run stopped — so their files start afresh;
    /// whatever they still deliver is an orphan.)
    private func begin(_ kind: ExtraKind, generation: Int, live: [TransportTask]) {
        guard var run = runs[kind], run.generation == generation, var job = jobs[kind], job.isRunning else { return }
        for task in live where task.tag.kind == kind && storage.isLive(kind, generation: task.tag.generation)
            && !thisLaunch.contains(TransportTag.Generation(kind: kind, number: task.tag.generation)) {
            if run.outstanding[task.tag.id] != nil {
                // both lanes have it (caught mid-move): wait for the background one
                if task.lane == .background { run.outstanding[task.tag.id] = task }
            } else if job.batch.markInFlight(task.tag.id) {
                run.outstanding[task.tag.id] = task
            }
        }
        runs[kind] = run
        jobs[kind] = job
        pump(kind)
    }

    /// Starts files until the window is full.
    private func pump(_ kind: ExtraKind) {
        guard var job = jobs[kind], job.isRunning, var run = runs[kind] else { return }
        var started = false
        while let item = job.batch.nextToStart() {
            let tag = TransportTag(kind: kind, generation: run.generation, id: item.id)
            run.outstanding[item.id] = TransportTask(tag: tag, lane: lane)
            transport.start(item, tag: tag, lane: lane)
            started = true
        }
        guard started else { return }
        runs[kind] = run
        jobs[kind] = job
    }

    private func handle(_ c: TransportCompletion) {
        consumed += 1
        let kind = c.kind
        guard var run = runs[kind], run.outstanding[c.id] == TransportTask(tag: c.tag, lane: c.lane) else {
            orphan(c)
            return
        }
        run.outstanding[c.id] = nil
        runs[kind] = run
        guard var job = jobs[kind], job.isRunning else {
            // already on its way when the batch stopped: keep nothing
            discard(c.file)
            return
        }
        let before = job.batch.gone
        let verdict = job.batch.record(c.id, c.result)
        if verdict == .store, job.batch.present.contains(c.id), let file = c.file {
            do { try storage.adopt(file, as: kind, c.id, generation: c.tag.generation) } catch {
                Self.logger.error("couldn't keep \(c.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        } else {
            discard(c.file)
        }
        skipped[kind] = job.batch.skipped
        storage.mergeGone(kind, from: before, to: job.batch.gone)
        jobs[kind] = job
        if job.isRunning {
            pump(kind)
        } else if job.batch.phase == .finished {
            if runs[kind]?.outstanding.isEmpty == true { runs[kind] = nil }
        } else {
            stopTasks(kind)
        }
    }

    /// A completion no running batch is waiting for.
    private func orphan(_ c: TransportCompletion) {
        guard storage.isLive(c.kind, generation: c.tag.generation) else {
            // started before a Delete: licensed bytes don't come back
            discard(c.file)
            return
        }
        switch FetchVerdict.of(c.result, kind: c.kind) {
        case .store:
            guard let file = c.file else { return }
            if (try? storage.adopt(file, as: c.kind, c.id, generation: c.tag.generation)) != nil {
                storage.updateGone(c.kind) { $0.forget(c.id) }
            }
        case .gone:
            discard(c.file)
            // only a previous launch's verdict: a batch of THIS launch has
            // already judged its stragglers (and may have undone a streak)
            if !thisLaunch.contains(TransportTag.Generation(kind: c.kind, number: c.tag.generation)) {
                storage.updateGone(c.kind) { $0.mark(c.id) }
            }
        default:
            discard(c.file)
        }
    }

    private func discard(_ file: URL?) {
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Cancels the tasks a stopped run still waits for (its own only).
    private func stopTasks(_ kind: ExtraKind) {
        guard let run = runs[kind], !run.outstanding.isEmpty else { return }
        let tags = Set(run.outstanding.values.map(\.tag))
        let transport = transport
        Task { await transport.cancel(lane: nil) { tags.contains($0) } }
    }

    func cancel(_ kind: ExtraKind) {
        guard var job = jobs[kind], job.isRunning else { return }
        job.batch.cancel()
        jobs[kind] = job
        stopTasks(kind)
    }

    /// Removes every file of a kind, its staged downloads and its gone
    /// marks (Delete). Nothing fetched before this call is kept afterwards.
    func delete(_ kind: ExtraKind) async {
        storage.retire(kind)
        if var job = jobs[kind], job.isRunning {
            job.batch.cancel()
            jobs[kind] = job
        }
        // from here every completion of the kind is an orphan below the floor
        runs[kind] = nil
        await transport.cancel(lane: nil) { $0.kind == kind }
        storage.deleteAll(kind)
        jobs[kind] = nil
        skipped[kind] = nil
    }

    // MARK: Foreground ↔ background

    /// Where new tasks go. Leaving the foreground moves the files in flight
    /// to the background session (restarted there; the foreground tasks
    /// are cancelled and their completions ignored), so the system carries
    /// on while the app is suspended. Coming back, background tasks finish
    /// where they are and new windows start in the foreground again.
    func setLane(_ new: TransportLane) {
        guard new != lane else { return }
        lane = new
        guard new == .background else { return }
        for (kind, var run) in runs {
            guard let job = jobs[kind], job.isRunning else { continue }
            let moving = run.outstanding.values.filter { $0.lane == .foreground }
            guard !moving.isEmpty else { continue }
            for task in moving {
                guard let item = job.batch.items.first(where: { $0.id == task.tag.id }) else { continue }
                run.outstanding[task.tag.id] = TransportTask(tag: task.tag, lane: .background)
                transport.start(item, tag: task.tag, lane: .background)
            }
            runs[kind] = run
            let tags = Set(moving.map(\.tag))
            let transport = transport
            Task { await transport.cancel(lane: .foreground) { tags.contains($0) } }
        }
    }
}

extension TransportTag {
    /// A kind's batch generation.
    nonisolated struct Generation: Hashable, Sendable {
        let kind: ExtraKind
        let number: Int
    }
}
