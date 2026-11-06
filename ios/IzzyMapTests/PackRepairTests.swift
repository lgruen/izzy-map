import Foundation
import IzzyKit
import Synchronization
import Testing
@testable import IzzyMap

/// Packs the system calls "downloaded" whose files are cut short (the iPad
/// ran out of space mid-download, 2026-11-06): never shown, removed and
/// asked for again — once per failure — over `FakePackSystem` with real,
/// truncated files in its directory.
@MainActor
@Suite(.serialized)
struct PackRepairTests {
    /// The queue's test timing, with a short confirmation delay.
    static var tuning: PackStore.Tuning {
        var t = PackQueueTests.tuning
        t.repairConfirmAfter = .milliseconds(150)
        return t
    }

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

    @Test func truncatedArchiveIsHiddenRemovedAndFetchedOnce() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        let full = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.topo], seconds: 0.4, directory: dir, returnDelay: 0.05)
        // the download writes the whole file this time
        system.onInstall { id in if id == "topo" { try? full.write(to: url) } }
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        // never handed to the map while damaged; the row says what happens
        #expect(store.location.url(for: .topo) == nil)
        #expect(store.errorLog[.topo]?.first?.stage == "integrity")
        #expect(store.errorLog[.topo]?.first?.text.contains("topo_tas.pmtiles TRUNCATED (have ") == true)
        #expect(await eventually { if case .repairing = StorageModel(packs: store, trees: nil).status(.topo) { true } else { false } })
        #expect(StorageModel(packs: store, trees: nil).status(.topo).text(bytes: 1000, device: "iPad").hasPrefix("Repairing — downloading again"))
        #expect(await eventually { store.state(.topo).isInstalled })
        #expect(store.location.url(for: .topo) == url)
        #expect(store.repairing.isEmpty)
        #expect(store.integrity[.topo]?.isDamaged == false)
        // exactly one removal and one request; looking again adds none
        await store.resync()
        await store.resync()
        #expect(system.calls == ["-topo", "topo"])
    }

    @Test func stillDamagedAfterTheRepairFailsWithoutLooping() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        // the download leaves the same short file (space still full)
        let system = FakePackSystem(installed: [.topo], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(await eventually { store.state(.topo) == .failed(PackStore.damaged) })
        await store.resync()
        try? await Task.sleep(for: .milliseconds(200))
        await store.resync()
        #expect(system.calls == ["-topo", "topo"])
        #expect(store.location.url(for: .topo) == nil)
        #expect(store.repairing.isEmpty)
        // a Retry repairs again — once
        store.fetch(.topo)
        #expect(await eventually { system.calls.count == 4 })
        #expect(await eventually { store.state(.topo) == .failed(PackStore.damaged) })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(system.calls == ["-topo", "topo", "-topo", "topo"])
    }

    @Test func aCompletePackIsCheckedOncePerVersion() async throws {
        let dir = try tempDir()
        _ = try Self.pmtiles(dir.appending(path: Archive.topo.fileName))
        let defaults = defaults()
        let system = FakePackSystem(installed: [.topo], directory: dir)
        let store = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning)
        #expect(store.state(.topo).isInstalled && store.integrity[.topo]?.isDamaged == false)
        store.shutdown()
        // the next launch: the same files passed — not read again
        let passed = defaults.dictionary(forKey: PackStore.integrityKey) as? [String: String]
        #expect(passed?["topo"] != nil)
        let again = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning)
        defer { again.shutdown() }
        #expect(again.state(.topo).isInstalled && again.integrity[.topo] == nil)
        #expect(system.calls.isEmpty)
    }

    // MARK: Plant ID

    @Test func truncatedPlantIDModelIsRepairedOnce() async throws {
        let dir = try tempDir()
        let (folder, head) = try Self.plantID(in: dir)
        let headURL = folder.appending(path: "v3-head.bin")
        Self.truncate(headURL, by: 3000)
        let system = FakePackSystem(installed: [.plantid], seconds: 0.05, directory: dir, returnDelay: 0.05)
        system.onInstall { id in if id == "plantid" { try? head.write(to: headURL) } }
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.errorLog[.plantid]?.first?.text.contains("plantid/v3-head.bin TRUNCATED (have 5,192, need 8,192)") == true)
        #expect(await eventually { store.state(.plantid).isInstalled })
        #expect(system.calls == ["-plantid", "plantid"])
        #expect(store.integrity[.plantid]?.isDamaged == false)
    }

    /// The engine checks before Core ML sees the files: the repair message,
    /// not "array weight out of bounds", and the store is told.
    @Test func damagedModelFailsTheLoadWithTheRepairMessage() async throws {
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
        #expect(message == PlantIDFailure.repairing)
        #expect(told.withLock { $0 } == ["plantid"])
    }

    // MARK: Reference photos

    @Test func refPhotosWithMissingFilesAreRepairedOnce() async throws {
        let dir = try tempDir()
        let folder = dir.appending(path: RefPhotoFiles.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var photos: [String: Any] = [:]
        for i in 0 ..< 40 {
            try Data(repeating: 9, count: 50 + i).write(to: folder.appending(path: "p\(i).avif"))
            photos["Species \(i)"] = ["file": "p\(i).avif", "bytes": 50 + i, "attribution": "a"]
        }
        try JSONSerialization.data(withJSONObject: ["version": 2, "photos": photos]).write(to: folder.appending(path: RefPhotoFiles.index))
        let last = folder.appending(path: "p9.avif")   // "Species 9" sorts last: always sampled
        try FileManager.default.removeItem(at: last)
        let system = FakePackSystem(installed: [.refphotos], seconds: 0.05, directory: dir, returnDelay: 0.05)
        system.onInstall { id in if id == "refphotos" { try? Data(repeating: 9, count: 59).write(to: last) } }
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        #expect(store.errorLog[.refphotos]?.first?.text.contains("refphotos/p9.avif MISSING") == true)
        #expect(await eventually { store.state(.refphotos).isInstalled })
        #expect(system.calls == ["-refphotos", "refphotos"])
    }

    // MARK: Guards: confirmation, space, the cap across launches

    /// One damaged look removes nothing: an in-place update may be
    /// mid-swap. Complete by the second look = never removed.
    @Test func aSecondLookBeforeAnythingIsRemoved() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        let full = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        var tuning = Self.tuning
        tuning.repairConfirmAfter = .milliseconds(500)
        let system = FakePackSystem(installed: [.topo], directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: tuning)
        defer { store.shutdown() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(system.calls.isEmpty)
        #expect(store.location.url(for: .topo) == nil)
        // the swap finishes before the second look
        try full.write(to: url)
        #expect(await eventually { store.state(.topo).isInstalled })
        #expect(store.location.url(for: .topo) == url)
        #expect(system.calls.isEmpty)
    }

    /// While the system downloads (updates) the pack, it isn't judged.
    @Test func noRemovalWhileTheSystemDownloadsThePack() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.topo], downloading: [.topo: 0.5], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning)
        defer { store.shutdown() }
        try? await Task.sleep(for: .milliseconds(600))
        #expect(system.calls.isEmpty)
        system.drop(.topo)
        #expect(await eventually { system.calls == ["-topo", "topo"] })
    }

    @Test func tooLittleSpaceRemovesNothingAndSaysHowMuchToFree() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let system = FakePackSystem(installed: [.topo], seconds: 0.05, directory: dir, returnDelay: 0.05)
        let store = await PackStore.testing(system: system, defaults: defaults(), tuning: Self.tuning, freeSpace: { 500_000_000 })
        defer { store.shutdown() }
        let blocked = { if case .failed(let m) = store.state(.topo) { m.hasPrefix("Not enough space to repair — free ") } else { false } }
        #expect(await eventually { blocked() })
        let status = StorageModel(packs: store, trees: nil).status(.topo)
        #expect(status.offersGet)
        if case let .noSpace(message) = status { #expect(message.hasSuffix("GB")) } else { Issue.record("row: \(status)") }
        await store.resync()
        try? await Task.sleep(for: .milliseconds(400))
        await store.resync()
        #expect(system.calls.isEmpty)
        #expect(blocked())
    }

    /// At most `maxRepairs` automatic repairs per pack version — across
    /// launches; a Retry starts over.
    @Test func theRepairCapHoldsAcrossLaunches() async throws {
        let dir = try tempDir()
        let url = dir.appending(path: Archive.topo.fileName)
        _ = try Self.pmtiles(url)
        Self.truncate(url, by: 500)
        let defaults = defaults()
        for launch in 1 ... 3 {
            let system = FakePackSystem(installed: [.topo], seconds: 0.05, directory: dir, returnDelay: 0.05)
            let store = await PackStore.testing(system: system, defaults: defaults, tuning: Self.tuning)
            if launch <= PackStore.maxRepairs {
                #expect(await eventually { system.calls == ["-topo", "topo"] && store.state(.topo) == .failed(PackStore.damaged) }, "launch \(launch)")
            } else {
                try? await Task.sleep(for: .milliseconds(600))
                #expect(system.calls.isEmpty, "launch \(launch)")
                #expect(store.state(.topo) == .failed(PackStore.damaged))
                store.fetch(.topo)
                #expect(await eventually { system.calls == ["-topo", "topo"] })
            }
            try? await Task.sleep(for: .milliseconds(100))
            store.shutdown()
        }
    }
}
