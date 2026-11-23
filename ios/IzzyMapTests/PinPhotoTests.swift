import CoreImage
import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import IzzyMap

// MARK: - Helpers

/// Within a few pixels (ImageIO's HEIC decoder subsamples on its own grid:
/// asked for 533 × 400 it may give 533 × 398).
private func near(_ a: (Int, Int), _ b: (Int, Int), by slack: Int = 4) -> Bool {
    abs(a.0 - b.0) <= slack && abs(a.1 - b.1) <= slack
}

/// A stand-in for a real 12 MP photo's detail: the drawn landscape under
/// fractal noise (octaves of random noise, amplitude growing with scale —
/// natural images have about a 1/f spectrum, which is what makes their
/// files large; a flat drawing compresses to a tenth).
private func naturalScene(seed: Int, size: CGSize) -> UIImage {
    let base = CIImage(cgImage: PinTestPhoto.image(seed: seed, size: size).cgImage!)
    let extent = CGRect(origin: .zero, size: size)
    var detail = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
    for (i, scale) in [1.0, 2, 4, 8, 16, 32].enumerated() {
        let weight = 0.05 * pow(scale, 0.35)
        let octave = noise
            .transformed(by: CGAffineTransform(translationX: CGFloat(seed * 97 + i * 31), y: CGFloat(i * 53)))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
                "inputBiasVector": CIVector(x: -weight / 2, y: -weight / 2, z: -weight / 2, w: 0),
            ])
            .cropped(to: extent)
        detail = octave.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: detail])
    }
    let mixed = detail.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: base]).cropped(to: extent)
    let cg = CIContext().createCGImage(mixed, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    return UIImage(cgImage: cg)
}

/// An image drawn in a known layout: the left half red, the right half
/// blue (in its stored pixels), `w` × `h`, at scale 1.
private func halves(_ w: Int, _ h: Int) -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        UIColor.blue.setFill()
        ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    }.cgImage!
}

/// `image` encoded as `type` with `properties` (EXIF, orientation…).
private func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func properties(_ data: Data) -> [CFString: Any] {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
}

private func type(_ data: Data) -> UTType? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
}

private func pixelSize(_ data: Data) -> (Int, Int) {
    let p = properties(data)
    return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
}

