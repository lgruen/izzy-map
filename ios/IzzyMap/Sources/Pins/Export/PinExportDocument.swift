import Foundation
import ImageIO
import IzzyKit
import SwiftData
import UniformTypeIdentifiers

// The pins export, first half (docs/PINS_PLAN.md §6): pins → the plain
// `ExportDocument` IzzyKit's DocxWriter writes. Everything here is plain
// values and runs off the main actor; the only store access is reading one
// photo original at a time from a context of its own.

/// What is exported, read on the main actor when the export starts: plain
/// values (no model objects cross actors).
nonisolated struct PinExportSnapshot: Sendable, Equatable {
    /// The document's title: the project's name, or "Unfiled pins".
    var title: String
    /// The file's stem: the project's name, or "Unfiled".
    var fileStem: String
    /// In date order, oldest first.
    var pins: [Pin]

    struct Pin: Sendable, Equatable {
        var title: String
        var note: String
        var createdAt: Date
        var lat: Double
        var lon: Double
        /// In the order they were added (oldest first).
        var photos: [Photo]
    }

    struct Photo: Sendable, Equatable {
        var id: UUID
        var caption: String
    }

    var photoCount: Int { pins.reduce(0) { $0 + $1.photos.count } }

    /// The pins of `project` (nil: Unfiled) — all of them, or those in `only`.
    @MainActor
    static func make(project: PinProject?, pins: [SavedPin], only: Set<UUID>? = nil) -> PinExportSnapshot {
        let chosen = pins.filter { only?.contains($0.id) ?? true }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return PinExportSnapshot(
            title: project.map { PinText.projectName($0.name) } ?? "Unfiled pins",
            fileStem: project.map { PinText.projectName($0.name) } ?? "Unfiled",
            pins: chosen.map { pin in
                Pin(title: pin.displayTitle, note: pin.note, createdAt: pin.createdAt, lat: pin.lat, lon: pin.lon,
                    photos: (pin.photos ?? []).sorted { ($0.sort, $0.createdAt) < ($1.sort, $1.createdAt) }
                        .map { Photo(id: $0.id, caption: $0.caption) })
            })
    }
}

