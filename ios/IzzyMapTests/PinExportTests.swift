import Foundation
import ImageIO
import IzzyKit
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import IzzyMap

// The export's first half (docs/PINS_PLAN.md §6): pins → ExportDocument,
// the photos' export copies, the file name.

/// A JPEG with EXIF (camera, date), GPS and a TIFF block, `w` × `h` stored
/// pixels, the left half red and the right half blue, tagged `orientation`.
private func taggedJPEG(_ w: Int, _ h: Int, orientation: Int = 1) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        UIColor.blue.setFill()
        ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    }.cgImage!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:20 10:00:00",
                                         kCGImagePropertyExifLensModel: "Test lens"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.88, kCGImagePropertyGPSLatitudeRef: "S",
                                        kCGImagePropertyGPSLongitude: 147.32, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test", kCGImagePropertyTIFFModel: "Camera"],
    ] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// The JPEG's application segments (marker bytes 0xE0…0xEF) before the scan.
private func appSegments(_ jpeg: Data) -> [UInt8] {
    let b = [UInt8](jpeg)
    var i = 2, out: [UInt8] = []
    while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
        if (0xE0 ... 0xEF).contains(b[i + 1]) { out.append(b[i + 1]) }
        i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
    }
    return out
}

private func pixel(_ jpeg: Data, x: Double, y: Double) -> (r: Int, b: Int) {
    let src = CGImageSourceCreateWithData(jpeg as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let px = CGFloat(x) * CGFloat(image.width), py = CGFloat(y) * CGFloat(image.height)
    ctx.draw(image, in: CGRect(x: -px, y: -(CGFloat(image.height) - py), width: CGFloat(image.width), height: CGFloat(image.height)))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(p[0]), Int(p[2]))
}

@Suite struct PinExportPhotoTests {
    @Test func aLargePhotoIs1600OnItsLongEdgeAndCarriesNoMetadata() throws {
        let photo = try #require(PinExport.exportJPEG(taggedJPEG(4032, 3024), caption: "Seep"))
        #expect((photo.pixelWidth, photo.pixelHeight) == (1600, 1200))
        #expect(photo.caption == "Seep")
        let src = try #require(CGImageSourceCreateWithData(photo.jpeg as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "no GPS")
        #expect(props[kCGImagePropertyExifDictionary] == nil, "no EXIF")
        #expect(props[kCGImagePropertyTIFFDictionary] == nil, "no TIFF (camera make/model)")
        #expect(props[kCGImagePropertyIPTCDictionary] == nil, "no IPTC")
        // only JFIF (APP0) and at most an ICC profile (APP2) remain
        #expect(Set(appSegments(photo.jpeg)).isSubset(of: [0xE0, 0xE2]), "\(appSegments(photo.jpeg))")
        #expect(photo.jpeg.range(of: Data("Test lens".utf8)) == nil)
    }

    @Test func aSmallPhotoIsNeverEnlarged() throws {
        let photo = try #require(PinExport.exportJPEG(taggedJPEG(800, 600)))
        #expect((photo.pixelWidth, photo.pixelHeight) == (800, 600))
    }

    /// EXIF orientation 6 (rotate 90° clockwise to show): the copy is
    /// portrait, upright in its pixels, and says nothing about orientation.
    @Test func orientationIsBakedIntoThePixels() throws {
        // stored 2000 × 1500: red left, blue right → shown rotated, red on top
        let photo = try #require(PinExport.exportJPEG(taggedJPEG(2000, 1500, orientation: 6)))
        #expect((photo.pixelWidth, photo.pixelHeight) == (1200, 1600))
        let src = try #require(CGImageSourceCreateWithData(photo.jpeg as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let top = pixel(photo.jpeg, x: 0.5, y: 0.1), bottom = pixel(photo.jpeg, x: 0.5, y: 0.9)
        #expect(top.r > 200 && top.b < 60, "red on top: \(top)")
        #expect(bottom.b > 200 && bottom.r < 60, "blue at the bottom: \(bottom)")
    }

    @Test func notAnImageGivesNothing() {
        #expect(PinExport.exportJPEG(Data("hello".utf8)) == nil)
        #expect(PinExport.stripMetadata(Data([0x00, 0x01, 0x02, 0x03, 0x04])) == nil)
    }

