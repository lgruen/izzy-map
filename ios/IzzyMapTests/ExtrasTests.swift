import CoreLocation
import Foundation
import IzzyKit
import Testing
import UIKit
@testable import IzzyMap

/// A transport the test drives. With `auto`, each started task answers at
/// once from `script` (a missing id fails as offline); otherwise tasks stay
/// live until the test completes or fails them.
nonisolated final class FakeTransport: ExtrasTransport, @unchecked Sendable {
    let storage: ExtrasStorage
    private let lock = NSLock()
    var auto = true
    /// id → (status, body)
    var script: [String: (Int, Data)] = [:]
    /// Tasks whose cancel comes too late: they had already finished (not
    /// live any more), and report their real result when the test says.
    var finishing: Set<String> = []
    private var _started: [TransportTask] = []
    private var _cancelled: [TransportTask] = []
    private var _live: [TransportTask] = []
    private var _delivered = 0
    private let stream: AsyncStream<TransportCompletion>
    private let sink: AsyncStream<TransportCompletion>.Continuation

    init(storage: ExtrasStorage, live: [TransportTask] = []) {
        self.storage = storage
        _live = live
        (stream, sink) = AsyncStream.makeStream(of: TransportCompletion.self)
    }

    var started: [TransportTask] { lock.withLock { _started } }
    var cancelled: [TransportTask] { lock.withLock { _cancelled } }
    var completions: AsyncStream<TransportCompletion> { stream }
    var delivered: Int { lock.withLock { _delivered } }

    func start(_ item: ExtraItem, tag: TransportTag, lane: TransportLane) {
        let task = TransportTask(tag: tag, lane: lane)
        lock.withLock {
            _started.append(task)
            _live.append(task)
        }
        guard auto else { return }
        if let (status, body) = script[tag.id] { complete(task, status: status, body: body) } else { fail(task, .offline) }
    }

    /// Finishes a task with a body, staged like the real transport does.
    func complete(_ task: TransportTask, status: Int = 200, body: Data) {
        let file = storage.stagingURL(task.tag.kind)
        try? body.write(to: file)
        deliver(TransportCompletion(tag: task.tag, lane: task.lane,
                                    result: .response(status: status, head: body.prefix(16), allowedHost: true), file: file))
    }

    func fail(_ task: TransportTask, _ result: FetchResult) {
        deliver(TransportCompletion(tag: task.tag, lane: task.lane, result: result, file: nil))
    }

    private func deliver(_ c: TransportCompletion) {
        lock.withLock {
            _live.removeAll { $0 == TransportTask(tag: c.tag, lane: c.lane) }
            _delivered += 1
        }
        sink.yield(c)
    }

    func live() async -> [TransportTask] { lock.withLock { _live } }

    func cancel(lane: TransportLane?, where match: @escaping @Sendable (TransportTag) -> Bool) async {
        let hit = lock.withLock { () -> [TransportTask] in
            let hit = _live.filter { (lane == nil || $0.lane == lane) && match($0.tag) }
            _cancelled += hit
            _live.removeAll { hit.contains($0) }
            return hit
        }
        for task in hit where !finishing.contains(task.tag.id) { fail(task, .cancelled) }
    }
}

