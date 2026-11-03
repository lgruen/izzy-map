import CoreGraphics
import Foundation
import ImageIO

/// Photo → normalised 1×3×S×S tensor, roughly like open_clip (shortest side
/// to S, centre crop). Approximate: Core Graphics' resampling isn't Pillow's
/// bicubic and the photo is converted to sRGB (Pillow ignores the profile).
/// The three test photos use the laptop's exact tensors; this is only for
/// "try your own photo".
enum Preprocess {
    static func tensor(_ data: Data, size S: Int, mean: [Float], std: [Float]) throws -> [Float] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw TestError("not an image") }
        // decode at a reduced size (a 48 MP photo would be ~200 MB) with the
        // EXIF orientation applied
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: S * 6,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw TestError("couldn't decode the photo")
        }
        let scale = CGFloat(S) / CGFloat(min(img.width, img.height))
        let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
        guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw TestError("couldn't make a drawing context") }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (CGFloat(S) - w) / 2, y: (CGFloat(S) - h) / 2, width: w, height: h))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw TestError("no pixels") }
        let n = S * S
        var out = [Float](repeating: 0, count: 3 * n)
        for i in 0 ..< n {  // bitmap memory is top row first
            for c in 0 ..< 3 { out[c * n + i] = (Float(p[i * 4 + c]) / 255 - mean[c]) / std[c] }
        }
        return out
    }
}
