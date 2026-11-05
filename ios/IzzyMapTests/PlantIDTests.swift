import CoreGraphics
import Foundation
import ImageIO
import IzzyKit
import Testing
import UniformTypeIdentifiers
@testable import IzzyMap

/// Photo decoding for plant ID (colour profile ignored, orientation applied,
/// GPS read) into the IzzyKit preprocessing, against the Python fixture;
/// the DEBUG fake engine; and — where the developer's pipeline cache is
/// reachable from the simulator — the real model on the eval's three CC0
/// sample photos against the Python result.
struct PlantIDPhotoTests {
    nonisolated static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    nonisolated static let fixtures = repo.appending(path: "ios/IzzyKit/Tests/Fixtures")

    /// build_ship.synthetic_rgb (no photo).
    static func synthetic(_ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 3
                px[i] = UInt8((x * 7 + y * 3) & 255)
                px[i + 1] = UInt8((x * y + 5 * x) & 255)
                px[i + 2] = UInt8((((x ^ y) * 9) + 40) & 255)
            }
        }
        return px
    }

    /// A lossless TIFF of `rgb` tagged with `space`, an EXIF orientation and
    /// optionally a GPS position.
    static func tiff(_ rgb: [UInt8], _ w: Int, _ h: Int, space: CFString, orientation: Int = 1,
                     gps: (Double, Double)? = nil) throws -> Data {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0 ..< w * h { for c in 0 ..< 3 { rgba[i * 4 + c] = rgb[i * 3 + c] } }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: space)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let (lat, lon) = gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon < 0 ? "W" : "E",
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// A Display P3 photo keeps its stored numbers (Pillow ignores the
    /// profile), and the result resizes exactly like Pillow.
    @Test func displayP3ValuesAreNotConverted() throws {
        let (w, h) = (317, 241)
        let rgb = Self.synthetic(w, h)
        let photo = try PlantIDPhoto.decode(Self.tiff(rgb, w, h, space: CGColorSpace.displayP3))
        #expect(photo.pixels.width == w && photo.pixels.height == h)
        #expect(photo.pixels.pixels == rgb, "the decoded P3 values changed (colour conversion?)")
        #expect(photo.location == nil)
        let want = try Data(contentsOf: Self.fixtures.appending(path: "plantid-preprocess.bin"))
        let got = PlantIDPreprocess.resizeCrop(photo.pixels)
        #expect(got.pixels == [UInt8](want.prefix(224 * 224 * 3)))
        // the framed square: the fixture's second case, crop (40, 10)–(220, 190)
        let crop = CGRect(x: 40.0 / Double(w), y: 10.0 / Double(h), width: 180.0 / Double(w), height: 180.0 / Double(h))
        let square = photo.pixels(in: crop)
        #expect(square.width == 180 && square.height == 180)
        #expect(PlantIDPreprocess.resizeCrop(square).pixels == [UInt8](want.suffix(224 * 224 * 3)))
    }

    /// EXIF orientation 6 (stored on its side): the pixels come out upright, exactly.
    @Test func orientationIsApplied() throws {
        let (w, h) = (40, 30)
        let rgb = Self.synthetic(w, h)
        let photo = try PlantIDPhoto.decode(Self.tiff(rgb, w, h, space: CGColorSpace.sRGB, orientation: 6))
        #expect(photo.pixels.width == h && photo.pixels.height == w)
        // shown at (x, y) = stored (y, H − 1 − x)
        for (x, y) in [(0, 0), (5, 7), (29, 39), (12, 3)] {
            let d = (y * h + x) * 3, s = ((h - 1 - x) * w + y) * 3
            #expect(Array(photo.pixels.pixels[d ..< d + 3]) == Array(rgb[s ..< s + 3]), "(\(x), \(y))")
        }
        #expect(abs(photo.display.size.width / photo.display.size.height - CGFloat(h) / CGFloat(w)) < 0.02)
    }

    @Test func gpsIsRead() throws {
        let photo = try PlantIDPhoto.decode(Self.tiff(Self.synthetic(20, 20), 20, 20, space: CGColorSpace.sRGB,
                                                      gps: (-42.8821, 147.3272)))
        let p = try #require(photo.location)
        #expect(abs(p.latitude + 42.8821) < 1e-6 && abs(p.longitude - 147.3272) < 1e-6)
    }

    @Test func defaultCropIsTheCentreSquare() {
        #expect(PlantIDSession.defaultCrop(aspect: 2) == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        #expect(PlantIDSession.defaultCrop(aspect: 0.5) == CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
    }

    @Test func packListsEveryPlantIDFile() {
        let paths = Set(PlantIDFiles.packPaths)
        for f in PlantIDModel.files + [PlantIDFiles.bank, PlantIDFiles.pipeline, PlantIDFiles.credits, PlantIDFiles.photoCredits] {
            #expect(paths.contains("\(PlantIDFiles.folder)/\(f)"), "\(f)")
        }
        #expect(paths.contains("\(PlantIDFiles.folder)/\(PlantIDFiles.encoder)/"))
        #expect(PlantIDModel.files.contains(PlantIDFiles.head))
        #expect(Pack.plantid.otherFiles == PlantIDFiles.packPaths && Pack.plantid.archives.isEmpty)
        #expect(Pack.refphotos.otherFiles == RefPhotoFiles.packPaths && Pack.refphotos.policy == .prefetch)
    }

    #if DEBUG
    @Test(arguments: ["species", "genus", "unsure", "mainland"])
    func fakeEngineGivesEachLadderStep(mode: String) async throws {
        let engine = PlantIDEngine(source: .fake(mode))
        let image = RGBImage(width: 300, height: 300, pixels: [UInt8](repeating: 90, count: 300 * 300 * 3))
        let r = try await engine.identify(image, location: GeoPoint(longitude: 147.32, latitude: -42.88))
        #expect(r.usedLocation)
        switch (mode, r.answer) {
        case ("species", .species), ("genus", .genus("Eucalyptus", _)), ("unsure", .notSure), ("mainland", .species(8, _)): break
        default: Issue.record("\(mode): \(r.answer)")
        }
        #expect(r.candidates.count == 5)
        if case .genus = r.answer { #expect(r.genusSpecies.count == 3) }
        #expect(r.candidates.contains { $0.nearbyRecords > 0 })
        await engine.release()
        #expect(await !engine.isLoaded)
    }
    #endif

    // MARK: The real model (local: the cache is gitignored)

    /// The staged pack (build_packs.py plantid): the single model loads,
    /// the credits and the model identity decode, and the Tasmania box
    /// takes the Tasmanian-bank path.
    @Test(.enabled(if: PlantIDModel.available(in: staged), "needs data/packs/stage-plantid (build_packs.py plantid)"))
    func stagedPack() throws {
        let m = try PlantIDModel(directory: Self.staged)
        #expect(m.labels.count == 22122 && m.dimension == 1024)
        let credits = try PlantIDCredits.load(Self.staged)
        #expect(credits.observers.count > 100_000 && credits.photos >= credits.observers.count)
        #expect(credits.sources?["ala"] != nil && credits.sources?["commons"] != nil)
        let id = try #require(PlantIDModelIdentity.load(Self.staged))
        #expect(id.id == "final-cb50-s1" && id.classes == 22122 && id.line.contains("git "))
        let e = [Float](repeating: 0.03, count: m.dimension)
        #expect(m.identify(embedding: e, location: GeoPoint(longitude: 151.21, latitude: -33.87)).scope == .australia)
        #expect(m.identify(embedding: e, location: GeoPoint(longitude: 147.33, latitude: -42.88)).scope == .tasmania)
        #expect(m.identify(embedding: e, location: nil).scope == .australia)
    }

    nonisolated static let ship = repo.appending(path: "pipeline/cache/plantid/ship")
    nonisolated static let staged = repo.appending(path: "data/packs/stage-plantid/plantid")
    nonisolated static let samples = repo.appending(path: "pipeline/cache/plantid/coreml/bioclip25/data")
    nonisolated static var haveModel: Bool {
        FileManager.default.fileExists(atPath: staged.appending(path: "\(PlantIDFiles.encoder)/coremldata.bin").path(percentEncoded: false))
            && FileManager.default.fileExists(atPath: samples.appending(path: "samples-f16.bin").path(percentEncoded: false))
    }

    /// The eval's three CC0 sample photos through the app's decode +
    /// preprocessing (vs Python's tensors) and the w8 encoder + scorer (vs
    /// Python's top-1: Blandfordia punicea, Bellendena montana, Leucopogon
    /// virgatus — `Ship` on their PyTorch fp32 embeddings, no location).
    @Test(.enabled(if: haveModel, "needs data/packs/stage-plantid (build_packs.py plantid) and the eval samples"),
          .timeLimit(.minutes(5)))
    func realModelMatchesPython() async throws {
        struct Info: Decodable {
            struct Sample: Decodable { var photo_id: Int; var species: String }
            var samples: [Sample]
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: Self.samples.appending(path: "test.json")))
        let tensors = try Data(contentsOf: Self.samples.appending(path: "samples-f16.bin"))
        let n = 3 * 224 * 224
        let engine = PlantIDEngine(source: .files(Self.staged))
        let start = ContinuousClock.now
        let (scorer, encoder) = try await engine.prepare()
        print("PlantID real model: loaded in \(start.duration(to: .now))")
        for (i, s) in info.samples.enumerated() {
            let photo = try PlantIDPhoto.decode(Data(contentsOf: Self.samples.appending(path: "samples/\(s.photo_id).jpg")))
            let mine = PlantIDPreprocess.tensor(photo.pixels)
            let theirs: [Float] = tensors.subdata(in: i * n * 2 ..< (i + 1) * n * 2).withUnsafeBytes {
                $0.bindMemory(to: Float16.self).map(Float.init)
            }
            let diffs = zip(mine, theirs).map { abs($0 - $1) }
            let mean = diffs.reduce(0, +) / Float(n)
            // JPEG decoders differ by ±1–2 levels (≈ 0.03 here); a colour
            // conversion or a wrong resize would be far off
            #expect(mean < 0.05, "\(s.photo_id): mean |Δ tensor| \(mean)")
            let t0 = ContinuousClock.now
            let e = try await encoder.embedding(mine)
            let r = scorer.identify(embedding: e, location: nil)
            let top = r.candidates[0]
            print("PlantID real model: \(s.photo_id) → \(scorer.labels[top.label].name) \(top.p) (\(r.answer)); tensor mean |Δ| \(mean), max \(diffs.max()!); embed \(t0.duration(to: .now))")
            #expect(scorer.labels[top.label].name == s.species, "\(s.photo_id)")
        }
        await engine.release()
    }
}