/// Waits (briefly) until `condition` holds.
@MainActor func eventually(_ condition: () -> Bool) async {
    for _ in 0 ..< 300 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
struct ExtrasDownloadsTests {
    nonisolated static let pdf = Data("%PDF-1.4 test".utf8)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0])
    static let html = Data("<html>login</html>".utf8)

    let storage: ExtrasStorage
    init() {
        storage = ExtrasStorage(root: URL.temporaryDirectory.appending(path: "extras-\(UUID().uuidString)"))
    }

    static func items(_ n: Int) -> [ExtraItem] {
        (0 ..< n).map { ExtraItem(id: "s\($0).pdf", url: URL(string: "https://www.arcgis.com/x/\($0)")!, bytes: 10) }
    }

    static func photos(_ n: Int) -> [ExtraItem] {
        (0 ..< n).map { ExtraItem(id: "p\($0).jpg", url: URL(string: "https://database.understorey-network.org.au/\($0)")!, bytes: 5) }
    }

    private func staged() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: storage.incoming.path(percentEncoded: false))) ?? []
    }

    private func finish(_ d: ExtrasDownloads, _ kind: ExtraKind) async {
        await eventually { d.jobs[kind]?.isRunning != true }
        await d.settle()
    }

    private func task(_ t: FakeTransport, _ id: String, lane: TransportLane = .foreground) -> TransportTask? {
        t.started.last { $0.tag.id == id && $0.lane == lane }
    }

    @Test func storesGoneAndResumes() async throws {
        let t = FakeTransport(storage: storage)
        t.script = ["s0.pdf": (200, Self.pdf), "s1.pdf": (400, Self.html), "s2.pdf": (200, Self.pdf)]
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.sheets, items: Self.items(3))
        await finish(d, .sheets)
        #expect(d.jobs[.sheets]?.batch.phase == .finished)
        #expect(storage.storedNames(.sheets) == ["s0.pdf", "s2.pdf"])
        #expect(storage.goneMarks(.sheets).contains("s1.pdf"))
        #expect(d.jobs[.sheets]?.batch.statusText == "✓ downloaded · 1 sheet no longer published")
        // resume: nothing left to fetch
        let t2 = FakeTransport(storage: storage)
        let again = ExtrasDownloads(storage: storage, transport: t2)
        again.start(.sheets, items: Self.items(3))
        #expect(again.jobs[.sheets]?.batch.phase == .finished)
        await again.settle()
        #expect(t2.started.isEmpty)
        // delete clears files and marks
        await again.delete(.sheets)
        #expect(storage.storedNames(.sheets).isEmpty)
        #expect(storage.goneMarks(.sheets).count == 0)
    }

    @Test func fiveGoneInARowIsAPortal() async throws {
        let t = FakeTransport(storage: storage)
        for i in 0 ..< 8 { t.script["s\(i).pdf"] = (400, Self.html) }
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.sheets, items: Self.items(8))
        await finish(d, .sheets)
        #expect(d.jobs[.sheets]?.batch.phase == .stopped(.captivePortal))
        #expect(storage.goneMarks(.sheets).count == 0)  // the streak's marks undone
        #expect(storage.storedNames(.sheets).isEmpty)
        #expect(staged().isEmpty)  // nothing left staged
        // two at a time: never more than the window ahead of the verdicts
        #expect(t.started.count <= 6)
    }

    @Test func aLoginPageStopsPhotos() async {
        let t = FakeTransport(storage: storage)
        t.script = ["p0.jpg": (200, Self.jpeg), "p1.jpg": (200, Self.html), "p2.jpg": (200, Self.jpeg)]
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.photos, items: Self.photos(3))
        await finish(d, .photos)
        #expect(d.jobs[.photos]?.batch.phase == .stopped(.captivePortal))
        #expect(storage.storedNames(.photos) == ["p0.jpg"])
        #expect(staged().isEmpty)
    }

    @Test func offlineStopsAndKeepsWhatArrived() async {
        let t = FakeTransport(storage: storage)
        t.script = ["s0.pdf": (200, Self.pdf)]  // s1 has no answer: offline
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.sheets, items: Self.items(3))
        await finish(d, .sheets)
        #expect(d.jobs[.sheets]?.batch.phase == .stopped(.offline))
        #expect(d.jobs[.sheets]?.batch.statusText == "Stopped — needs reception. What arrived is kept.")
        #expect(storage.storedNames(.sheets) == ["s0.pdf"])
    }

    /// Finding 1: a cancelled batch's stragglers belong to ITS generation —
    /// they never finish, count towards or stop the next batch.
    @Test func staleCompletionsNeverLeakIntoTheNextBatch() async throws {
        let t = FakeTransport(storage: storage)
        t.auto = false
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.sheets, items: Self.items(3))
        await eventually { t.started.count == 2 }
        let old0 = try #require(task(t, "s0.pdf")), old1 = try #require(task(t, "s1.pdf"))
        t.finishing = ["s0.pdf", "s1.pdf"]  // too late to cancel: they will still report
        d.cancel(.sheets)
        #expect(d.jobs[.sheets]?.batch.phase == .stopped(.cancelled))
        await eventually { t.cancelled.count == 2 }
        // the next batch
        d.start(.sheets, items: Self.items(3))
        await eventually { t.started.count == 4 }
        let new0 = try #require(task(t, "s0.pdf")), new1 = try #require(task(t, "s1.pdf"))
        #expect(new0.tag.generation > old0.tag.generation)
        // the old batch's stragglers arrive: a failure must not stop it, a
        // success must not count as its file
        t.fail(old1, .offline)
        t.complete(old0, body: Self.pdf)
        await d.settle()
        #expect(d.jobs[.sheets]?.isRunning == true)
        #expect(d.jobs[.sheets]?.batch.present.isEmpty == true)
        #expect(t.started.count == 4)  // no slot was freed by them
        // the straggler's valid file is still kept (Delete didn't retire it)
        #expect(storage.storedNames(.sheets) == ["s0.pdf"])
        // its own completions do count
        t.complete(new0, body: Self.pdf)
        t.complete(new1, body: Self.pdf)
        await eventually { t.started.count == 5 }
        t.complete(try #require(task(t, "s2.pdf")), body: Self.pdf)
        await finish(d, .sheets)
        #expect(d.jobs[.sheets]?.batch.phase == .finished)
        #expect(staged().isEmpty)
    }

    /// Tasks a previous launch left running are waited for, never started twice.
    @Test func liveTasksAreCountedNotRestarted() async throws {
        let previous = TransportTask(tag: TransportTag(kind: .sheets, generation: 0, id: "s1.pdf"), lane: .background)
        let t = FakeTransport(storage: storage, live: [previous])
        t.auto = false
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.sheets, items: Self.items(3))
        await eventually { !t.started.isEmpty }
        await d.settle()
        #expect(t.started.map(\.tag.id) == ["s0.pdf"])  // window of 2: s1 is already in flight
        t.complete(previous, body: Self.pdf)
        await eventually { t.started.count == 2 }
        #expect(d.jobs[.sheets]?.batch.present == ["s1.pdf"])
        #expect(t.started.last?.tag.id == "s2.pdf")
    }

    /// Finding 2: Delete really deletes — files, staged downloads, marks —
    /// and nothing that was in flight comes back afterwards.
    @Test func deleteLeavesNothingAndRetiresWhatWasInFlight() async throws {
        let t = FakeTransport(storage: storage)
        t.auto = false
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.sheets, items: Self.items(4))
        await eventually { t.started.count == 2 }
        t.complete(try #require(task(t, "s0.pdf")), body: Self.pdf)
        await eventually { storage.storedNames(.sheets) == ["s0.pdf"] }
        storage.updateGone(.sheets) { $0.mark("old.pdf") }
        let tapGeneration = storage.generation(.sheets)  // a tap fetch in flight
        let late = try #require(task(t, "s1.pdf"))
        t.finishing = ["s1.pdf"]  // reports after Delete
        try Data("leftover".utf8).write(to: storage.stagingURL(.sheets))
        await d.delete(.sheets)
        #expect(storage.storedNames(.sheets).isEmpty)
        #expect(storage.goneMarks(.sheets).count == 0)
        #expect(staged().isEmpty)
        #expect(d.jobs[.sheets] == nil)
        // the straggler lands: not adopted, its staged file removed
        t.complete(late, body: Self.pdf)
        await d.settle()
        #expect(storage.storedNames(.sheets).isEmpty)
        #expect(staged().isEmpty)
        // the tap fetch lands: refused, its download removed
        let tap = URL.temporaryDirectory.appending(path: "tap-\(UUID().uuidString)")
        try Self.pdf.write(to: tap)
        #expect(throws: ExtrasStorage.AdoptError.self) {
            try storage.adopt(tap, as: .sheets, "t.pdf", generation: tapGeneration)
        }
        #expect(!FileManager.default.fileExists(atPath: tap.path(percentEncoded: false)))
        // a new batch after Delete works as usual
        let before = t.started.count
        d.start(.sheets, items: Self.items(1))
        await eventually { t.started.count == before + 1 }
        t.complete(try #require(task(t, "s0.pdf")), body: Self.pdf)
        await finish(d, .sheets)
        #expect(storage.storedNames(.sheets) == ["s0.pdf"])
    }

    @Test func launchSweepsStagedFilesAndCancelsRetiredTasks() async throws {
        try Data("x".utf8).write(to: storage.stagingURL(.photos))
        storage.retire(.sheets)
        let retired = TransportTask(tag: TransportTag(kind: .sheets, generation: 0, id: "a.pdf"), lane: .background)
        let current = TransportTask(tag: TransportTag(kind: .photos, generation: 0, id: "b.jpg"), lane: .background)
        let t = FakeTransport(storage: storage, live: [retired, current])
        let d = ExtrasDownloads(storage: storage, transport: t)
        var connected = false
        d.launch { connected = true }
        #expect(connected)
        #expect(staged().isEmpty)
        await eventually { !t.cancelled.isEmpty }
        #expect(t.cancelled == [retired])
    }

    @Test func aFailedAdoptLeavesNoStagedFile() throws {
        let temp = storage.stagingURL(.sheets)
        try Self.pdf.write(to: temp)
        #expect(throws: (any Error).self) {
            try storage.adopt(temp, as: .sheets, "no-such-folder/x.pdf", generation: storage.generation(.sheets))
        }
        #expect(staged().isEmpty)
    }

    /// Finding 6: windows of the kind's concurrency; one stall retries
    /// without killing the batch; leaving the foreground moves the window
    /// to the background session; no reception stops it.
    @Test func windowsRetriesAndLanes() async throws {
        let t = FakeTransport(storage: storage)
        t.auto = false
        let d = ExtrasDownloads(storage: storage, transport: t)
        d.start(.photos, items: Self.photos(10))
        await eventually { t.started.count == 4 }
        await d.settle()
        #expect(t.started.count == 4)
        #expect(t.started.allSatisfy { $0.lane == .foreground })
        // one stall: the same file goes out again, the batch runs on
        t.fail(try #require(task(t, "p0.jpg")), .timedOut)
        await eventually { t.started.count == 5 }
        #expect(t.started.last?.tag.id == "p0.jpg")
        #expect(d.jobs[.photos]?.isRunning == true)
        t.complete(try #require(task(t, "p1.jpg")), body: Self.jpeg)
        await eventually { t.started.count == 6 }
        #expect(t.started.last?.tag.id == "p4.jpg")
        // the app leaves the foreground: the window moves
        d.setLane(.background)
        await eventually { t.cancelled.count == 4 }
        let moved = t.started.filter { $0.lane == .background }.map(\.tag.id).sorted()
        #expect(moved == ["p0.jpg", "p2.jpg", "p3.jpg", "p4.jpg"])
        #expect(t.cancelled.allSatisfy { $0.lane == .foreground })
        await d.settle()
        #expect(d.jobs[.photos]?.isRunning == true)  // the cancelled foreground tasks don't count
        // a background completion refills the window in the background
        t.complete(try #require(task(t, "p2.jpg", lane: .background)), body: Self.jpeg)
        await eventually { t.started.count == 11 }
        #expect(t.started.last?.tag.id == "p5.jpg" && t.started.last?.lane == .background)
        // no reception stops the batch
        t.fail(try #require(task(t, "p3.jpg", lane: .background)), .offline)
        await finish(d, .photos)
        #expect(d.jobs[.photos]?.batch.phase == .stopped(.offline))
        #expect(storage.storedNames(.photos) == ["p1.jpg", "p2.jpg"])
    }

    /// Finding 8: marks and adoption have one owner.
    @Test func concurrentMarksAndAdoptsDontRace() throws {
        let storage = storage
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            storage.updateGone(.sheets) { $0.mark("m\(i)") }
        }
        #expect(storage.goneMarks(.sheets).count == 200)
        let failures = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            let temp = storage.stagingURL(.sheets)
            do {
                try Self.pdf.write(to: temp)
                try storage.adopt(temp, as: .sheets, "same.pdf", generation: storage.generation(.sheets))
            } catch { failures.add() }
        }
        #expect(failures.count == 0)
        #expect(storage.storedNames(.sheets) == ["same.pdf"])
        #expect(staged().isEmpty)
    }

    @Test func itemsFromTheBundledTables() {
        let data = BundledData.inBundle()
        let f2f = ExtrasDownloads.items(.f2f, data: data, catalog: nil, trees: nil)
        #expect(f2f.count == 11)
        #expect(f2f.allSatisfy { ($0.bytes ?? 0) > 0 })  // sizes from f2f_index.json
        let trees = try? data?.trees()
        #expect(ExtrasDownloads.items(.sheets, data: data, catalog: nil, trees: trees).count == trees?.sheets.count)
    }
}

nonisolated final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

/// Answers every request with whatever the test set.
nonisolated final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data)?
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        guard let (status, body) = Self.response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let r = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct DocumentStoreTests {
    let storage = ExtrasStorage(root: URL.temporaryDirectory.appending(path: "docs-\(UUID().uuidString)"))
    let store: DocumentStore
    static let sheet = DocumentRef.sheet(item: "abc123", title: "Test", bytes: 600_000)
    /// A real (12-page) PDF.
    static let pdf = StubNetwork.pdf

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        store = DocumentStore(storage: storage, session: URLSession(configuration: config))
    }

    @Test func fetchesOnceThenOpensFromDisk() async throws {
        ScriptedURLProtocol.response = (200, Self.pdf)
        ScriptedURLProtocol.requests = 0
        let url = try await store.open(Self.sheet)
        #expect(url.lastPathComponent == "abc123.pdf")
        #expect(store.localURL(Self.sheet) == url)
        _ = try await store.open(Self.sheet)
        #expect(ScriptedURLProtocol.requests == 1)
    }

    @Test func eachCauseHasItsError() async {
        for (response, want) in [((400, Data("<html>".utf8)), DocumentError.gone),
                                 ((200, Data("<html>login".utf8)), .notPDF),
                                 ((503, Data()), .failed(status: 503))] as [((Int, Data), DocumentError)] {
            ScriptedURLProtocol.response = response
            do {
                _ = try await store.open(Self.sheet)
                Issue.record("expected \(want)")
            } catch {
                #expect(error == want)
            }
            #expect(store.localURL(Self.sheet) == nil)
        }
        #expect(store.isGone(Self.sheet))
        ScriptedURLProtocol.response = nil
        do { _ = try await store.open(Self.sheet) } catch { #expect(error == .offline) }
        // a gone sheet is still tried; success forgets the mark
        ScriptedURLProtocol.response = (200, Self.pdf)
        _ = try? await store.open(Self.sheet)
        #expect(!store.isGone(Self.sheet))
    }

    /// Finding 7: "%PDF" and then garbage is a failed transfer, never kept;
    /// a stored file that no longer opens is fetched again.
    @Test func aPDFMustOpenToBeKept() async throws {
        ScriptedURLProtocol.response = (200, Data("%PDF-1.7\n% cut off here".utf8))
        do {
            _ = try await store.open(Self.sheet)
            Issue.record("a broken PDF was accepted")
        } catch {
            #expect(error == .failed(status: nil))
        }
        #expect(store.localURL(Self.sheet) == nil)
        // a broken file already on the device (kept by an older build)
        _ = try storage.write(Data("%PDF-1.4 junk".utf8), as: .sheets, "abc123.pdf")
        ScriptedURLProtocol.response = (200, Self.pdf)
        ScriptedURLProtocol.requests = 0
        let url = try await store.open(Self.sheet)
        #expect(ScriptedURLProtocol.requests == 1)
        #expect(DocumentCheck.opens(url))
        // the reader's "Download Again" drops the stored copy
        await store.discard(Self.sheet)
        #expect(store.localURL(Self.sheet) == nil)
    }

    @Test func messagesPerCause() {
        let sheet = Self.sheet
        #expect(DocumentError.cancelled.message(for: sheet, device: "iPhone", sheetsTotal: nil) == nil)
        #expect(DocumentError.offline.message(for: sheet, device: "iPhone", sheetsTotal: 446_000_000)?
            .contains("get all sheets (446\u{00A0}MB) in Storage") == true)
        #expect(DocumentError.gone.message(for: sheet, device: "iPhone", sheetsTotal: nil) == "This data sheet is no longer published by the council.")
        #expect(DocumentError.notPDF.message(for: sheet, device: "iPhone", sheetsTotal: nil)?.contains("Wi-Fi login page") == true)
    }

    @Test func tapFetchesIdleNotWholeTransferTimeout() {
        let config = ExtrasNetwork.configuration(timeout: DocumentStore.timeout)
        #expect(config.timeoutIntervalForRequest == 30)
        #expect(config.timeoutIntervalForResource >= 300)
    }
}

/// Finding 5: the reader is the first step of the Escape chain.
@MainActor
struct ReaderEscapeTests {
    @Test func escapeClosesTheReaderNotTheCard() {
        let model = AppModel(data: .none, tables: MapTables())
        model.selectCommunity(code: "DOB", sourceName: nil, at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.2))
        model.present(.attribution)
        let doc = DocumentRef.f2f(file: "f2f_dry_eucalypt.pdf", page: 3, title: "Eucalyptus obliqua dry forest")
        model.documents.reading = DocumentOpener.Reading(doc: doc, url: URL(filePath: "/tmp/x.pdf"), page: 3)
        #expect(model.escapeStep == .closeDocument)
        #expect(model.escapeStep?.title == "Close Document")
        model.escape()
        #expect(model.documents.reading == nil)
        #expect(model.selection != nil)
        #expect(model.escapeStep == .dismiss(.attribution))
    }

    @Test func aNewCardEndsTheOldCardsFetches() {
        let opener = DocumentOpener()
        opener.failure = .init(doc: .sheet(item: "a", title: "A", bytes: nil), title: "Open the data sheet", message: "x")
        opener.selectionChanged()
        #expect(opener.failure == nil)
        #expect(opener.fetching.isEmpty)
    }
}