/// Pins → `ExportDocument`, file names, and the photos' export copies.
nonisolated enum PinExport {
    /// Long edge of a photo in the document (two across on A4: ~83 mm at
    /// ~490 dpi — sharp when she zooms in, small enough for Drive).
    static let photoLongEdge = 1600
    static let photoQuality = 0.8
    /// Google Docs converts Word files up to 50 MB.
    static let googleDocsLimit = 50_000_000

    // MARK: The document

    /// The document for `snapshot`. `photo` is asked for each photo's
    /// export JPEG in order (nil: left out); `includePhotos` false asks for
    /// none. Cancellable between photos.
    static func document(_ snapshot: PinExportSnapshot, includePhotos: Bool, now: Date = Date(),
                         photo: (PinExportSnapshot.Photo) async throws -> ExportDocument.Photo?) async throws -> ExportDocument {
        var sections: [ExportDocument.Section] = []
        var photos = 0
        for pin in snapshot.pins {
            var section = ExportDocument.Section(heading: pin.title, meta: meta(pin), link: mapsLink(lat: pin.lat, lon: pin.lon),
                                                 body: pin.note)
            if includePhotos {
                for p in pin.photos {
                    try Task.checkCancellation()
                    if let done = try await photo(p) { section.photos.append(done) }
                }
            }
            photos += section.photos.count
            sections.append(section)
        }
        return ExportDocument(title: snapshot.title, subtitle: subtitle(snapshot, photos: photos), sections: sections)
    }

    /// "3 – 24 November 2026" and "8 pins · 9 photos" (no photo count without photos).
    static func subtitle(_ snapshot: PinExportSnapshot, photos: Int) -> [String] {
        var lines: [String] = []
        if let range = dateRange(snapshot.pins.map(\.createdAt)) { lines.append(range) }
        lines.append(PinText.count(pins: snapshot.pins.count, photos: photos))
        return lines
    }

    /// The whole range with its year — a document outlives "this year".
    static func dateRange(_ dates: [Date], calendar: Calendar = .current) -> String? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let style = Date.FormatStyle.dateTime.day().month(.wide).year()
        if calendar.isDate(first, inSameDayAs: last) { return first.formatted(style) }
        return (first ..< last).formatted(.interval.day().month(.wide).year())
    }

    /// Date and time; lat/lon (5 dp); the MGA55 grid reference.
    static func meta(_ pin: PinExportSnapshot.Pin) -> [String] {
        [
            pin.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute()),
            GridReadout.latLon.text(latitude: pin.lat, longitude: pin.lon),
            GridReadout.mga.text(latitude: pin.lat, longitude: pin.lon),
        ]
    }

    /// "Open in Google Maps": a search for the point (opens the Maps app
    /// or the website, on any device the document travels to).
    static func mapsLink(lat: Double, lon: Double) -> ExportDocument.Link {
        let query = GridReadout.latLon.text(latitude: lat, longitude: lon).replacingOccurrences(of: " ", with: "")
        var c = URLComponents(string: "https://www.google.com/maps/search/")!
        c.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
        return ExportDocument.Link(text: "Open in Google Maps", url: c.url!)
    }

    // MARK: File name

    /// "<Project> — pins 2026-11-24.docx", with what file systems refuse
    /// left out (/ \ : * ? " < > |, control characters, leading dots).
    static func fileName(stem: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
        return "\(safeStem(stem)) — pins \(day).docx"
    }

    /// The name with forbidden characters dropped, whitespace runs folded,
    /// at most 100 characters and 150 UTF-8 bytes (file names stop at 255
    /// bytes, and the date part follows); "Pins" for nothing left.
    static func safeStem(_ stem: String) -> String {
        let forbidden = Set("/\\:*?\"<>|")
        // line breaks and tabs become spaces first (they're control characters too)
        let spaced = String(String.UnicodeScalarView(stem.unicodeScalars.map { $0.properties.isWhitespace ? " " : $0 }))
        var kept = String(String.UnicodeScalarView(spaced.unicodeScalars.filter { s in
            !(s.properties.generalCategory == .control || s.properties.generalCategory == .format && s.value != 0x200D)
                && !forbidden.contains(Character(s))
        }))
        kept = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while kept.hasPrefix(".") { kept.removeFirst() }
        kept = String(kept.prefix(100))
        while kept.utf8.count > 150 { kept.removeLast() }
        kept = kept.trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? "Pins" : kept
    }

    // MARK: Photos

    /// An original (HEIC or JPEG, any orientation) → the document's copy:
    /// at most `photoLongEdge` on its long side (never enlarged), upright
    /// (orientation applied to the pixels), sRGB, JPEG at `photoQuality`,
    /// and NO metadata — no EXIF, no GPS, no TIFF block (the document may
    /// be passed on; its text carries the coordinates). ImageIO decodes
    /// straight to the reduced size, so a 12 MP original never sits in
    /// memory at full size.
    static func exportJPEG(_ original: Data, caption: String = "") -> ExportDocument.Photo? {
        guard let src = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        guard let size = PinPhotoPipeline.uprightSize(props) else { return nil }
        let target = min(photoLongEdge, max(size.width, size.height))
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // only encoder options: the image itself carries no properties
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: photoQuality,
            kCGImageDestinationOptimizeColorForSharing: true,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0, let jpeg = stripMetadata(out as Data) else { return nil }
        return ExportDocument.Photo(jpeg: jpeg, pixelWidth: image.width, pixelHeight: image.height, caption: caption)
    }

    /// The JPEG without its APP1–APP15 and comment segments. ImageIO's encoder always
    /// writes a small Exif block (colour space, pixel size) and an empty
    /// Photoshop/IPTC one even for an image with no properties; dropping
    /// every application segment but JFIF (APP0) and an ICC profile (APP2
    /// "ICC_PROFILE") makes "no metadata" a guarantee rather than an
    /// encoder habit. nil: not a well-formed JPEG header.
    static func stripMetadata(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var out = Data([0xFF, 0xD8])
        var i = 2
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }                  // fill byte
            if marker == 0xDA {                                      // start of scan: the rest is image data
                out.append(contentsOf: bytes[i...])
                return out
            }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2, i + 2 + length <= bytes.count else { return nil }
            let segment = bytes[i ..< i + 2 + length]
            let isICC = marker == 0xE2 && bytes[(i + 4) ..< min(i + 15, bytes.count)].elementsEqual(Array("ICC_PROFILE".utf8))
            let isMetadata = (0xE1 ... 0xEF).contains(marker) || marker == 0xFE    // APPn, comment
            if !isMetadata || isICC { out.append(contentsOf: segment) }
            i += 2 + length
        }
        return nil
    }

    /// One photo's original, read in a context of its own (so the bytes
    /// never join the main context, which keeps the pins alive). nil: the
    /// photo or its original is gone.
    static func original(of photo: UUID, in container: ModelContainer) -> Data? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PinPhoto>(predicate: #Predicate { $0.id == photo })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.original?.data
    }

    /// Photos a build left out.
    struct Omitted: Equatable, Sendable {
        /// The original isn't on this device (yet — iCloud may still be bringing it).
        var notOnDevice = 0
        /// The original couldn't be read as an image.
        var unreadable = 0
        var total: Int { notOnDevice + unreadable }

        /// "2 photos weren’t on this device yet and were left out." (and/or
        /// "1 photo couldn’t be read and was left out."); nil for none.
        var sentence: String? {
            var parts: [String] = []
            if notOnDevice > 0 {
                parts.append(notOnDevice == 1 ? "1 photo wasn’t on this device yet and was left out."
                             : "\(notOnDevice.formatted()) photos weren’t on this device yet and were left out.")
            }
            if unreadable > 0 {
                parts.append(unreadable == 1 ? "1 photo couldn’t be read and was left out."
                             : "\(unreadable.formatted()) photos couldn’t be read and were left out.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Builds the .docx off the main actor, one photo at a time — read,
    /// downsampled, its original released before the next is read, so
    /// memory stays flat however many photos there are. `progress(done,
    /// total)` counts photos (and 1 for writing the file). Photos it had
    /// to leave out are counted, so the sheet can say so.
    @concurrent
    static func build(_ snapshot: PinExportSnapshot, includePhotos: Bool, container: ModelContainer, now: Date = Date(),
                      progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> (data: Data, omitted: Omitted) {
        let total = (includePhotos ? snapshot.photoCount : 0) + 1
        var done = 0
        var omitted = Omitted()
        await progress(0, total)
        let document = try await document(snapshot, includePhotos: includePhotos, now: now) { photo in
            enum Outcome { case ok(ExportDocument.Photo), missing, unreadable }
            let outcome = autoreleasepool { () -> Outcome in
                guard let data = original(of: photo.id, in: container) else { return .missing }
                return exportJPEG(data, caption: photo.caption).map(Outcome.ok) ?? .unreadable
            }
            done += 1
            await progress(done, total)
            switch outcome {
            case let .ok(jpeg): return jpeg
            case .missing: omitted.notOnDevice += 1
            case .unreadable: omitted.unreadable += 1
            }
            return nil
        }
        try Task.checkCancellation()
        let data = try DocxWriter.data(for: document, created: now)
        await progress(total, total)
        return (data, omitted)
    }
}

/// Where exports are written before they go to the share sheet: one
/// folder per export under tmp/PinExports, emptied at launch.
nonisolated enum PinExportFiles {
    static var root: URL { FileManager.default.temporaryDirectory.appending(path: "PinExports", directoryHint: .isDirectory) }

    /// Writes `data` as `name` in a fresh folder; the file's URL.
    static func write(_ data: Data, name: String) throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// At launch: whatever earlier sessions left behind.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
