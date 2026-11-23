import CoreLocation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A photo ready to join a pin: the bytes to keep, the strip's thumbnail
/// and the facts the row records.
nonisolated struct PinPhotoImport: Sendable {
    /// HEIC or JPEG (`PinPhotoPipeline`).
    let original: Data
    /// JPEG, `PinPhotoPipeline.thumbnailShortSide` on its short side.
    let thumbnail: Data
    /// Upright pixel size of `original`.
    let width: Int
    let height: Int
    /// The EXIF capture date, when the file has one.
    let capturedAt: Date?
    var bytes: Int { original.count }
}

/// From a camera capture or a library pick to a `PinPhotoImport`
/// (docs/PINS_PLAN.md §3, "Photos"). Pure and synchronous: callers run it
/// off the main actor, one photo at a time, so at most one full image is
/// decoded at once.
///
/// - Camera: HEIC (JPEG where the system has no HEIC encoder), long edge at
///   most `maxLongEdge`, quality `quality`, the pixels as the sensor gave
///   them with the orientation TAGGED (no re-rendering of a 12 MP image),
///   the capture date and — when a fix is known — the position in EXIF.
/// - Library: HEIC and JPEG up to `maxLongEdge` keep their original bytes
///   (the photo is hers, as she took it); larger ones (24/48 MP) and other
///   formats (PNG, TIFF, RAW…) are re-encoded the camera's way — HEIC, long
///   edge `maxLongEdge`, upright — with their EXIF date and GPS carried over.
/// - Encoding falls back to JPEG when HEIC fails: a capture is lost only if
///   both fail (the picker never saves it to the library).
nonisolated enum PinPhotoPipeline {
    static let maxLongEdge = 4032
    static let quality = 0.8
    static let thumbnailShortSide = 400
    /// The thumbnail's JPEG quality steps: the first that lands under
    /// `thumbnailMaxBytes` wins (a busy photo needs a lower one).
    static let thumbnailQualities: [Double] = [0.72, 0.6, 0.5, 0.4]
    static let thumbnailMaxBytes = 60_000

    nonisolated enum ImportError: LocalizedError {
        case notAnImage
        case encodeFailed
        /// The library couldn't hand the photo over — most often one kept
        /// only in iCloud ("Optimise Storage") while offline.
        case notOnDevice
        var errorDescription: String? {
            switch self {
            case .notAnImage: "Not a photo IzzyMap can read."
            case .encodeFailed: "The photo couldn’t be saved."
            case .notOnDevice: "That photo isn’t on this device — it needs a connection to download."
            }
        }
    }

    /// Where the camera stood (from a Core Location fix).
    nonisolated struct Position: Sendable, Equatable {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
        var accuracy: Double?
        var timestamp: Date

        init(latitude: Double, longitude: Double, altitude: Double? = nil, accuracy: Double? = nil, timestamp: Date) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.accuracy = accuracy
            self.timestamp = timestamp
        }

        init(_ fix: CLLocation) {
            self.init(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                      altitude: fix.verticalAccuracy > 0 ? fix.altitude : nil,
                      accuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil, timestamp: fix.timestamp)
        }
    }

    /// The encoder for new files: HEIC, or JPEG where ImageIO has none.
    static let encodeType: UTType = {
        let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return types.contains(UTType.heic.identifier) ? .heic : .jpeg
    }()

    // MARK: Camera

    /// A camera capture (UIImagePickerController's original image and its
    /// `mediaMetadata`).
    static func camera(_ image: UIImage, metadata: [String: Any]? = nil, position: Position?, date: Date,
                       timeZone: TimeZone = .current) throws -> PinPhotoImport {
        guard var cg = image.cgImage else { throw ImportError.notAnImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        if max(cg.width, cg.height) > maxLongEdge {
            guard let scaled = scale(cg, longEdge: maxLongEdge) else { throw ImportError.encodeFailed }
            cg = scaled
        }
        var props: [CFString: Any] = [:]
        // what the camera said (lens, exposure…), then ours on top
        for (key, value) in metadata ?? [:] { props[key as CFString] = value }
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let stamp = exifDate(date, timeZone: timeZone)
        exif[kCGImagePropertyExifDateTimeOriginal] = exif[kCGImagePropertyExifDateTimeOriginal] ?? stamp.date
        exif[kCGImagePropertyExifDateTimeDigitized] = exif[kCGImagePropertyExifDateTimeDigitized] ?? stamp.date
        exif[kCGImagePropertyExifOffsetTimeOriginal] = exif[kCGImagePropertyExifOffsetTimeOriginal] ?? stamp.offset
        exif[kCGImagePropertyExifPixelXDimension] = cg.width
        exif[kCGImagePropertyExifPixelYDimension] = cg.height
        props[kCGImagePropertyExifDictionary] = exif
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = orientation.rawValue
        tiff[kCGImagePropertyTIFFDateTime] = stamp.date
        props[kCGImagePropertyTIFFDictionary] = tiff
        props[kCGImagePropertyOrientation] = orientation.rawValue
        if let position { props[kCGImagePropertyGPSDictionary] = gps(position) }
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        let data = try encode(cg, properties: props)
        return try finish(data, capturedAt: date)
    }

    // MARK: Library

    /// A library pick (PhotosPicker's data with `.current` encoding: the
    /// file as stored).
    static func library(_ data: Data) throws -> PinPhotoImport {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src).flatMap({ UTType($0 as String) })
        else { throw ImportError.notAnImage }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let kept = type.conforms(to: .heic) || type.conforms(to: .heif) || type.conforms(to: .jpeg)
        if kept, let size = uprightSize(props), max(size.width, size.height) <= maxLongEdge {
            return try finish(data, source: src)
        }
        // re-encode: upright at most `maxLongEdge`, its EXIF and GPS carried over
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0, let upright = thumbnail(src, maxPixels: min(maxLongEdge, max(w, h))) else {
            throw ImportError.notAnImage
        }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary] {
            if let value = props[key] { out[key] = value }
        }
        out[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        let encoded = try encode(upright, properties: out)
        return try finish(encoded, capturedAt: nil)
    }

    // MARK: Pieces

    /// Thumbnail, size and capture date of finished bytes.
    private static func finish(_ data: Data, capturedAt: Date? = nil, source: CGImageSource? = nil) throws -> PinPhotoImport {
        guard let src = source ?? CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImportError.notAnImage }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        guard let size = uprightSize(props) else { throw ImportError.notAnImage }
        guard let thumb = thumbnailJPEG(src, size: size) else { throw ImportError.notAnImage }
        return PinPhotoImport(original: data, thumbnail: thumb, width: size.width, height: size.height,
                              capturedAt: captureDate(props) ?? capturedAt)
    }

    /// Pixel size as displayed (EXIF orientations 5–8 swap the sides).
    static func uprightSize(_ props: [CFString: Any]) -> (width: Int, height: Int)? {
        guard let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 ? (h, w) : (w, h)
    }

    /// Upright JPEG, `thumbnailShortSide` on the short side (never enlarged),
    /// at the first quality step under `thumbnailMaxBytes`.
    static func thumbnailJPEG(_ src: CGImageSource, size: (width: Int, height: Int)) -> Data? {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        let target = short <= thumbnailShortSide ? long
            : Int((Double(long) * Double(thumbnailShortSide) / Double(short)).rounded())
        guard let image = thumbnail(src, maxPixels: target) else { return nil }
        var last: Data?
        for q in thumbnailQualities {
            guard let data = jpeg(image, quality: q) else { return nil }
            last = data
            if data.count <= thumbnailMaxBytes { break }
        }
        return last
    }

    /// ImageIO's resampling, orientation applied.
    static func thumbnail(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// The image in the first of `types` that encodes (HEIC, then JPEG).
    static func encode(_ image: CGImage, properties: [CFString: Any],
                       types: [UTType] = [encodeType, .jpeg]) throws -> Data {
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        for type in types {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            if CGImageDestinationFinalize(dest), out.length > 0 { return out as Data }
        }
        throw ImportError.encodeFailed
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The image redrawn at `longEdge` on its long side (same orientation).
    private static func scale(_ image: CGImage, longEdge: Int) -> CGImage? {
        let s = Double(longEdge) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: EXIF

    /// "2026:11:24 10:42:07" and "+11:00" in `timeZone`.
    static func exifDate(_ date: Date, timeZone: TimeZone) -> (date: String, offset: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let seconds = timeZone.secondsFromGMT(for: date)
        let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        return (f.string(from: date), offset)
    }

    /// DateTimeOriginal, with its offset when the file has one (else the
    /// device's time zone — the camera's clock was local).
    static func captureDate(_ props: [CFString: Any]) -> Date? {
        guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = f.date(from: text + offset) { return date }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)
    }

    /// The EXIF GPS dictionary for a fix (unsigned degrees with N/S, E/W).
    static func gps(_ p: Position) -> [CFString: Any] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd"
        let date = f.string(from: p.timestamp)
        f.dateFormat = "HH:mm:ss.SS"
        var g: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(p.latitude),
            kCGImagePropertyGPSLatitudeRef: p.latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude: abs(p.longitude),
            kCGImagePropertyGPSLongitudeRef: p.longitude < 0 ? "W" : "E",
            kCGImagePropertyGPSDateStamp: date,
            kCGImagePropertyGPSTimeStamp: f.string(from: p.timestamp),
        ]
        if let altitude = p.altitude {
            g[kCGImagePropertyGPSAltitude] = abs(altitude)
            g[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
        }
        if let accuracy = p.accuracy { g[kCGImagePropertyGPSHPositioningError] = accuracy }
        return g
    }

    // MARK: Showing

    /// The original decoded at about `pixels` on its long side, upright (the viewer).
    static func image(_ data: Data, pixels: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = thumbnail(src, maxPixels: pixels) else { return nil }
        return UIImage(cgImage: cg)
    }
}