/// The RGB of one pixel of a decoded JPEG (x, y as fractions).
private func colour(_ data: Data, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
    let image = UIImage(data: data)!.cgImage!
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let w = Double(image.width), h = Double(image.height)
    ctx.draw(image, in: CGRect(x: -x * w, y: -(1 - y) * h, width: w, height: h))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

/// A wall-clock date with whole seconds (EXIF keeps seconds).
private let shotAt = Date(timeIntervalSince1970: 1_795_000_000)
private let hobart = TimeZone(identifier: "Australia/Hobart")!

// MARK: - Pipeline

@Suite struct PinPhotoPipelineTests {
    @Test func aCameraCaptureIsHEICCappedAt4032WithOrientationTagged() throws {
        // a 4800 × 3600 sensor image held upright by `.right` (a portrait shot)
        let image = UIImage(cgImage: halves(4800, 3600), scale: 1, orientation: .right)
        let result = try PinPhotoPipeline.camera(image, position: nil, date: shotAt, timeZone: hobart)
        #expect(type(result.original) == PinPhotoPipeline.encodeType)
        #expect(PinPhotoPipeline.encodeType == .heic, "the simulator's ImageIO encodes HEIC")
        // stored as the sensor gave it, long edge 4032, orientation 6 (= .right) tagged
        #expect(pixelSize(result.original) == (4032, 3024))
        #expect((properties(result.original)[kCGImagePropertyOrientation] as? Int) == 6)
        // the row records the UPRIGHT size
        #expect(result.width == 3024 && result.height == 4032)
        #expect(result.bytes == result.original.count)
    }

    @Test func orientationReachesTheThumbnailUpright() throws {
        // stored left half red: shown rotated a quarter turn clockwise
        // (`.right`), red is on top
        let image = UIImage(cgImage: halves(1200, 900), scale: 1, orientation: .right)
        let result = try PinPhotoPipeline.camera(image, position: nil, date: shotAt)
        let (tw, th) = pixelSize(result.thumbnail)
        #expect(near((tw, th), (400, 533)), "portrait, 400 on the short side: \(tw)×\(th)")
        let top = colour(result.thumbnail, x: 0.5, y: 0.2), bottom = colour(result.thumbnail, x: 0.5, y: 0.8)
        #expect(top.r > 200 && top.b < 60, "top \(top)")
        #expect(bottom.b > 200 && bottom.r < 60, "bottom \(bottom)")
    }

    @Test func aCaptureCarriesItsDateAndPositionInEXIF() throws {
        let image = UIImage(cgImage: halves(800, 600), scale: 1, orientation: .up)
        let fix = PinPhotoPipeline.Position(latitude: -42.8806, longitude: 147.3250, altitude: 312, accuracy: 5, timestamp: shotAt)
        let result = try PinPhotoPipeline.camera(image, metadata: [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifFNumber as String: 1.6]],
                                                 position: fix, date: shotAt, timeZone: hobart)
        let p = properties(result.original)
        let exif = try #require(p[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let expected = PinPhotoPipeline.exifDate(shotAt, timeZone: hobart)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == expected.date)
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == expected.offset)
        #expect(expected.offset == "+11:00" || expected.offset == "+10:00")
        // the camera's own metadata is kept
        #expect((exif[kCGImagePropertyExifFNumber] as? Double) == 1.6)
        let gps = try #require(p[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "S")
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "E")
        #expect(abs((gps[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 42.8806) < 1e-6)
        #expect(abs((gps[kCGImagePropertyGPSLongitude] as? Double ?? 0) - 147.3250) < 1e-6)
        #expect(abs((gps[kCGImagePropertyGPSAltitude] as? Double ?? 0) - 312) < 1e-6)
        // read back the way IzzyMap reads any photo
        #expect(PlantIDPhoto.gps(p).map { abs($0.latitude + 42.8806) < 1e-6 && abs($0.longitude - 147.325) < 1e-6 } == true)
        #expect(result.capturedAt == shotAt)
        #expect(PinPhotoPipeline.captureDate(p) == shotAt)
    }

    @Test func noFixNoGPS() throws {
        let image = UIImage(cgImage: halves(800, 600), scale: 1, orientation: .up)
        let result = try PinPhotoPipeline.camera(image, position: nil, date: shotAt)
        #expect(properties(result.original)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func aLibraryJPEGKeepsItsOriginalBytes() throws {
        let stamp = PinPhotoPipeline.exifDate(shotAt, timeZone: hobart)
        let jpeg = encode(halves(1600, 1200), as: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: stamp.date,
                                             kCGImagePropertyExifOffsetTimeOriginal: stamp.offset],
        ])
        let result = try PinPhotoPipeline.library(jpeg)
        #expect(result.original == jpeg)
        #expect(result.bytes == jpeg.count)
        #expect(result.width == 1600 && result.height == 1200)
        #expect(result.capturedAt == shotAt)
        #expect(near(pixelSize(result.thumbnail), (533, 400)), "\(pixelSize(result.thumbnail))")
    }

    @Test func aLibraryHEICUpTo4032KeepsItsOriginalBytes() throws {
        let heic = encode(halves(4032, 3024), as: .heic, properties: [kCGImagePropertyOrientation: 6])
        let result = try PinPhotoPipeline.library(heic)
        #expect(result.original == heic, "her photo, as she took it")
        #expect(result.width == 3024 && result.height == 4032, "orientation 6: upright is portrait")
        #expect(result.capturedAt == nil)
        #expect(near(pixelSize(result.thumbnail), (400, 533)), "\(pixelSize(result.thumbnail))")
    }

    /// A 24/48 MP pick is re-encoded like a capture: HEIC, long edge 4032,
    /// upright (orientation baked in), its EXIF date and GPS carried over.
    @Test func aLargeLibraryPickIsReencodedLikeACapture() throws {
        let stamp = PinPhotoPipeline.exifDate(shotAt, timeZone: hobart)
        let fix = PinPhotoPipeline.Position(latitude: -42.8806, longitude: 147.3250, timestamp: shotAt)
        // 8064 × 6048 (48 MP) stored left half red, held upright by orientation 6
        let big = encode(halves(8064, 6048), as: .heic, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: stamp.date,
                                             kCGImagePropertyExifOffsetTimeOriginal: stamp.offset],
            kCGImagePropertyGPSDictionary: PinPhotoPipeline.gps(fix),
        ])
        let result = try PinPhotoPipeline.library(big)
        #expect(result.original != big)
        #expect(type(result.original) == .heic)
        #expect(pixelSize(result.original) == (3024, 4032), "upright, long edge 4032")
        #expect((properties(result.original)[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(result.width == 3024 && result.height == 4032)
        #expect(result.capturedAt == shotAt, "EXIF date carried over")
        #expect(PlantIDPhoto.gps(properties(result.original)).map { abs($0.latitude + 42.8806) < 1e-6 } == true, "GPS carried over")
        // red was on the left of the stored pixels: upright, it is on top
        let top = colour(result.thumbnail, x: 0.5, y: 0.2)
        #expect(top.r > 200 && top.b < 60, "top \(top)")
        // a large JPEG goes the same way
        let jpeg = try PinPhotoPipeline.library(encode(halves(6000, 4000), as: .jpeg))
        #expect(type(jpeg.original) == .heic && pixelSize(jpeg.original) == (4032, 2688))
    }

    /// HEIC that can't be written falls back to JPEG: a capture is lost only
    /// when both fail.
    @Test func encodingFallsBackToJPEG() throws {
        let image = halves(800, 600)
        let none = UTType(importedAs: "org.gruenschloss.izzymap.test.no-encoder")
        let data = try PinPhotoPipeline.encode(image, properties: [:], types: [none, .jpeg])
        #expect(type(data) == .jpeg)
        #expect(throws: PinPhotoPipeline.ImportError.self) { try PinPhotoPipeline.encode(image, properties: [:], types: [none]) }
    }

    @Test func otherFormatsAreTranscodedToHEICUprightAndCapped() throws {
        let png = encode(halves(5000, 2000), as: .png, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:03:01 09:30:00"],
        ])
        let result = try PinPhotoPipeline.library(png)
        #expect(type(result.original) == .heic)
        #expect(pixelSize(result.original) == (4032, 1613))
        #expect(result.width == 4032 && result.height == 1613)
        #expect((properties(result.original)[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(result.capturedAt != nil, "its EXIF date is carried over")
        #expect(near(pixelSize(result.thumbnail), (1000, 400)), "\(pixelSize(result.thumbnail))")
    }

    @Test func notAPhotoThrows() {
        #expect(throws: PinPhotoPipeline.ImportError.self) { try PinPhotoPipeline.library(Data("hello".utf8)) }
    }

    /// A 12 MP capture of a busy scene: the HEIC's size, the thumbnail
    /// inside its byte bounds, and the time per photo (printed).
    @Test func a12MPCaptureAndItsThumbnailStayInBounds() throws {
        let image = naturalScene(seed: 3, size: CGSize(width: 4032, height: 3024))
        let start = ContinuousClock.now
        let result = try PinPhotoPipeline.camera(image, position: nil, date: shotAt)
        let took = ContinuousClock.now - start
        print("PINPHOTO 12MP heic=\(result.original.count) thumb=\(result.thumbnail.count) took=\(took)")
        #expect(pixelSize(result.original) == (4032, 3024))
        #expect(near(pixelSize(result.thumbnail), (533, 400)), "\(pixelSize(result.thumbnail))")
        #expect(result.thumbnail.count <= PinPhotoPipeline.thumbnailMaxBytes)
        #expect(result.thumbnail.count >= 10_000)
        #expect(result.original.count > 200_000 && result.original.count < 6_000_000)
    }

    @Test func aSmallPhotoIsNeverEnlarged() throws {
        let result = try PinPhotoPipeline.library(encode(halves(300, 200), as: .jpeg))
        #expect(near(pixelSize(result.thumbnail), (300, 200)), "\(pixelSize(result.thumbnail))")
    }
}