    /// Memory stays flat: 60 photos through the export path one at a time
    /// grow the footprint by well under the size of a few decoded originals.
    @Test func sixtyPhotosKeepMemoryFlat() throws {
        let original = taggedJPEG(4032, 3024)
        func footprint() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return Int(info.phys_footprint)
        }
        // warm up the codecs
        _ = autoreleasepool { PinExport.exportJPEG(original) }
        let before = footprint()
        var total = 0
        for _ in 0 ..< 60 {
            total += autoreleasepool { PinExport.exportJPEG(original)?.jpeg.count ?? 0 }
        }
        let grown = footprint() - before
        #expect(total > 0)
        // one decoded 12 MP original is ~48 MB; 60 held at once would be ~3 GB
        #expect(grown < 100_000_000, "grew \(grown / 1_000_000) MB")
    }
}

@MainActor
@Suite struct PinExportDocumentTests {
    private func store() -> PinStore {
        PinStore.inMemory(defaults: UserDefaults(suiteName: "izzymap-export-\(UUID().uuidString)")!,
                          now: { Date(timeIntervalSince1970: 1_795_000_000) })
    }

    private func date(_ day: Int, _ hour: Int = 10) -> Date {
        var c = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 11, day: day, hour: hour)
        c.minute = 30
        return c.date!
    }

    @Test func pinsGoInDateOrderWithTheRowsFallbackTitles() async throws {
        let s = store()
        let project = s.addProject(name: "Knocklofty Reserve", colour: .teal)
        let late = s.addPin(latitude: -42.88, longitude: 147.32, placedBy: .map)
        late.createdAt = date(20)
        s.setTitle(late, "Lookout")
        let early = s.addPin(latitude: -42.87654, longitude: 147.301239, placedBy: .map)
        early.createdAt = date(13)
        s.setNote(early, "Sphagnum, Richea\nCheck again in spring")
        let bare = s.addPin(latitude: -42.9, longitude: 147.3, placedBy: .map)
        bare.createdAt = date(15)
        s.flush()
        s.reload()

        let snapshot = PinExportSnapshot.make(project: project, pins: s.pins(in: project))
        #expect(snapshot.title == "Knocklofty Reserve")
        #expect(snapshot.pins.map(\.title) == ["Sphagnum, Richea", bare.displayTitle, "Lookout"])
        #expect(snapshot.pins[1].title.hasPrefix("Pin · "))

        let doc = try await PinExport.document(snapshot, includePhotos: true) { _ in nil }
        #expect(doc.title == "Knocklofty Reserve")
        #expect(doc.sections.map(\.heading) == ["Sphagnum, Richea", bare.displayTitle, "Lookout"])
        #expect(doc.subtitle.count == 2)
        #expect(doc.subtitle[1] == "3 pins")
        #expect(doc.subtitle[0].contains("13") && doc.subtitle[0].contains("20") && doc.subtitle[0].contains("2026"))

        let first = doc.sections[0]
        #expect(first.body == "Sphagnum, Richea\nCheck again in spring")
        #expect(first.meta.count == 3)
        #expect(first.meta[0].contains("2026") && first.meta[0].contains("13"))
        #expect(first.meta[1] == "-42.87654, 147.30124")
        #expect(first.meta[2] == GridReadout.mga.text(latitude: -42.87654, longitude: 147.301239))
        #expect(first.meta[2].hasPrefix("MGA55 ") && first.meta[2].hasSuffix("N"))
        #expect(first.link?.text == "Open in Google Maps")
        #expect(first.link?.url.absoluteString == "https://www.google.com/maps/search/?api=1&query=-42.87654,147.30124")
    }

    @Test func aSelectionAndUnfiled() throws {
        let s = store()
        let a = s.addPin(latitude: -42.88, longitude: 147.32, placedBy: .map)
        let b = s.addPin(latitude: -42.89, longitude: 147.33, placedBy: .map)
        s.setTitle(a, "A")
        s.setTitle(b, "B")
        s.flush()
        let snapshot = PinExportSnapshot.make(project: nil, pins: s.pins(in: nil), only: [b.id])
        #expect(snapshot.title == "Unfiled pins")
        #expect(snapshot.fileStem == "Unfiled")
        #expect(snapshot.pins.map(\.title) == ["B"])
    }

    @Test func photosComeInTheOrderAddedWithCaptionsAndCount() async throws {
        let s = store()
        let project = s.addProject(name: "Site", colour: .gold)
        let pin = s.addPin(latitude: -42.88, longitude: 147.32, placedBy: .map)
        for i in 0 ..< 3 {
            let id = try #require(try s.addPhoto(PinPhotoPipeline.library(taggedJPEG(1000 + i * 100, 800)), to: pin))
            s.setCaption(try #require(s.photo(id)), "Photo \(i)")
        }
        s.flush()
        s.reload()
        let snapshot = PinExportSnapshot.make(project: project, pins: s.pins(in: project))
        #expect(snapshot.pins[0].photos.map(\.caption) == ["Photo 0", "Photo 1", "Photo 2"])
        #expect(snapshot.photoCount == 3)

        var progress: [Int] = []
        let (data, omitted) = try await PinExport.build(snapshot, includePhotos: true, container: s.container) { done, _ in progress.append(done) }
        #expect(progress.last == 4, "3 photos + writing")
        #expect(omitted.total == 0)
        // the file holds three JPEGs, widths in order, none carrying GPS
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("word/media/image3.jpg"))
        #expect(!text.contains("word/media/image4.jpg"))

        let doc = try await PinExport.document(snapshot, includePhotos: true) { photo in
            PinExport.original(of: photo.id, in: s.container).flatMap { PinExport.exportJPEG($0, caption: photo.caption) }
        }
        #expect(doc.sections[0].photos.map(\.pixelWidth) == [1000, 1100, 1200])
        #expect(doc.subtitle.last == "1 pin · 3 photos")

        let textOnly = try await PinExport.document(snapshot, includePhotos: false) { _ in Issue.record("no photo asked for"); return nil }
        #expect(textOnly.sections[0].photos.isEmpty)
        #expect(textOnly.subtitle.last == "1 pin")
    }

    /// A photo whose original isn't on the device (iCloud still bringing
    /// it) is left out and counted, never a broken picture.
    @Test func photosNotOnTheDeviceAreCounted() async throws {
        let s = store()
        let pin = s.addPin(latitude: -42.88, longitude: 147.32, placedBy: .map)
        _ = try s.addPhoto(PinPhotoPipeline.library(taggedJPEG(1200, 900)), to: pin)
        s.reload()
        var snapshot = PinExportSnapshot.make(project: nil, pins: s.pins(in: nil))
        snapshot.pins[0].photos.append(.init(id: UUID(), caption: "gone"))
        let (data, omitted) = try await PinExport.build(snapshot, includePhotos: true, container: s.container) { _, _ in }
        #expect(omitted == PinExport.Omitted(notOnDevice: 1))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("word/media/image1.jpg") && !text.contains("word/media/image2.jpg"))
        #expect(text.contains("1 pin · 1 photo"), "the document counts what it holds")
    }

    @Test func buildingStopsWhenCancelled() async throws {
        let s = store()
        let pin = s.addPin(latitude: -42.88, longitude: 147.32, placedBy: .map)
        for _ in 0 ..< 3 { _ = try s.addPhoto(PinPhotoPipeline.library(taggedJPEG(1200, 900)), to: pin) }
        s.reload()
        let snapshot = PinExportSnapshot.make(project: nil, pins: s.pins(in: nil))
        let task = Task { try await PinExport.document(snapshot, includePhotos: true) { _ in
            try await Task.sleep(for: .seconds(5)); return nil
        } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct PinExportFileNameTests {
    /// 24 Nov 2026, 08:00 in Hobart = 23 Nov, 21:00 UTC: the date is local.
    private let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "Australia/Hobart"),
                                     year: 2026, month: 11, day: 24, hour: 8).date!
    private let hobart = TimeZone(identifier: "Australia/Hobart")!

    @Test func projectNameDashPinsDate() {
        #expect(PinExport.fileName(stem: "Knocklofty Reserve", date: day, timeZone: hobart) == "Knocklofty Reserve — pins 2026-11-24.docx")
    }

    @Test func charactersFileSystemsRefuseAreLeftOut() {
        #expect(PinExport.safeStem("Site A/B: \"north\" <stage 2> | *?\\") == "Site AB north stage 2")
        #expect(PinExport.safeStem("..hidden") == "hidden")
        #expect(PinExport.safeStem("  tabs\tand\nlines  ") == "tabs and lines")
        #expect(PinExport.safeStem("bell\u{07}\u{200E}") == "bell")
        #expect(PinExport.safeStem("///") == "Pins")
        #expect(PinExport.safeStem(String(repeating: "x", count: 300)).count == 100)
        #expect(PinExport.safeStem(String(repeating: "植", count: 90)).utf8.count <= 150, "a file name stops at 255 bytes")
        #expect(PinExport.safeStem("Waterworks Reserve — creek line, stage 2") == "Waterworks Reserve — creek line, stage 2")
    }
}
