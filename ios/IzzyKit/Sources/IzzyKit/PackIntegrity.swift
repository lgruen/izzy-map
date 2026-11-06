import Foundation

/// Cheap, offline checks that a pack's files are COMPLETE — the system's
/// "downloaded" can't be trusted after the device ran out of space during a
/// Background Assets download (field report, iPad Pro, iPadOS 27.2,
/// 2026-11-06: status [downloaded], yet topo_tas.pmtiles held 104 MB of
/// 2.04 GB and plantid/v3-head.bin 84 of 119 MB). Every check reads only
/// what the file says about its own extent (a PMTiles header, Core ML's
/// weight-blob headers) or a size the pack itself records (pipeline.json,
/// refphotos/index.json) — no hashing, nothing re-read in full.
///
/// A check that can't READ a file (data protection while locked, a move in
/// progress) is `inconclusive`, never "damaged": only positive evidence of
/// missing bytes triggers a repair.
public enum PackIntegrity {
    /// One file's verdict.
    public struct FileCheck: Sendable, Equatable {
        public enum Verdict: Error, Sendable, Equatable {
            case ok
            /// Shorter than its own header / the pack's record says.
            case truncated
            /// Listed by the pack, absent.
            case missing
            /// Present but not what it should be (bad magic, cut-off JSON).
            case malformed(String)
            /// Couldn't be read: no verdict.
            case unreadable(String)
        }

        /// The path inside the pack ("topo_tas.pmtiles", "plantid/v3-head.bin").
        public var path: String
        public var have: Int64?
        public var need: Int64?
        /// `need` is a lower bound (the file ends before its own last record).
        public var atLeast = false
        public var verdict: Verdict

        public init(path: String, have: Int64?, need: Int64?, atLeast: Bool = false, verdict: Verdict) {
            self.path = path
            self.have = have
            self.need = need
            self.atLeast = atLeast
            self.verdict = verdict
        }

        public var isDamaged: Bool {
            switch verdict {
            case .truncated, .missing, .malformed: true
            case .ok, .unreadable: false
            }
        }

        /// "size ok (2,044,499,329 bytes)", "TRUNCATED (have 103,546,880, need 2,044,499,329)".
        public var line: String {
            func n(_ v: Int64?) -> String { v.map { $0.formatted(.number.locale(Locale(identifier: "en_AU"))) } ?? "?" }
            return switch verdict {
            case .ok: "size ok (\(n(have)) bytes)"
            case .truncated: "TRUNCATED (have \(n(have)), need \(atLeast ? "≥ " : "")\(n(need)))"
            case .missing: "MISSING"
            case let .malformed(why): "DAMAGED (\(why); have \(n(have)) bytes)"
            case let .unreadable(why): "not checked (\(why))"
            }
        }
    }

    /// A pack's verdict: its files, worst first in `damaged`.
    public struct Report: Sendable, Equatable {
        public var files: [FileCheck]
        public init(files: [FileCheck]) { self.files = files }
        public var isDamaged: Bool { files.contains(where: \.isDamaged) }
        public var damaged: [FileCheck] { files.filter(\.isDamaged) }
        public var isConclusive: Bool { !files.contains { if case .unreadable = $0.verdict { true } else { false } } }
        /// "plantid/v3-head.bin TRUNCATED (have …, need …)" for the first damaged file.
        public var summary: String? { damaged.first.map { "\($0.path) \($0.line)" } }
    }

    // MARK: PMTiles

    /// A PMTiles v3 archive must reach the end of every section its header
    /// names (root and leaf directories, metadata, tile data).
    public static func pmtiles(_ url: URL, path: String) -> FileCheck {
        let have: Int64
        switch size(url) {
        case let .success(s): have = s
        case let .failure(f): return FileCheck(path: path, have: nil, need: nil, verdict: f)
        }
        guard have >= Int64(PMTiles.headerLength) else {
            return FileCheck(path: path, have: have, need: Int64(PMTiles.headerLength), atLeast: true, verdict: .truncated)
        }
        let head: Data
        switch read(url, offset: 0, count: PMTiles.headerLength) {
        case let .success(d): head = d
        case let .failure(f): return FileCheck(path: path, have: have, need: nil, verdict: f)
        }
        let header: PMTiles.Header
        do throws(PMTilesError) { header = try PMTiles.Header(parsing: head) } catch {
            return FileCheck(path: path, have: have, need: nil, verdict: .malformed(error.description))
        }
        let ends = [header.rootOffset &+ header.rootLength, header.metadataOffset &+ header.metadataLength,
                    header.leafDirectoryOffset &+ header.leafDirectoryLength, header.tileDataOffset &+ header.tileDataLength]
        let need = Int64(clamping: ends.max() ?? 0)
        return FileCheck(path: path, have: have, need: need, verdict: have >= need ? .ok : .truncated)
    }

