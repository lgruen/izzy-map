import Foundation
import Testing
@testable import IzzyKit

/// `PackIntegrity` over synthetic files cut short the way a storage-full
/// Background Assets download left them (iPad, 2026-11-06).
struct PackIntegrityTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "integrity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func truncate(_ url: URL, to size: Int64) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(size))
        try h.close()
    }

    private func pmtiles(_ url: URL) throws {
        let w = try PMTilesWriter(destination: url, tileType: .png)
        for x in 0 ..< 64 { try w.add(z: 8, x: x, y: 100, data: Data(repeating: UInt8(x), count: 900 + x)) }
        _ = try w.finish(name: "t", attribution: "t", metadata: [:])
    }

    /// A Core ML blob file: 64-byte header (count, version 2), then per blob
    /// a 64-byte record (0xDEADBEEF, dtype, size, offset) and its bytes, 64-aligned.
    static func blobFile(_ sizes: [Int]) -> Data {
        var d = Data(count: 64)
        d.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(sizes.count).littleEndian, as: UInt32.self) }
        d.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) })
        for size in sizes {
            var meta = Data(count: 64)
            let offset = UInt64(d.count + 64)
            meta.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: UInt32(0xDEAD_BEEF).littleEndian) { Data($0) })
            meta.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: UInt32(4).littleEndian) { Data($0) })
            meta.replaceSubrange(8 ..< 16, with: withUnsafeBytes(of: UInt64(size).littleEndian) { Data($0) })
            meta.replaceSubrange(16 ..< 24, with: withUnsafeBytes(of: offset.littleEndian) { Data($0) })
            d.append(meta)
            d.append(Data(repeating: 7, count: size))
            let pad = (64 - d.count % 64) % 64
            d.append(Data(count: pad))
        }
        return d
    }

    @Test func pmtilesCutShortIsTruncated() throws {
        let dir = try tempDir()
        let url = dir.appending(path: "a.pmtiles")
        try pmtiles(url)
        let full = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let ok = PackIntegrity.pmtiles(url, path: "a.pmtiles")
        #expect(ok.verdict == .ok && ok.need == Int64(full) && !ok.isDamaged)
        try truncate(url, to: Int64(full) - 100)
        let cut = PackIntegrity.pmtiles(url, path: "a.pmtiles")
        #expect(cut.verdict == .truncated && cut.have == Int64(full) - 100 && cut.need == Int64(full))
        #expect(cut.line.hasPrefix("TRUNCATED (have "))
        try truncate(url, to: 50)
        #expect(PackIntegrity.pmtiles(url, path: "a.pmtiles").verdict == .truncated)
        try Data("not a pmtiles archive at all, but long enough to have a header-sized prefix ........................................................".utf8).write(to: url)
        #expect(PackIntegrity.pmtiles(url, path: "a.pmtiles").isDamaged)
        // gone: missing (damaged); a verdict needs evidence, not a failed read
        try FileManager.default.removeItem(at: url)
        #expect(PackIntegrity.pmtiles(url, path: "a.pmtiles").verdict == .missing)
    }

    @Test func blobFileWalksEveryRecord() throws {
        let dir = try tempDir()
        let url = dir.appending(path: "weight.bin")
        let data = Self.blobFile([100, 5000, 64, 3])
        try data.write(to: url)
        let ok = PackIntegrity.blobFile(url, path: "w")
        #expect(ok.verdict == .ok)
        #expect(ok.need.map { $0 <= Int64(data.count) && $0 > Int64(data.count) - 64 } == true)
        // cut inside the last blob, at a record, inside a middle blob
        let need = Int(ok.need ?? 0)
        for cut in [need - 1, need - 70, 700, 65] {
            try data.prefix(cut).write(to: url)
            let c = PackIntegrity.blobFile(url, path: "w")
            #expect(c.verdict == .truncated, "cut at \(cut)")
        }
    }

    @Test func plantIDChecksRecordedSizesAndTheEncoder() throws {
        let dir = try tempDir()
        let head = Data(repeating: 1, count: 4096), prior = Data(repeating: 2, count: 1000)
        try head.write(to: dir.appending(path: "v3-head.bin"))
        try prior.write(to: dir.appending(path: "v3-prior.bin"))
        let manifest: [String: Any] = ["version": 1, "files": ["v3-head.bin": ["bytes": head.count, "sha256": "x"],
                                                               "v3-prior.bin": ["bytes": prior.count, "sha256": "y"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appending(path: "pipeline.json"))
        let enc = dir.appending(path: "PlantEncoder-w8.mlmodelc/weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: enc, withIntermediateDirectories: true)
        try Self.blobFile([300, 300]).write(to: enc.appending(path: "weight.bin"))
        try Data("program(1.0)\n{\n  func main() {\n  }\n}\n".utf8).write(to: enc.deletingLastPathComponent().appending(path: "model.mil"))
        let required = ["v3-head.bin", "v3-prior.bin"]
        let ok = PackIntegrity.plantID(dir, required: required)
        #expect(!ok.isDamaged && ok.isConclusive, "\(ok.files.map(\.line))")

        try truncate(dir.appending(path: "v3-head.bin"), to: 1000)
        let cut = PackIntegrity.plantID(dir, required: required)
        #expect(cut.isDamaged)
        #expect(cut.summary == "plantid/v3-head.bin TRUNCATED (have 1,000, need 4,096)")

        try head.write(to: dir.appending(path: "v3-head.bin"))
        try truncate(enc.appending(path: "weight.bin"), to: 500)
        #expect(PackIntegrity.plantID(dir, required: required).damaged.map(\.path) == ["plantid/PlantEncoder-w8.mlmodelc/weights/weight.bin"])

        try Self.blobFile([300, 300]).write(to: enc.appending(path: "weight.bin"))
        let json = try Data(contentsOf: dir.appending(path: "pipeline.json"))
        try json.prefix(json.count / 2).write(to: dir.appending(path: "pipeline.json"))
        #expect(PackIntegrity.plantID(dir, required: required).damaged.map(\.path) == ["plantid/pipeline.json"])
    }

    /// pipeline.json may record names the app doesn't read (an older or
    /// newer model's table): absent, they don't make the pack damaged.
    @Test func plantIDIgnoresRecordedNamesTheAppDoesNotRead() throws {
        let dir = try tempDir()
        let head = Data(repeating: 1, count: 512)
        try head.write(to: dir.appending(path: "v3-head.bin"))
        let manifest: [String: Any] = ["files": ["v3-head.bin": ["bytes": head.count], "au-head.bin": ["bytes": 99999],
                                                 "bank-fp16.bin": ["bytes": 5]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appending(path: "pipeline.json"))
        let enc = dir.appending(path: "PlantEncoder-w8.mlmodelc/weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: enc, withIntermediateDirectories: true)
        try Self.blobFile([64]).write(to: enc.appending(path: "weight.bin"))
        try Data("{\n}\n".utf8).write(to: enc.deletingLastPathComponent().appending(path: "model.mil"))
        let report = PackIntegrity.plantID(dir, required: ["v3-head.bin"])
        #expect(!report.isDamaged, "\(report.files.map { "\($0.path) \($0.line)" })")
        #expect(!report.files.contains { $0.path.contains("au-head") || $0.path.contains("bank-fp16") })
        // a required name absent: damaged
        #expect(PackIntegrity.plantID(dir, required: ["v3-head.bin", "v3-prior.bin"]).damaged.map(\.path) == ["plantid/v3-prior.bin"])
    }

    @Test func refPhotosSampleSizes() throws {
        let dir = try tempDir()
        var photos: [String: Any] = [:]
        for i in 0 ..< 300 {
            let file = "p\(i).avif"
            try Data(repeating: 3, count: 100 + i).write(to: dir.appending(path: file))
            photos["Species \(i)"] = ["file": file, "bytes": 100 + i, "attribution": "a"]
        }
        try JSONSerialization.data(withJSONObject: ["version": 2, "photos": photos]).write(to: dir.appending(path: "index.json"))
        #expect(!PackIntegrity.refPhotos(dir, sample: 32).isDamaged)
        // the last photo (always sampled) missing
        try FileManager.default.removeItem(at: dir.appending(path: "p99.avif"))
        #expect(PackIntegrity.refPhotos(dir, sample: 32).damaged.map(\.verdict) == [.missing])
        // a cut-off index
        let json = try Data(contentsOf: dir.appending(path: "index.json"))
        try json.prefix(json.count - 10).write(to: dir.appending(path: "index.json"))
        #expect(PackIntegrity.refPhotos(dir).damaged.first?.path == "refphotos/index.json")
    }

    /// The real staged plant-ID pack (developer Mac only): all sizes match.
    @Test func realStagedPlantIDPackIsComplete() throws {
        let dir = PMTilesFixtures.dataDir.appending(path: "packs/stage-plantid/plantid", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: dir.appending(path: "pipeline.json").path(percentEncoded: false)) else { return }
        let report = PackIntegrity.plantID(dir, required: ["bank-int8.bin", "pipeline.json", "credits.json", "credits-photos.tsv.gz",
                                                           "v3-head.bin", "v3-prior.bin", "v2-labels.json"])
        #expect(!report.isDamaged && report.isConclusive, "\(report.files.map { "\($0.path) \($0.line)" })")
        #expect(report.files.count >= 9)
    }

    /// The real archives and reference photos (developer Mac only): complete.
    @Test func realArchivesAndRefPhotosAreComplete() throws {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: PMTilesFixtures.dataDir.path(percentEncoded: false))) ?? []
        for name in names where name.hasSuffix(".pmtiles") {
            let check = PackIntegrity.pmtiles(PMTilesFixtures.archive(name), path: name)
            #expect(check.verdict == .ok, "\(name): \(check.line)")
        }
        let photos = PMTilesFixtures.dataDir.appending(path: "packs/stage-refphotos/refphotos", directoryHint: .isDirectory)
        if fm.fileExists(atPath: photos.appending(path: "index.json").path(percentEncoded: false)) {
            let report = PackIntegrity.refPhotos(photos)
            #expect(!report.isDamaged && report.files.count > 60, "\(report.summary ?? "")")
        }
    }
}