// MARK: - Store

@MainActor
@Suite struct PinPhotoStoreTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "izzymap-pinphotos-\(UUID().uuidString)")! }

    private func photo(_ seed: Int = 0, size: Int = 600) throws -> PinPhotoImport {
        try PinPhotoPipeline.library(PinTestPhoto.jpeg(seed: seed, size: CGSize(width: size, height: size * 3 / 4)))
    }

    /// Adds through the store (a context of its own), returns the main context's record.
    private func add(_ s: PinStore, _ imported: PinPhotoImport, to pin: SavedPin) throws -> PinPhoto {
        let id = try #require(try s.addPhoto(imported, to: pin))
        return try #require(s.photo(id))
    }

    /// What is SAVED (a separate context).
    private func count<T: PersistentModel>(_ type: T.Type, _ store: PinStore) throws -> Int {
        try ModelContext(store.container).fetchCount(FetchDescriptor<T>())
    }

    @Test func photosJoinNewestFirstAndAreSavedAtOnce() throws {
        let clock = DateBox()
        let s = PinStore.inMemory(defaults: defaults(), now: { clock.now })
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let a = try add(s, try photo(1), to: pin)
        clock.advance(days: 1)
        let b = try add(s, try photo(2), to: pin)
        #expect(pin.sortedPhotos.map(\.id) == [b.id, a.id])
        #expect(a.sort == 0 && b.sort == 1)
        #expect(pin.modifiedAt == clock.now)
        #expect(a.original?.data?.isEmpty == false && a.bytes == a.original?.data?.count)
        #expect(try count(PinPhoto.self, s) == 2 && count(PinPhotoOriginal.self, s) == 2)
        #expect(s.photoCount(s.pins) == 2)
    }

    @Test func aCaptionIsSavedOnFlush() throws {
        let s = PinStore.inMemory(defaults: defaults())
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let p = try add(s, try photo(), to: pin)
        s.setCaption(p, "Seed heads")
        #expect(try ModelContext(s.container).fetch(FetchDescriptor<PinPhoto>()).first?.caption == "")
        s.flush()
        #expect(try ModelContext(s.container).fetch(FetchDescriptor<PinPhoto>()).first?.caption == "Seed heads")
    }

    @Test func deletingAPhotoRemovesItAndItsOriginal() throws {
        let s = PinStore.inMemory(defaults: defaults())
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let a = try add(s, try photo(1), to: pin)
        let b = try add(s, try photo(2), to: pin)
        s.deletePhoto(b)
        #expect(pin.sortedPhotos.map(\.id) == [a.id])
        #expect(try count(PinPhoto.self, s) == 1 && count(PinPhotoOriginal.self, s) == 1)
    }

    @Test func photosFollowThePinThroughSoftDeleteRestoreAndPurge() throws {
        let clock = DateBox()
        let s = PinStore.inMemory(defaults: defaults(), now: { clock.now })
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        try s.addPhoto(try photo(1), to: pin)
        try s.addPhoto(try photo(2), to: pin)
        s.delete(pin)
        #expect(s.deletedPins.first?.photos?.count == 2, "a deleted pin keeps its photos")
        #expect(s.photoCount(s.pins) == 0)
        s.restore(pin)
        #expect(s.pins.first?.photos?.count == 2)
        s.delete(pin)
        clock.advance(days: 31)
        s.purge()
        #expect(try count(SavedPin.self, s) == 0)
        #expect(try count(PinPhoto.self, s) == 0 && count(PinPhotoOriginal.self, s) == 0)
    }

    @Test func deleteNowTakesThePhotosToo() throws {
        let s = PinStore.inMemory(defaults: defaults())
        let project = s.addProject(name: "Knocklofty", colour: .teal)
        let inProject = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        try s.addPhoto(try photo(1), to: inProject)
        s.setProject(inProject, project)
        let alone = s.addPin(latitude: -42.8, longitude: 147.2, placedBy: .map)
        s.setProject(alone, nil)
        try s.addPhoto(try photo(2), to: alone)
        let third = s.addPin(latitude: -42.7, longitude: 147.1, placedBy: .map)
        try s.addPhoto(try photo(3), to: third)
        #expect(try count(PinPhoto.self, s) == 3)

        s.delete(alone)
        s.deleteNow(alone)
        #expect(try count(PinPhoto.self, s) == 2 && count(PinPhotoOriginal.self, s) == 2)
        s.deleteProject(project)
        s.deleteNow(project)
        #expect(try count(PinPhoto.self, s) == 1 && count(PinPhotoOriginal.self, s) == 1)
        s.delete(third)
        s.deleteAllNow()
        #expect(try count(PinPhoto.self, s) == 0 && count(PinPhotoOriginal.self, s) == 0)
    }

    /// The batch: several photos, one that fails; the rest arrive, the
    /// failure is reported once, the report stays until dismissed.
    @Test func aBatchCarriesOnPastAFailureAndReportsIt() async throws {
        let s = PinStore.inMemory(defaults: defaults())
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.importPhotos([
            .file { PinTestPhoto.jpeg(seed: 1, size: CGSize(width: 800, height: 600)) },
            .file { Data("not a photo".utf8) },
            .file { PinTestPhoto.jpeg(seed: 2, size: CGSize(width: 600, height: 800)) },
        ], to: pin.id)
        #expect(s.photoImports[pin.id] == PinStore.PhotoImport(total: 3))
        for _ in 0 ..< 200 where s.photoImports[pin.id]?.finished != true { try await Task.sleep(for: .milliseconds(25)) }
        #expect(s.photoImports[pin.id] == PinStore.PhotoImport(total: 3, done: 2, failed: 1, reason: "Not a photo IzzyMap can read."))
        #expect(pin.photos?.count == 2)
        #expect(s.photoCount(of: pin) == 2)
        s.dismissPhotoImport(pin.id)
        #expect(s.photoImports[pin.id] == nil)
    }

    /// A pick the library can't hand over says why in plain words.
    @Test func aPhotoNotOnTheDeviceSaysWhy() async throws {
        let s = PinStore.inMemory(defaults: defaults())
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.importPhotos([.file { throw PinPhotoPipeline.ImportError.notOnDevice }], to: pin.id)
        for _ in 0 ..< 200 where s.photoImports[pin.id]?.finished != true { try await Task.sleep(for: .milliseconds(25)) }
        #expect(s.photoImports[pin.id]?.reason == "That photo isn’t on this device — it needs a connection to download.")
    }

    /// The photo is written by a context of its own; typing not yet saved
    /// in the main context survives it, and the lists see the photo.
    @Test func aBackgroundInsertKeepsPendingTypingAndShowsUp() async throws {
        let clock = DateBox()
        let s = PinStore.inMemory(defaults: defaults(), now: { clock.now })
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.setTitle(pin, "Seep")  // not saved yet
        clock.advance(days: 1)
        s.importPhotos([.file { PinTestPhoto.jpeg(seed: 1, size: CGSize(width: 800, height: 600)) }], to: pin.id)
        s.setNote(pin, "Sphagnum")  // typed while it imports
        for _ in 0 ..< 200 where s.photoImports[pin.id] != nil { try await Task.sleep(for: .milliseconds(25)) }
        s.flush()
        let saved = try #require(try ModelContext(s.container).fetch(FetchDescriptor<SavedPin>()).first)
        #expect(saved.title == "Seep" && saved.note == "Sphagnum")
        #expect(saved.photos?.count == 1)
        #expect(pin.photos?.count == 1 && s.photoCount(of: pin) == 1 && s.coverPhoto(of: pin) == pin.sortedPhotos.first?.id)
        #expect(pin.modifiedAt == clock.now)
    }

    /// Counts and covers come from the store's index and follow every change.
    @Test func photoCountsAndCoversFollowChanges() throws {
        let s = PinStore.inMemory(defaults: defaults())
        let a = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let b = s.addPin(latitude: -42.8, longitude: 147.2, placedBy: .map)
        #expect(s.photoCount(of: a) == 0 && s.coverPhoto(of: a) == nil)
        let first = try add(s, try photo(1), to: a)
        let second = try add(s, try photo(2), to: a)
        try s.addPhoto(try photo(3), to: b)
        #expect(s.photoCount(of: a) == 2 && s.photoCount([a, b]) == 3)
        #expect(s.coverPhoto(of: a) == second.id, "the newest")
        s.deletePhoto(second)
        #expect(s.photoCount(of: a) == 1 && s.coverPhoto(of: a) == first.id)
        #expect(s.thumbnail(first.id) == first.thumbnail)
    }

    @Test func aCleanBatchLeavesNoReport() async throws {
        let s = PinStore.inMemory(defaults: defaults())
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        s.importPhotos((0 ..< 25).map { i in .file { PinTestPhoto.jpeg(seed: i, size: CGSize(width: 320, height: 240)) } }, to: pin.id)
        #expect(s.photoImports[pin.id]?.total == PinStore.photosPerPick, "at most 20 per pick")
        for _ in 0 ..< 400 where s.photoImports[pin.id] != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(s.photoImports[pin.id] == nil)
        #expect(pin.photos?.count == PinStore.photosPerPick)
    }

    /// On disk: the originals live beside the store (external storage),
    /// the size on disk counts them, and purging takes them away.
    @Test func originalsAreExternalCountedAndRemovedWhenPurged() async throws {
        let dir = URL.temporaryDirectory.appending(path: "pinphotos-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Pins.store")
        let clock = DateBox()
        let s = PinStore(container: PinStore.makeContainer(url: url).container, defaults: defaults(), now: { clock.now })
        let before = await s.bytesOnDisk()
        let pin = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        let big = try PinPhotoPipeline.camera(PinTestPhoto.image(seed: 5, size: CGSize(width: 4032, height: 3024)),
                                              position: nil, date: shotAt)
        let id = try #require(try s.addPhoto(big, to: pin))
        let after = await s.bytesOnDisk()
        #expect(after - before >= big.bytes, "the size on disk includes the photo (\(before) → \(after), photo \(big.bytes))")
        let external = externalFiles(dir)
        #expect(!external.isEmpty, "the original is an external file")
        // the viewer reads it back in a context of its own
        let shown = await PinStore.originalImage(photo: id, in: s.container, pixels: 1024)
        #expect(shown.map { max($0.size.width, $0.size.height) } == 1024)
        // a page paged past cancels its load: nothing is read or decoded
        let container = s.container
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PinStore.originalImage(photo: id, in: container, pixels: 1024)
        }.value
        #expect(cancelled == nil)

        s.delete(pin)
        clock.advance(days: 31)
        s.purge()
        #expect(externalFiles(dir).isEmpty, "purged with its pin: \(externalFiles(dir))")
    }

    private func externalFiles(_ dir: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        var found: [String] = []
        while let url = walker?.nextObject() as? URL {
            if url.path.contains("_EXTERNAL_DATA"), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(url.lastPathComponent)
            }
        }
        return found
    }
}

