import Foundation
import IzzyKit
import os

/// Where the licensed extras live on the device: Application Support/
/// Extras/<kind>/, excluded from iCloud backup. F2F chapters, Understorey
/// Network photos and tree data sheets are all rights reserved upstream —
/// the device fetches them for private use; they are never bundled,
/// committed or hosted by us (docs/LICENSING.md §2).
///
/// Safe from any thread. The read-modify-write operations — gone marks,
/// adopting a download, Delete — have ONE owner: a process-wide lock, so
/// the batch engine (main actor), the document store and the photo store
/// (their own actors) and the transport's delegate queue never interleave
/// them. (A lock, not an actor: every caller stays synchronous, and none
/// holds it across anything slower than a same-volume rename.)
///
/// **Generations.** Every batch and every tap fetch takes a generation
/// number (`generation(_:)` / `nextGeneration(_:)`); Delete raises the
/// kind's floor past every number handed out so far. `adopt` refuses a
/// download from below the floor, so a completion that lands after Delete
/// — a straggling task, a tap fetch in flight — is deleted, never kept:
/// licensed bytes must not survive Delete.
nonisolated struct ExtrasStorage: Sendable {
    let root: URL

    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Extras")
    /// The one owner of marks, adoption, generations and Delete.
    private static let lock = NSLock()

    /// The app's store (Application Support/Extras).
    static let shared: ExtrasStorage = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(filePath: NSTemporaryDirectory())
        return ExtrasStorage(root: base.appending(path: "Extras", directoryHint: .isDirectory))
    }()

    init(root: URL) {
        self.root = root
        prepare(root)
    }

    /// Why a download wasn't kept.
    enum AdoptError: Error {
        /// Delete ran after this download started.
        case deleted
    }

    /// Creates `dir` and marks it excluded from backup.
    private func prepare(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
    }

    func directory(_ kind: ExtraKind) -> URL {
        let dir = root.appending(path: kind.folder, directoryHint: .isDirectory)
        prepare(dir)
        return dir
    }

    /// Thumbnails fetched on view (not part of the photo batch's count).
    var thumbnails: URL {
        let dir = root.appending(path: "plant-thumbs", directoryHint: .isDirectory)
        prepare(dir)
        return dir
    }

    /// Where completed batch downloads wait to be checked and moved.
    var incoming: URL {
        let dir = root.appending(path: ".incoming", directoryHint: .isDirectory)
        prepare(dir)
        return dir
    }

    /// A fresh staging path for one of `kind`'s downloads ("<kind>-<uuid>",
    /// so Delete can find a kind's leftovers).
    func stagingURL(_ kind: ExtraKind) -> URL {
        incoming.appending(path: "\(kind.rawValue)-\(UUID().uuidString)", directoryHint: .notDirectory)
    }

    func file(_ kind: ExtraKind, _ name: String) -> URL {
        directory(kind).appending(path: name, directoryHint: .notDirectory)
    }

    /// The stored file, if present and not empty.
    func existing(_ kind: ExtraKind, _ name: String) -> URL? {
        let url = file(kind, name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 ? url : nil
    }

    /// Names of every stored file of a kind.
    func storedNames(_ kind: ExtraKind) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(kind).path(percentEncoded: false))) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    // MARK: Generations

    private var generationsURL: URL { root.appending(path: "generations.json") }

    private struct Generations: Codable {
        /// Last number handed out, per kind.
        var issued: [String: Int] = [:]
        /// Downloads from below this were started before a Delete.
        var floor: [String: Int] = [:]
    }

    private func loadGenerations() -> Generations {
        guard let data = try? Data(contentsOf: generationsURL) else { return Generations() }
        return (try? JSONDecoder().decode(Generations.self, from: data)) ?? Generations()
    }

    private func saveGenerations(_ g: Generations) {
        do { try JSONEncoder().encode(g).write(to: generationsURL, options: .atomic) } catch {
            Self.logger.error("generations not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// The current generation: what a tap fetch stamps itself with.
    func generation(_ kind: ExtraKind) -> Int {
        Self.lock.withLock { loadGenerations().issued[kind.rawValue] ?? 0 }
    }

    /// A new generation for a batch (persisted: numbers never repeat
    /// across launches, so a previous launch's tasks stay distinguishable).
    func nextGeneration(_ kind: ExtraKind) -> Int {
        Self.lock.withLock {
            var g = loadGenerations()
            let next = (g.issued[kind.rawValue] ?? 0) + 1
            g.issued[kind.rawValue] = next
            saveGenerations(g)
            return next
        }
    }

    /// Downloads started before the last Delete carry a generation below this.
    func floor(_ kind: ExtraKind) -> Int {
        Self.lock.withLock { loadGenerations().floor[kind.rawValue] ?? 0 }
    }

    /// Whether a download of `generation` may still be kept.
    func isLive(_ kind: ExtraKind, generation: Int) -> Bool { generation >= floor(kind) }

    // MARK: Adopting downloads

    /// Moves a checked download into place (replacing any older copy) —
    /// unless Delete ran since `generation` was handed out. The staged file
    /// is gone afterwards either way: moved, or deleted on any failure.
    @discardableResult
    func adopt(_ temp: URL, as kind: ExtraKind, _ name: String, generation: Int) throws -> URL {
        do {
            return try Self.lock.withLock {
                guard generation >= (loadGenerations().floor[kind.rawValue] ?? 0) else { throw AdoptError.deleted }
                return try place(temp, as: kind, name)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// `adopt` at the current generation (callers that don't track one).
    @discardableResult
    func adopt(_ temp: URL, as kind: ExtraKind, _ name: String) throws -> URL {
        try adopt(temp, as: kind, name, generation: generation(kind))
    }

    /// Under the lock: exists-then-move can't race another adopter.
    private func place(_ temp: URL, as kind: ExtraKind, _ name: String) throws -> URL {
        let dest = file(kind, name)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(dest, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
        return dest
    }

    /// Writes bytes atomically.
    func write(_ data: Data, as kind: ExtraKind, _ name: String) throws -> URL {
        let dest = file(kind, name)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: Gone marks (a Codable file per kind)

    private func goneURL(_ kind: ExtraKind) -> URL { root.appending(path: "\(kind.rawValue)-gone.json") }

    func goneMarks(_ kind: ExtraKind) -> GoneMarks {
        Self.lock.withLock { readGone(kind) }
    }

    private func readGone(_ kind: ExtraKind) -> GoneMarks {
        guard let data = try? Data(contentsOf: goneURL(kind)) else { return GoneMarks() }
        return (try? JSONDecoder().decode(GoneMarks.self, from: data)) ?? GoneMarks()
    }

    private func writeGone(_ marks: GoneMarks, _ kind: ExtraKind) {
        do {
            if marks.count == 0 {
                try? FileManager.default.removeItem(at: goneURL(kind))
            } else {
                try JSONEncoder().encode(marks).write(to: goneURL(kind), options: .atomic)
            }
        } catch {
            Self.logger.error("gone marks not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Read-modify-write of a kind's marks, atomic against every other caller.
    func updateGone(_ kind: ExtraKind, _ change: (inout GoneMarks) -> Void) {
        Self.lock.withLock {
            var marks = readGone(kind)
            change(&marks)
            writeGone(marks, kind)
        }
    }

    /// A batch's changes (`before` → `after`) onto the file's current marks.
    func mergeGone(_ kind: ExtraKind, from before: GoneMarks, to after: GoneMarks) {
        guard before != after else { return }
        updateGone(kind) { $0.apply(from: before, to: after) }
    }

    // MARK: Delete and the launch sweep

    /// Delete, step 1: from now on nothing started earlier is kept.
    func retire(_ kind: ExtraKind) {
        Self.lock.withLock {
            var g = loadGenerations()
            let next = (g.issued[kind.rawValue] ?? 0) + 1
            g.issued[kind.rawValue] = next
            g.floor[kind.rawValue] = next
            saveGenerations(g)
        }
    }

    /// Delete, last step: every file of a kind, its staged downloads and its
    /// gone marks.
    func deleteAll(_ kind: ExtraKind) {
        Self.lock.withLock {
            let fm = FileManager.default
            try? fm.removeItem(at: root.appending(path: kind.folder, directoryHint: .isDirectory))
            if kind == .photos { try? fm.removeItem(at: root.appending(path: "plant-thumbs", directoryHint: .isDirectory)) }
            let staged = root.appending(path: ".incoming", directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: staged.path(percentEncoded: false))) ?? []
            where name.hasPrefix(kind.rawValue + "-") {
                try? fm.removeItem(at: staged.appending(path: name))
            }
            writeGone(GoneMarks(), kind)
        }
    }

    /// At launch, before any session exists: a staged file belongs to a
    /// delegate callback of THIS process (staged, then adopted or deleted in
    /// the same completion), so whatever is left in incoming/ is an
    /// interrupted process's leftover — removed.
    func sweepIncoming() {
        Self.lock.withLock {
            let fm = FileManager.default
            let staged = root.appending(path: ".incoming", directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: staged.path(percentEncoded: false))) ?? [] {
                try? fm.removeItem(at: staged.appending(path: name))
            }
        }
    }

    /// Bytes stored for a kind.
    func bytesStored(_ kind: ExtraKind) -> Int {
        let dir = directory(kind)
        let names = storedNames(kind)
        return names.reduce(0) { sum, name in
            sum + ((try? dir.appending(path: name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Free space for user-requested downloads.
    var freeBytes: Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// Reads the first bytes of a file (for the magic checks).
nonisolated func fileHead(_ url: URL, count: Int = 16) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: count)) ?? Data()
}
