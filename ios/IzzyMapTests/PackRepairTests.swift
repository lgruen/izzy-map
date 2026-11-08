import Foundation
import IzzyKit
import Synchronization
import Testing
@testable import IzzyMap

/// Packs the system has that the app won't use: files cut short (the iPad
/// ran out of space mid-download, 2026-11-06) or lookups iOS refuses (an
/// iPhone after an automatic repair, 2026-11-08). Never handed to the map
/// or Core ML, NEVER removed by the app, never re-requested; the row and
/// the Storage note name the fix. Over `FakePackSystem` with real,
/// truncated files in its directory.
@MainActor
@Suite(.serialized)
struct PackRepairTests {
    static var tuning: PackStore.Tuning {
        var t = PackQueueTests.tuning
        t.blockedAfter = .milliseconds(250)
        return t
    }

    /// No removal ("-id") in what the store asked of the system.
    private func noRemovals(_ system: FakePackSystem) -> Bool { !system.calls.contains { $0.hasPrefix("-") } }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "PackRepairTests-\(UUID().uuidString)")! }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "repair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func truncate(_ url: URL, by bytes: Int) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let h = try! FileHandle(forWritingTo: url)
        try! h.truncate(atOffset: UInt64(max(0, size - bytes)))
        try! h.close()
    }

    /// A small valid PMTiles archive; its bytes (to "download" it again).
    private static func pmtiles(_ url: URL) throws -> Data {
        let w = try PMTilesWriter(destination: url, tileType: .png)
        for x in 0 ..< 32 { try w.add(z: 8, x: x, y: 100, data: Data(repeating: UInt8(x), count: 700 + x)) }
        _ = try w.finish(name: "t", attribution: "t", metadata: [:])
        return try Data(contentsOf: url)
    }

    /// A Core ML blob file (`PackIntegrity.blobFile`'s format).
    private static func blobFile(_ sizes: [Int]) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = le(UInt32(sizes.count)) + le(UInt32(2)) + Data(count: 56)
        for size in sizes {
            d += le(UInt32(0xDEAD_BEEF)) + le(UInt32(4)) + le(UInt64(size)) + le(UInt64(d.count + 64)) + Data(count: 40)
            d += Data(repeating: 7, count: size)
            d += Data(count: (64 - d.count % 64) % 64)
        }
        return d
    }

    /// `<dir>/plantid/` as the pack ships it (tiny); the head's full bytes.
    private static func plantID(in dir: URL) throws -> (folder: URL, head: Data) {
        let folder = dir.appending(path: PlantIDFiles.folder, directoryHint: .isDirectory)
        let encoder = folder.appending(path: "\(PlantIDFiles.encoder)/weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
        let head = Data(repeating: 1, count: 8192)
        var files: [String: Any] = [:]
        for (name, data) in [("v3-head.bin", head), ("v3-prior.bin", Data(repeating: 2, count: 900)),
                             ("v2-labels.json", Data("{}".utf8)), ("bank-int8.bin", Data(repeating: 3, count: 640)),
                             ("credits.json", Data("{}".utf8)), ("credits-photos.tsv.gz", Data(repeating: 4, count: 30))] {
            try data.write(to: folder.appending(path: name))
            files[name] = ["bytes": data.count, "sha256": "-"]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "files": files]).write(to: folder.appending(path: PlantIDFiles.pipeline))
        try blobFile([500, 900]).write(to: encoder.appending(path: "weight.bin"))
        let mlmodelc = encoder.deletingLastPathComponent()
        try Data("program(1.0)\n{\n}\n".utf8).write(to: mlmodelc.appending(path: "model.mil"))
        try Data(repeating: 0, count: 64).write(to: mlmodelc.appending(path: "coremldata.bin"))
        return (folder, head)
    }

    // MARK: PMTiles

    @Test func truncatedArchiveIsHiddenAndNeverRemoved() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.topo], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        // never handed to the map; the row and the note say what's wrong
        #expect(store.location.url(for: .topo) == nil)
        #expect(store.errorLog[.topo]?.first?.stage == "integrity")
        #expect(store.errorLog[.topo]?.first?.text.contains("topo_tas.pmtiles TRUNCATED (have ") == true)
        #expect(store.state(.topo) == .failed(PackStore.damaged))
        let storage = StorageModel(packs: store, trees: nil)
        guard case .unusable(.incomplete) = storage.status(.topo) else { Issue.record("row: \(storage.status(.topo))"); return }
        #expect(storage.status(.topo).text(bytes: 1000, device: "iPad").hasPrefix("Incomplete on this iPad"))
        #expect(!storage.status(.topo).offersGet)
        #expect(storage.unusableNote?.contains("install it again from TestFlight") == true)
        // looking again, and even a fetch, ask nothing of the system
        await store.resync()
        try? await Task.sleep(for: .milliseconds(300))
        await store.resync()
        store.fetch(.topo)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(system.calls.isEmpty)
        #expect(store.errorLog[.topo]?.count == 1)   // logged once per failure
    }

    /// The files come right (the system replaced them): installed, no note.
    @Test func completeFilesClearTheState() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        let full = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.topo], directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.unusable[.topo] != nil)
        try full.write(to: url)
        await store.resync()
        #expect(await eventually { store.state(.topo).isInstalled })
        #expect(store.location.url(for: .topo) == url)
        #expect(store.unusable.isEmpty)
        #expect(StorageModel(packs: store, trees: nil).unusableNote == nil)
        #expect(system.calls.isEmpty)
    }

    @Test func aCompletePackIsCheckedOncePerVersion() async throws {
        let dir = try tempDir()
        _ = try Self.pmtiles(dir.appending(path: Archive.topo.fileName))
        let defaults = defaults()
        defaults.set(["topo": [1, 2]], forKey: PackStore.retiredRepairsKey)
        let system = FakePackSystem(installed: [.topo], directory: dir)
        let store = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning)
        #expect(store.state(.topo).isInstalled && store.integrity[.topo]?.isDamaged == false)
        #expect(defaults.object(forKey: PackStore.retiredRepairsKey) == nil)   // old counters cleared
        store.shutdown()
        // the next launch: the same files passed — not read again
        let passed = defaults.dictionary(forKey: PackStore.integrityKey) as? [String: String]
        #expect(passed?["topo"] != nil)
        let again = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning)
        defer { again.shutdown() }
        #expect(again.state(.topo).isInstalled && again.integrity[.topo] == nil)
        #expect(system.calls.isEmpty)
    }

    /// While the system downloads (updates) the pack, it isn't judged; once
    /// that ends with the files still short, it's unusable — not removed.
    @Test func notJudgedWhileTheSystemDownloadsThePack() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.topo], downloading: [.topo: 0.5], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.unusable[.topo] == nil)
        if case .downloading = store.state(.topo) {} else { Issue.record("state: \(store.state(.topo))") }
        system.drop(.topo)
        await store.resync()
        #expect(await eventually { store.state(.topo) == .failed(PackStore.damaged) })
        #expect(noRemovals(system))
    }

    // MARK: Refused lookups

    /// iOS refuses the lookups (`url(for:)` throws): "won't open", no
    /// Retry, no request, and plant ID isn't mistaken for an older version.
    @Test func refusedLookupsAreBlockedNotRetried() async throws {
        let system = FakePackSystem(installed: [.vector, .plantid], seconds: 0.05, returnDelay: 0.05)
        system.setRefused(.vector, true)
        system.setRefused(.plantid, true)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        // at first only unreadable for now (a refusal may pass): no reinstall advice yet
        #expect(store.state(.vector) == .failed(PackStore.unreadable))
        #expect(store.unusable.isEmpty)
        #expect(StorageModel(packs: store, trees: nil).unusableNote == nil)
        // still refused after `blockedAfter`: iOS won't open it
        #expect(await eventually { store.unusable == [.vector: .blocked, .plantid: .blocked] })
        #expect(store.state(.vector) == .failed(PackStore.blocked))
        #expect(!store.outdated.contains(.plantid))
        let storage = StorageModel(packs: store, trees: nil)
        #expect(storage.status(.vector) == .unusable(.blocked))
        #expect(storage.status(.vector).text(bytes: 1000, device: "iPhone").hasPrefix("On this iPhone, but iOS won't open it"))
        #expect(storage.unusableNote?.hasPrefix("iOS won't let IzzyMap open") == true)
        store.fetch(.vector)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(system.calls.isEmpty)
        // iOS lets go again (after a reinstall, say): installed
        system.setRefused(.vector, false)
        await store.resync()
        #expect(await eventually { store.state(.vector).isInstalled })
        #expect(store.unusable[.vector] == nil)
    }

    /// Refused while the system downloads (updates) the pack: not judged.
    @Test func refusedDuringAnUpdateIsNotJudged() async throws {
        let system = FakePackSystem(installed: [.topo], downloading: [.topo: 0.4], seconds: 0.05, returnDelay: 0.05)
        system.setRefused(.topo, true)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        try? await Task.sleep(for: .milliseconds(600))
        await store.resync()
        #expect(store.unusable.isEmpty)
        if case .downloading = store.state(.topo) {} else { Issue.record("state: \(store.state(.topo))") }
        #expect(noRemovals(system))
    }

    /// A refused pack that leaves the device: plain "not here" again.
    @Test func refusedPackThatLeavesIsNotInstalled() async throws {
        let system = FakePackSystem(installed: [.tasmap], seconds: 0.05, returnDelay: 0.05)
        system.setRefused(.tasmap, true)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(await eventually { store.unusable[.tasmap] == .blocked })
        // no trash for refused lookups: reinstalling is the fix
        #expect(StorageModel(packs: store, trees: nil).status(.tasmap) == .unusable(.blocked))
        try await system.remove("tasmap")   // iOS deletes it (offloading, say)
        system.setRefused(.tasmap, false)
        await store.resync()
        #expect(await eventually { store.state(.tasmap) == .notInstalled })
        #expect(store.unusable.isEmpty)
    }

    // MARK: On-demand

    /// An incomplete on-demand map: the row offers Remove (her tap), the
    /// note says remove and get again; after Remove it's a plain Get.
    @Test func incompleteOnDemandMapCanBeRemovedByHand() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.tasmap.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.tasmap], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        let storage = StorageModel(packs: store, trees: nil)
        guard case .unusable(.incomplete) = storage.status(.tasmap) else { Issue.record("row: \(storage.status(.tasmap))"); return }
        #expect(storage.unusableNote == "An extra map on this \(DeviceNoun.current) is incomplete: remove it and get it again.")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(system.calls.isEmpty)
        await store.remove(.tasmap)
        #expect(system.calls == ["-tasmap"])
        #expect(await eventually { storage.status(.tasmap) == .get })
        #expect(store.unusable.isEmpty)
    }

    // MARK: Plant ID

    @Test func truncatedPlantIDModelIsIncompleteNotRemoved() async throws {
        let dir = try tempDir()
        let (folder, _) = try Self.plantID(in: dir)
        Self.truncate(folder.appending(path: "v3-head.bin"), by: 3000)
        let system = FakePackSystem(installed: [.plantid], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.errorLog[.plantid]?.first?.text.contains("plantid/v3-head.bin TRUNCATED (have 5,192, need 8,192)") == true)
        #expect(store.state(.plantid) == .failed(PackStore.damaged))
        guard case .incomplete? = store.unusable[.plantid] else { Issue.record("unusable: \(String(describing: store.unusable[.plantid]))"); return }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(system.calls.isEmpty)
    }

    /// The engine checks before Core ML sees the files: the incomplete
    /// message, not "array weight out of bounds", and the store is told.
    @Test func damagedModelFailsTheLoadWithTheIncompleteMessage() async throws {
        let dir = try tempDir()
        let (folder, _) = try Self.plantID(in: dir)
        Self.truncate(folder.appending(path: "\(PlantIDFiles.encoder)/weights/weight.bin"), by: 100)
        let told = Mutex<[String]>([])
        let token = NotificationCenter.default.addObserver(forName: PackVerification.damagedNotification, object: nil, queue: nil) { note in
            let id = note.object as? String ?? "?"
            told.withLock { $0.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let engine = PlantIDEngine(source: .files(folder))
        var message: String?
        do { _ = try await engine.prepare() } catch { message = error.localizedDescription }
        #expect(message == PlantIDFailure.incomplete)
        #expect(told.withLock { $0 } == ["plantid"])
    }

    // MARK: Reference photos

    /// 40 photos in `<dir>/refphotos/` with their index; "Species 9" sorts
    /// last, so p9.avif (59 bytes recorded) is always sampled.
    private func refPhotosFolder() throws -> (dir: URL, last: URL) {
        let dir = try tempDir()
        let folder = dir.appending(path: RefPhotoFiles.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var photos: [String: Any] = [:]
        for i in 0 ..< 40 {
            try Data(repeating: 9, count: 50 + i).write(to: folder.appending(path: "p\(i).avif"))
            photos["Species \(i)"] = ["file": "p\(i).avif", "bytes": 50 + i, "attribution": "a"]
        }
        try JSONSerialization.data(withJSONObject: ["version": 2, "photos": photos]).write(to: folder.appending(path: RefPhotoFiles.index))
        return (dir, folder.appending(path: "p9.avif"))
    }

    @Test func refPhotosWithTruncatedFilesAreIncomplete() async throws {
        let (dir, last) = try refPhotosFolder()
        try Data(repeating: 9, count: 20).write(to: last)
        let system = FakePackSystem(installed: [.refphotos], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.errorLog[.refphotos]?.first?.text.contains("refphotos/p9.avif TRUNCATED") == true)
        #expect(store.state(.refphotos) == .failed(PackStore.damaged))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(system.calls.isEmpty)
    }

    /// A photo not beside index.json is no evidence: iOS 27 stages a pack's
    /// files one requested path at a time (device, 2026-11-08: a "missing"
    /// photo removed a complete pack). Installed, never removed.
    @Test func refPhotoNotBesideTheIndexIsNoDamage() async throws {
        let (dir, last) = try refPhotosFolder()
        try FileManager.default.removeItem(at: last)
        let system = FakePackSystem(installed: [.refphotos], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.state(.refphotos).isInstalled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.state(.refphotos).isInstalled)
        #expect(system.calls.isEmpty)
        #expect(store.errorLog[.refphotos] == nil)
    }
}