// MARK: - Words

@Suite struct PinPhotoTextTests {
    @Test func countsSayPhotosOnlyWhenThereAreSome() {
        #expect(PinText.count(pins: 12, photos: 0) == "12 pins")
        #expect(PinText.count(pins: 12, photos: 5) == "12 pins · 5 photos")
        #expect(PinText.count(pins: 1, photos: 1) == "1 pin · 1 photo")
        #expect(PinText.photoCount(1_200) == "\(1_200.formatted()) photos")
    }

    /// The viewer follows the photo she opened, not a position.
    @Test func theViewerKeepsItsPhotoWhenTheListChanges() {
        let a = UUID(), b = UUID(), c = UUID(), new = UUID()
        // she looks at b (page 1); an import puts a new photo in front
        #expect(PinViewerSelection.index(of: b, in: [new, a, b, c], lastIndex: 1) == 2)
        #expect(PinViewerSelection.resolve(selected: b, in: [new, a, b, c], lastIndex: 1)! == (b, 2))
        // b is deleted (here or in another window): the neighbour in its place
        #expect(PinViewerSelection.resolve(selected: b, in: [a, c], lastIndex: 1)! == (c, 1))
        // the last one deleted: the one before it
        #expect(PinViewerSelection.resolve(selected: c, in: [a, b], lastIndex: 2)! == (b, 1))
        // none left: the viewer closes
        #expect(PinViewerSelection.resolve(selected: a, in: [], lastIndex: 0) == nil)
    }
}

