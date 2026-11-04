import Foundation
import IzzyKit
import os

/// Which batch a task belongs to: kind, batch generation, file id —
/// "kind|generation|id" in the task's `taskDescription`, so a relaunch can
/// still tell whose a finished task was, and a straggler of a cancelled
/// batch is never mistaken for the next batch's file of the same name.
nonisolated struct TransportTag: Hashable, Sendable, CustomStringConvertible {
    let kind: ExtraKind
    let generation: Int
    let id: String

    init(kind: ExtraKind, generation: Int, id: String) {
        self.kind = kind
        self.generation = generation
        self.id = id
    }

    /// Parses a task description; nil for anything else (the old
    /// two-field "kind|id" form included: its owner can't be known).
    init?(_ text: String?) {
        guard let parts = text?.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false),
              parts.count == 3, let kind = ExtraKind(rawValue: String(parts[0])),
              let generation = Int(parts[1]), !parts[2].isEmpty else { return nil }
        self.init(kind: kind, generation: generation, id: String(parts[2]))
    }

    var description: String { "\(kind.rawValue)|\(generation)|\(id)" }
}

/// Which session a task runs in. While the app is in the foreground,
/// batches use an ordinary session: no reception answers at once ("needs
/// reception"). Once the app leaves the foreground, the remaining work
/// moves to the background session, which the system carries on with
/// while the app is suspended or closed (and which, by design, WAITS for
/// connectivity instead of failing).
nonisolated enum TransportLane: Sendable, Hashable { case foreground, background }

/// One task the transport is running.
nonisolated struct TransportTask: Hashable, Sendable {
    let tag: TransportTag
    let lane: TransportLane
}

/// One file of a batch, finished (or failed) by the transport.
nonisolated struct TransportCompletion: Sendable {
    let tag: TransportTag
    let lane: TransportLane
    let result: FetchResult
    /// The body, staged in the store's incoming folder (nil on failure);
    /// the engine moves or deletes it.
    let file: URL?

    var kind: ExtraKind { tag.kind }
    var id: String { tag.id }
}

/// How a batch's files travel. The app uses `SessionTransport`; tests fake it.
nonisolated protocol ExtrasTransport: AnyObject, Sendable {
    /// Every task's completion, whoever started it (this launch's batches,
    /// a previous launch's background tasks). One consumer: the engine,
    /// which routes each by its tag.
    var completions: AsyncStream<TransportCompletion> { get }
    /// Completions handed to `completions` so far (the engine's settle
    /// check after a background wake).
    var delivered: Int { get }
    /// Starts one file.
    func start(_ item: ExtraItem, tag: TransportTag, lane: TransportLane)
    /// Tasks not complete yet, in either session.
    func live() async -> [TransportTask]
    /// Cancels the matching tasks (nil lane: both sessions) and returns once
    /// none of them is live any more (bounded wait).
    func cancel(lane: TransportLane?, where match: @escaping @Sendable (TransportTag) -> Bool) async
}