    // MARK: Plant ID

    /// The plant-ID folder: each file the app `required`s (the pack's own
    /// list) present, at the size pipeline.json's `files` records for it
    /// (`bytes` — build_ship.py writes it, build_packs.py asserts `files` =
    /// the packed set), and the compiled encoder's weights complete. Names
    /// pipeline.json records beyond `required` are ignored: only what the
    /// app reads can make it a damaged pack. `prefix` names them in the report.
    public static func plantID(_ dir: URL, prefix: String = "plantid/", encoder: String = "PlantEncoder-w8.mlmodelc",
                               required: [String]) -> Report {
        var out: [FileCheck] = []
        let manifestURL = dir.appending(path: "pipeline.json")
        var recorded: [String: Int64] = [:]
        switch size(manifestURL) {
        case let .failure(f):
            out.append(FileCheck(path: prefix + "pipeline.json", have: nil, need: nil, verdict: f))
        case let .success(have):
            switch read(manifestURL, offset: 0, count: Int(clamping: have)) {
            case let .failure(f):
                out.append(FileCheck(path: prefix + "pipeline.json", have: have, need: nil, verdict: f))
            case let .success(data):
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    out.append(FileCheck(path: prefix + "pipeline.json", have: have, need: have, verdict: .ok))
                    for (name, entry) in (json["files"] as? [String: Any]) ?? [:] {
                        if let bytes = (entry as? [String: Any])?["bytes"] as? NSNumber { recorded[name] = bytes.int64Value }
                    }
                } else {
                    // a cut-off JSON file: its end is missing
                    out.append(FileCheck(path: prefix + "pipeline.json", have: have, need: nil, verdict: .malformed("not valid JSON")))
                }
            }
        }
        for name in Set(required).sorted() where name != "pipeline.json" {
            let url = dir.appending(path: name)
            switch size(url) {
            case let .success(have):
                guard let need = recorded[name] else {
                    out.append(FileCheck(path: prefix + name, have: have, need: nil, verdict: .ok))
                    continue
                }
                let verdict: FileCheck.Verdict = have == need ? .ok : have < need ? .truncated : .malformed("larger than recorded")
                out.append(FileCheck(path: prefix + name, have: have, need: need, verdict: verdict))
            case let .failure(f):
                out.append(FileCheck(path: prefix + name, have: nil, need: recorded[name], verdict: f))
            }
        }
        out.append(contentsOf: coreMLModel(dir.appending(path: encoder, directoryHint: .isDirectory), path: prefix + encoder + "/"))
        return Report(files: out)
    }

    /// A compiled Core ML (ML Program) model: `weights/weight.bin` walked
    /// blob by blob (its 64-byte header holds the blob count; each blob has
    /// a 64-byte metadata record — sentinel 0xDEADBEEF, size, data offset —
    /// and the next record follows at the 64-aligned end), and `model.mil`
    /// ending in its closing brace. No full read: ~one 64-byte read per blob.
    public static func coreMLModel(_ model: URL, path: String) -> [FileCheck] {
        var out: [FileCheck] = []
        let mil = model.appending(path: "model.mil")
        switch size(mil) {
        case let .failure(f): out.append(FileCheck(path: path + "model.mil", have: nil, need: nil, verdict: f))
        case let .success(have):
            let tail = read(mil, offset: max(0, have - 64), count: Int(min(have, 64)))
            switch tail {
            case let .failure(f): out.append(FileCheck(path: path + "model.mil", have: have, need: nil, verdict: f))
            case let .success(d):
                let text = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(FileCheck(path: path + "model.mil", have: have, need: nil,
                                     verdict: text.hasSuffix("}") ? .ok : .malformed("program text cut off")))
            }
        }
        let weights = model.appending(path: "weights/weight.bin")
        out.append(blobFile(weights, path: path + "weights/weight.bin"))
        return out
    }

    /// Core ML's MIL blob-storage file (see `coreMLModel`).
    public static func blobFile(_ url: URL, path: String) -> FileCheck {
        let have: Int64
        switch size(url) {
        case let .success(s): have = s
        case let .failure(f): return FileCheck(path: path, have: nil, need: nil, verdict: f)
        }
        guard have >= 64 else { return FileCheck(path: path, have: have, need: 64, atLeast: true, verdict: .truncated) }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileCheck(path: path, have: have, need: nil, verdict: .unreadable("can't open"))
        }
        defer { try? handle.close() }
        func record(at offset: Int64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        guard let head = record(at: 0, 8) else { return FileCheck(path: path, have: have, need: nil, verdict: .unreadable("can't read")) }
        let count = head.le32(0)
        guard count > 0, count < 1_000_000 else { return FileCheck(path: path, have: have, need: nil, verdict: .malformed("bad blob count \(count)")) }
        var at: Int64 = 64
        var end: Int64 = 64
        for i in 0 ..< Int(count) {
            guard at + 64 <= have else {
                return FileCheck(path: path, have: have, need: at + 64, atLeast: true, verdict: .truncated)
            }
            guard let meta = record(at: at, 24) else { return FileCheck(path: path, have: have, need: nil, verdict: .unreadable("can't read")) }
            guard meta.le32(0) == 0xDEAD_BEEF else {
                return FileCheck(path: path, have: have, need: nil, verdict: .malformed("blob \(i) has no sentinel"))
            }
            let size = Int64(clamping: meta.le64(8)), offset = Int64(clamping: meta.le64(16))
            guard offset >= at + 64 else { return FileCheck(path: path, have: have, need: nil, verdict: .malformed("blob \(i) overlaps its record")) }
            end = offset &+ size
            guard end <= have else {
                // the last blob's end is the file's: when it's missing, more is
                let atLeast = i < Int(count) - 1
                return FileCheck(path: path, have: have, need: end, atLeast: atLeast, verdict: .truncated)
            }
            at = (end + 63) / 64 * 64
        }
        return FileCheck(path: path, have: have, need: end, verdict: have >= end ? .ok : .truncated)
    }

    // MARK: Reference photos

    /// `index.json` parses, and a sample of the photos it lists (evenly
    /// spread, `sample` of them) is there at the recorded `bytes`.
    public static func refPhotos(_ dir: URL, prefix: String = "refphotos/", sample: Int = 64) -> Report {
        let indexURL = dir.appending(path: "index.json")
        var out: [FileCheck] = []
        let have: Int64
        switch size(indexURL) {
        case let .success(s): have = s
        case let .failure(f): return Report(files: [FileCheck(path: prefix + "index.json", have: nil, need: nil, verdict: f)])
        }
        let data: Data
        switch read(indexURL, offset: 0, count: Int(clamping: have)) {
        case let .success(d): data = d
        case let .failure(f): return Report(files: [FileCheck(path: prefix + "index.json", have: have, need: nil, verdict: f)])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = json["photos"] as? [String: Any]
        else {
            return Report(files: [FileCheck(path: prefix + "index.json", have: have, need: nil, verdict: .malformed("not valid JSON"))])
        }
        out.append(FileCheck(path: prefix + "index.json", have: have, need: have, verdict: .ok))
        let keys = photos.keys.sorted()
        guard !keys.isEmpty else { return Report(files: out) }
        let n = min(sample, keys.count)
        var picked: [String] = []
        for i in 0 ..< n { picked.append(keys[i * keys.count / n]) }
        if let last = keys.last, !picked.contains(last) { picked.append(last) }
        for key in picked {
            guard let entry = photos[key] as? [String: Any], let file = entry["file"] as? String, !file.isEmpty else { continue }
            let need = (entry["bytes"] as? NSNumber)?.int64Value
            switch size(dir.appending(path: file)) {
            case let .success(s):
                let verdict: FileCheck.Verdict = need.map { s == $0 ? .ok : s < $0 ? .truncated : .malformed("larger than recorded") } ?? (s > 0 ? .ok : .truncated)
                out.append(FileCheck(path: prefix + file, have: s, need: need, verdict: verdict))
            case let .failure(f):
                out.append(FileCheck(path: prefix + file, have: nil, need: need, verdict: f))
            }
        }
        return Report(files: out)
    }

    // MARK: Signature

    /// What a cached verdict is keyed on: each file's path, size and
    /// modification time (a new pack version = new files = a new check).
    public static func signature(_ urls: [URL]) -> String {
        urls.map { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path(percentEncoded: false)) \(v?.fileSize ?? -1) \(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        }.joined(separator: "|")
    }

    // MARK: File access

    private static func size(_ url: URL) -> Result<Int64, FileCheck.Verdict> {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else {
            let e = errno
            return .failure(e == ENOENT || e == ENOTDIR ? .missing : .unreadable(String(cString: strerror(e))))
        }
        return .success(Int64(info.st_size))
    }

    private static func read(_ url: URL, offset: Int64, count: Int) -> Result<Data, FileCheck.Verdict> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable("can't open")) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let d = try handle.read(upToCount: count) ?? Data()
            return .success(d)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }
}

private extension Data {
    func le32(_ at: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + at + $1]) << (8 * $1) }
    }

    func le64(_ at: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + at + $1]) << (8 * $1) }
    }
}