// MARK: - Migration

/// The slice-2 models exactly as they shipped in fdb6936 (no photos): a
/// store they wrote must open with today's schema — a lightweight
/// migration, no plan — keeping every pin and project.
nonisolated enum PinSchemaSlice2 {
    @Model
    nonisolated final class PinProject {
        var id: UUID = UUID()
        var name: String = ""
        var colour: String = "orange"
        var note: String = ""
        var createdAt: Date = Date.distantPast
        var modifiedAt: Date = Date.distantPast
        var archivedAt: Date?
        var deletedAt: Date?
        @Relationship(deleteRule: .nullify, inverse: \SavedPin.project)
        var pins: [SavedPin]? = []
        init(name: String) { self.name = name }
    }

    @Model
    nonisolated final class SavedPin {
        var id: UUID = UUID()
        var project: PinProject?
        var lat: Double = 0
        var lon: Double = 0
        var title: String = ""
        var note: String = ""
        var colour: String?
        var createdAt: Date = Date.distantPast
        var modifiedAt: Date = Date.distantPast
        var deletedAt: Date?
        var placedBy: String = "map"
        var accuracy: Double?
        var altitude: Double?
        init(title: String, lat: Double, lon: Double) {
            self.title = title
            self.lat = lat
            self.lon = lon
        }
    }
}