/// The URLSession transport: a foreground session (delegate-based, so both
/// lanes share one code path) and the background session.
///
/// Background sessions are delegate-only (async/await APIs throw for them)
/// and follow redirects on their own while the app is suspended, so the
/// host check happens on the final response URL too: a body that ended
/// off the publisher's hosts is discarded, never stored.
nonisolated final class SessionTransport: NSObject, ExtrasTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "org.gruenschloss.izzymap.extras"
    static let shared = SessionTransport(storage: .shared)

    /// Idle limit per request in the foreground (a stall), as for taps.
    static let foregroundTimeout: TimeInterval = 30

    private let storage: ExtrasStorage
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let stream: AsyncStream<TransportCompletion>
    private let sink: AsyncStream<TransportCompletion>.Continuation
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Extras")

    private struct StagingKey: Hashable {
        let lane: TransportLane
        let task: Int
    }

    private struct State {
        /// Between "finished downloading" and "complete": the staged body.
        var staged: [StagingKey: (file: URL?, result: FetchResult)] = [:]
        var delivered = 0
        /// The system's handlers from background wakes, waiting for
        /// "did finish events".
        var eventWaiters: [EventWaiter] = []
        /// "Did finish events" arrived before anyone waited (the session was
        /// created at launch, ahead of the scene's background-task handler).
        var eventsFinished = false
    }

    /// Resumes its continuation exactly once (events finished, or the
    /// safety timeout — whichever comes first).
    private final class EventWaiter: @unchecked Sendable {
        private let once = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Never>
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            let first = once.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume() }
        }
    }

    private let foregroundBox = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    /// The ordinary session (created on first use: it needs `self` as delegate).
    private var foreground: URLSession {
        foregroundBox.withLock { box in
            if let box { return box }
            let config = ExtrasNetwork.configuration(timeout: Self.foregroundTimeout)
            let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            box = s
            return s
        }
    }

    private let backgroundBox = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    /// Created on first use (reconnects to the system's session after a
    /// relaunch: queued events start arriving).
    private var background: URLSession {
        backgroundBox.withLock { box in
            if let box { return box }
            let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.httpMaximumConnectionsPerHost = 4
            config.urlCache = nil
            let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            box = s
            return s
        }
    }

    init(storage: ExtrasStorage) {
        self.storage = storage
        (stream, sink) = AsyncStream.makeStream(of: TransportCompletion.self)
        super.init()
    }

    var completions: AsyncStream<TransportCompletion> { stream }
    var delivered: Int { lock.withLock { $0.delivered } }

    /// Reconnects to the background session (call at launch, after the
    /// incoming sweep): a previous launch's finished tasks report now.
    func connect() { _ = background }

    /// The scene's `.backgroundTask(.urlSession(identifier))` hands over
    /// here; returns once the system has delivered every queued event, so
    /// the caller can let the system suspend the app. Never hangs: events
    /// that finished before this was called resume it at once, and a
    /// safety timeout covers a "did finish" that never comes.
    func handleEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = EventWaiter(continuation)
            let already = lock.withLock { s -> Bool in
                if s.eventsFinished {
                    s.eventsFinished = false
                    return true
                }
                s.eventWaiters.append(waiter)
                return false
            }
            if already {
                waiter.resume()
                return
            }
            _ = background
            Task {
                // the system allows ~30 s for a background wake
                try? await Task.sleep(for: .seconds(25))
                waiter.resume()
            }
        }
    }

    func start(_ item: ExtraItem, tag: TransportTag, lane: TransportLane) {
        // the app's one network gate (Connectivity.swift); the background
        // session can't carry a debug URLProtocol, so this is its only stop
        guard NetworkGate.allows(item.url, stubbed: lane == .foreground) else {
            lock.withLock { $0.delivered += 1 }
            sink.yield(TransportCompletion(tag: tag, lane: lane, result: .offline, file: nil))
            return
        }
        let session = lane == .foreground ? foreground : background
        let task = session.downloadTask(with: URLRequest(url: item.url))
        task.taskDescription = tag.description
        if let bytes = item.bytes { task.countOfBytesClientExpectsToReceive = Int64(bytes) }
        task.resume()
    }

    private func sessions() -> [(URLSession, TransportLane)] {
        [(foreground, .foreground), (background, .background)]
    }

    func live() async -> [TransportTask] {
        var out: [TransportTask] = []
        for (session, lane) in sessions() {
            for task in await session.allTasks where task.state == .running || task.state == .suspended {
                if let tag = TransportTag(task.taskDescription) { out.append(TransportTask(tag: tag, lane: lane)) }
            }
        }
        return out
    }

    func cancel(lane: TransportLane?, where match: @escaping @Sendable (TransportTag) -> Bool) async {
        let chosen = sessions().filter { lane == nil || $0.1 == lane }
        func matching() async -> [URLSessionTask] {
            var out: [URLSessionTask] = []
            for (session, _) in chosen {
                out += await session.allTasks.filter { task in
                    task.state != .completed && TransportTag(task.taskDescription).map(match) == true
                }
            }
            return out
        }
        for task in await matching() { task.cancel() }
        // cancelled tasks report (as cancelled) shortly; wait, bounded
        for _ in 0 ..< 100 {
            if await matching().isEmpty { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Self.logger.error("cancelled tasks still live after 5 s")
    }

    private func lane(of session: URLSession) -> TransportLane {
        session.configuration.identifier == Self.identifier ? .background : .foreground
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // a redirect off the publisher's hosts (a captive portal's usual
        // move) is refused while the app runs; the final-URL check below
        // covers the redirects a background session follows by itself
        guard let tag = TransportTag(task.taskDescription) else { return completionHandler(nil) }
        completionHandler(ExtrasCatalog.allows(host: request.url?.host(), for: tag.kind) ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the system deletes `location` when this returns: stage it now
        guard let tag = TransportTag(downloadTask.taskDescription) else { return }
        let staged = storage.stagingURL(tag.kind)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            Self.logger.error("staging failed: \(String(describing: error), privacy: .public)")
            return
        }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let result: FetchResult
        let file: URL?
        if (300 ..< 400).contains(status) {
            // a refused redirect ends here with the 3xx itself: never stored
            try? FileManager.default.removeItem(at: staged)
            (result, file) = (.response(status: 200, head: Data(), allowedHost: false), nil)
        } else {
            let allowed = ExtrasCatalog.allows(host: response?.url?.host(), for: tag.kind)
            (result, file) = ExtrasNetwork.checked(.response(status: status, head: fileHead(staged), allowedHost: allowed),
                                                   file: staged, kind: tag.kind)
        }
        let key = StagingKey(lane: lane(of: session), task: downloadTask.taskIdentifier)
        lock.withLock { $0.staged[key] = (file, result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let tag = TransportTag(task.taskDescription) else { return }
        let lane = lane(of: session)
        let key = StagingKey(lane: lane, task: task.taskIdentifier)
        let staged = lock.withLock { $0.staged.removeValue(forKey: key) }
        let completion: TransportCompletion
        if let error {
            if let file = staged?.file { try? FileManager.default.removeItem(at: file) }
            completion = TransportCompletion(tag: tag, lane: lane, result: ExtrasNetwork.result(of: error), file: nil)
        } else if let staged {
            completion = TransportCompletion(tag: tag, lane: lane, result: staged.result, file: staged.file)
        } else {
            completion = TransportCompletion(tag: tag, lane: lane, result: .failed, file: nil)
        }
        lock.withLock { $0.delivered += 1 }
        sink.yield(completion)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let waiters = lock.withLock { s -> [EventWaiter] in
            defer { s.eventWaiters = [] }
            if s.eventWaiters.isEmpty { s.eventsFinished = true }
            return s.eventWaiters
        }
        for w in waiters { w.resume() }
    }
}
