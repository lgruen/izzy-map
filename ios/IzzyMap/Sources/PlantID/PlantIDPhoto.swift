import CoreGraphics
import Foundation
import ImageIO
import IzzyKit
import UIKit

/// A photo to identify: its pixels for the encoder, a smaller copy for the
/// screen, and where it was taken when the file says so.
///
/// The encoder's pixels follow the evaluation's preprocessing
/// (pipeline.json `encoder.preprocess`): the values as stored, the embedded
/// colour profile IGNORED — Pillow never converts, so an iPhone's Display
/// P3 photo is read as its raw P3 numbers, not converted to sRGB. They are
/// turned upright by the EXIF orientation (she frames what she sees; the
/// iNaturalist training photos are upright too). The screen copy is the
/// system's colour-managed thumbnail.
nonisolated struct PlantIDPhoto: Sendable {
    nonisolated enum Origin: Sendable { case camera, library }

    /// Upright, ≤ `maxPixels` on its long side.
    let pixels: RGBImage
    /// Upright, ≤ `displayPixels` on its long side, same aspect as `pixels`.
    let display: UIImage
    /// From the file's GPS metadata.
    let location: GeoPoint?
    let origin: Origin

    /// Largest long side kept for identification: a 12 MP photo whole; a
    /// 48 MP one is reduced (its crop still has ≥ 224 px unless she frames
    /// less than a twentieth of the width).
    static let maxPixels = 4096
    static let displayPixels = 2048

    nonisolated enum DecodeError: LocalizedError {
        case notAnImage
        var errorDescription: String? { "This file isn’t a photo IzzyMap can read." }
    }

    /// A photo file (PhotosPicker's data: JPEG, HEIC, PNG…).
    static func decode(_ data: Data, origin: Origin = .library) throws -> PlantIDPhoto {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0
        else { throw DecodeError.notAnImage }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let pixels: RGBImage
        if max(w, h) <= maxPixels, let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            pixels = upright(rawRGB(full), orientation)
        } else if let reduced = thumbnail(src, maxPixels) {
            // the system applies the orientation; its resampling only matters for huge photos
            pixels = rawRGB(reduced)
        } else {
            throw DecodeError.notAnImage
        }
        guard let shown = thumbnail(src, displayPixels) else { throw DecodeError.notAnImage }
        return PlantIDPhoto(pixels: pixels, display: UIImage(cgImage: shown), location: gps(props), origin: origin)
    }

    /// A camera capture (UIImagePickerController): the image is upright
    /// through `imageOrientation`; its metadata has no GPS.
    static func decode(camera image: UIImage) throws -> PlantIDPhoto {
        guard let cg = image.cgImage else { throw DecodeError.notAnImage }
        let o = CGImagePropertyOrientation(image.imageOrientation)
        var raw = rawRGB(cg, limit: maxPixels)
        raw = upright(raw, o)
        let display = UIGraphicsImageRenderer(size: fit(image.size, displayPixels), format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            return f
        }()).image { _ in image.draw(in: CGRect(origin: .zero, size: fit(image.size, displayPixels))) }
        return PlantIDPhoto(pixels: raw, display: display, location: nil, origin: .camera)
    }

    static func fit(_ size: CGSize, _ limit: Int) -> CGSize {
        let s = min(1, CGFloat(limit) / max(size.width, size.height))
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }

    private static func thumbnail(_ src: CGImageSource, _ limit: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// The stored RGB values: drawn into a context in the image's OWN colour
    /// space, so Core Graphics has nothing to convert (Pillow's behaviour).
    /// Grey or CMYK images are converted to sRGB (Pillow's convert("RGB")
    /// expands grey the same way). `limit` reduces a larger image first.
    static func rawRGB(_ image: CGImage, limit: Int? = nil) -> RGBImage {
        var w = image.width, h = image.height
        if let limit, max(w, h) > limit {
            let s = Double(limit) / Double(max(w, h))
            w = max(1, Int((Double(w) * s).rounded()))
            h = max(1, Int((Double(h) * s).rounded()))
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        rgba.withUnsafeBufferPointer { s in
            rgb.withUnsafeMutableBufferPointer { d in
                for i in 0 ..< w * h {
                    d[i * 3] = s[i * 4]
                    d[i * 3 + 1] = s[i * 4 + 1]
                    d[i * 3 + 2] = s[i * 4 + 2]
                }
            }
        }
        return RGBImage(width: w, height: h, pixels: rgb)
    }

    /// The pixels as displayed under an EXIF orientation (exact: a pure
    /// re-indexing, no resampling).
    static func upright(_ img: RGBImage, _ o: CGImagePropertyOrientation) -> RGBImage {
        if o == .up { return img }
        let W = img.width, H = img.height
        let swaps = [.left, .right, .leftMirrored, .rightMirrored].contains(o)
        let ow = swaps ? H : W, oh = swaps ? W : H
        var out = [UInt8](repeating: 0, count: ow * oh * 3)
        img.pixels.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for y in 0 ..< oh {
                    for x in 0 ..< ow {
                        // source pixel shown at (x, y)
                        let (sx, sy): (Int, Int) = switch o {
                        case .upMirrored: (W - 1 - x, y)
                        case .down: (W - 1 - x, H - 1 - y)
                        case .downMirrored: (x, H - 1 - y)
                        case .leftMirrored: (y, x)
                        case .right: (y, H - 1 - x)
                        case .rightMirrored: (W - 1 - y, H - 1 - x)
                        case .left: (W - 1 - y, x)
                        default: (x, y)
                        }
                        let si = (sy * W + sx) * 3, di = (y * ow + x) * 3
                        d[di] = s[si]
                        d[di + 1] = s[si + 1]
                        d[di + 2] = s[si + 2]
                    }
                }
            }
        }
        return RGBImage(width: ow, height: oh, pixels: out)
    }

    /// Latitude/longitude from the file's GPS dictionary (S and W negative).
    static func gps(_ props: [CFString: Any]) -> GeoPoint? {
        guard let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = (g[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (g[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        else { return nil }
        let south = (g[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (g[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        let point = GeoPoint(longitude: west ? -abs(lon) : lon, latitude: south ? -abs(lat) : lat)
        guard abs(point.latitude) <= 90, abs(point.longitude) <= 180, point.latitude != 0 || point.longitude != 0 else { return nil }
        return point
    }

    /// The pixels inside `crop` (unit coordinates of the upright photo),
    /// whole pixels.
    func pixels(in crop: CGRect) -> RGBImage {
        let W = Double(pixels.width), H = Double(pixels.height)
        let x = Int((crop.minX * W).rounded()), y = Int((crop.minY * H).rounded())
        let w = Int((crop.width * W).rounded()), h = Int((crop.height * H).rounded())
        return pixels.cropped(x: x, y: y, width: max(1, w), height: max(1, h))
    }

    /// The screen copy's part inside `crop` (her crop beside the candidates).
    func displayCrop(_ crop: CGRect) -> UIImage {
        guard let cg = display.cgImage else { return display }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let r = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H).integral
        return cg.cropping(to: r).map { UIImage(cgImage: $0) } ?? display
    }

    /// The photo's aspect (width / height), upright.
    var aspect: CGFloat { CGFloat(pixels.width) / CGFloat(pixels.height) }
}

extension CGImagePropertyOrientation {
    nonisolated init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