@MainActor
@Suite struct PinMigrationTests {
    @Test func aSlice2StoreOpensWithPhotosAndKeepsItsPins() throws {
        let dir = URL.temporaryDirectory.appending(path: "pins-migrate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Pins.store")
        let projectID: UUID
        do {
            let schema = Schema([PinSchemaSlice2.PinProject.self, PinSchemaSlice2.SavedPin.self])
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
            let context = ModelContext(old)
            let project = PinSchemaSlice2.PinProject(name: "Knocklofty")
            projectID = project.id
            context.insert(project)
            let a = PinSchemaSlice2.SavedPin(title: "Seep", lat: -42.88, lon: 147.30)
            a.project = project
            context.insert(a)
            let b = PinSchemaSlice2.SavedPin(title: "Gate", lat: -42.87, lon: 147.31)
            b.deletedAt = Date()
            context.insert(b)
            try context.save()
        }
        let opened = PinStore.makeContainer(url: url)
        #expect(!opened.failed, "the store opens (a lightweight migration)")
        let s = PinStore(container: opened.container, defaults: UserDefaults(suiteName: "izzymap-migrate-\(UUID().uuidString)")!)
        #expect(s.pins.map(\.title) == ["Seep"])
        #expect(s.deletedPins.map(\.title) == ["Gate"])
        #expect(s.projects.map(\.id) == [projectID] && s.pins.first?.project?.name == "Knocklofty")
        #expect(s.pins.first?.photos?.isEmpty != false)
        // and photos can join the old pins, and survive reopening
        let pin = try #require(s.pins.first)
        try s.addPhoto(try PinPhotoPipeline.library(PinTestPhoto.jpeg(seed: 1, size: CGSize(width: 400, height: 300))), to: pin)
        let again = PinStore(container: PinStore.makeContainer(url: url).container,
                             defaults: UserDefaults(suiteName: "izzymap-migrate-\(UUID().uuidString)")!)
        #expect(again.pins.first?.photos?.count == 1)
    }
}
