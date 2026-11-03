import Foundation

/// An 8-bit RGB image, rows top first, pixels interleaved R G B.
public struct RGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 3, "RGB buffer size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The pixel rectangle (clamped to the image).
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> RGBImage {
        let x0 = min(max(x, 0), width - 1), y0 = min(max(y, 0), height - 1)
        let w = max(1, min(w, width - x0)), h = max(1, min(h, height - y0))
        var out = [UInt8](repeating: 0, count: w * h * 3)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0 ..< h {
                    let s = ((y0 + row) * width + x0) * 3
                    for i in 0 ..< w * 3 { dst[row * w * 3 + i] = src[s + i] }
                }
            }
        }
        return RGBImage(width: w, height: h, pixels: out)
    }
}

/// The encoder's input, exactly as open_clip's eval transform makes it
/// (pipeline.json `encoder.preprocess`; build_ship.py `preprocess`):
/// shortest side → 224 with Pillow's bicubic resampling, centre crop
/// 224 × 224, /255, CLIP mean/std, channels first. The resampler is a port
/// of Pillow's (libImaging/Resample.c: a = −0.5 cubic, support scaled by
/// the reduction, 22-bit fixed-point coefficients, horizontal pass then
/// vertical, uint8 between and after), so the bytes match Pillow's exactly
/// (PlantIDPreprocessTests).
public enum PlantIDPreprocess {
    public static let size = 224
    public static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    public static let std: [Float] = [0.26862954, 0.26130258, 0.27577711]

    /// torchvision Resize(int) + CenterCrop(224) → 224 × 224 RGB.
    public static func resizeCrop(_ image: RGBImage) -> RGBImage {
        let S = size, w = image.width, h = image.height
        // short side = 224, long side = int(224 · long / short)
        let (nw, nh) = w <= h ? (S, Int(Double(S) * Double(h) / Double(w))) : (Int(Double(S) * Double(w) / Double(h)), S)
        let resized = resample(image, width: nw, height: nh)
        // offsets round((W − 224) / 2), Python's round half to even
        let l = Int((Double(nw - S) / 2).rounded(.toNearestOrEven))
        let t = Int((Double(nh - S) / 2).rounded(.toNearestOrEven))
        return resized.cropped(x: l, y: t, width: S, height: S)
    }

    /// 1 × 3 × 224 × 224 float32, channels first.
    public static func tensor(_ image: RGBImage) -> [Float] {
        let img = image.width == size && image.height == size ? image : resizeCrop(image)
        let n = size * size
        var out = [Float](repeating: 0, count: 3 * n)
        img.pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0 ..< n {
                    for c in 0 ..< 3 { o[c * n + i] = (Float(p[i * 3 + c]) / 255 - mean[c]) / std[c] }
                }
            }
        }
        return out
    }

    // MARK: Pillow's resampler

    static let precisionBits = 32 - 8 - 2

    static func bicubic(_ x: Double) -> Double {
        let a = -0.5
        let x = abs(x)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// precompute_coeffs + normalize_coeffs_8bpc: per output pixel the first
    /// input index, the tap count and `ksize` fixed-point weights.
    static func coefficients(inSize: Int, outSize: Int) -> (ksize: Int, bounds: [(Int, Int)], kk: [Int32]) {
        let scale = Double(inSize) / Double(outSize)
        let filterscale = max(scale, 1)
        let support = 2.0 * filterscale
        let ksize = Int(support.rounded(.up)) * 2 + 1
        var bounds: [(Int, Int)] = []
        bounds.reserveCapacity(outSize)
        var kk = [Int32](repeating: 0, count: outSize * ksize)
        var k = [Double](repeating: 0, count: ksize)
        for xx in 0 ..< outSize {
            let center = (Double(xx) + 0.5) * scale
            let ss = 1 / filterscale
            // C's (int) truncates toward zero; then clamped at 0
            let xmin = max(Int(center - support + 0.5), 0)
            var xmax = Int(center + support + 0.5)
            if xmax > inSize { xmax = inSize }
            xmax -= xmin
            var ww = 0.0
            for x in 0 ..< ksize { k[x] = 0 }
            for x in 0 ..< xmax {
                let w = bicubic((Double(x + xmin) - center + 0.5) * ss)
                k[x] = w
                ww += w
            }
            for x in 0 ..< xmax where ww != 0 { k[x] /= ww }
            for x in 0 ..< ksize {
                let v = k[x] * Double(1 << precisionBits)
                kk[xx * ksize + x] = Int32(k[x] < 0 ? -0.5 + v : 0.5 + v)
            }
            bounds.append((xmin, xmax))
        }
        return (ksize, bounds, kk)
    }

    @inline(__always) static func clip8(_ v: Int32) -> UInt8 {
        let s = v >> Int32(precisionBits)
        return s < 0 ? 0 : s > 255 ? 255 : UInt8(s)
    }

    /// Image.resize((width, height), BICUBIC) of an RGB image.
    public static func resample(_ image: RGBImage, width: Int, height: Int) -> RGBImage {
        let (kh, bh, kkh) = coefficients(inSize: image.width, outSize: width)
        let (kv, bounds, kkv) = coefficients(inSize: image.height, outSize: height)
        var bv = bounds
        let needH = width != image.width
        let needV = height != image.height
        var current = image
        let half = Int32(1 << (precisionBits - 1))
        if needH {
            // only the rows the vertical pass reads
            let first = bv[0].0
            let last = bv[height - 1].0 + bv[height - 1].1
            for i in 0 ..< height { bv[i].0 -= first }
            let rows = last - first
            var out = [UInt8](repeating: 0, count: width * rows * 3)
            let inW = image.width
            image.pixels.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    kkh.withUnsafeBufferPointer { kk in
                        for yy in 0 ..< rows {
                            let rowBase = (yy + first) * inW * 3
                            for xx in 0 ..< width {
                                let (xmin, xmax) = bh[xx]
                                let k = xx * kh
                                var s0 = half, s1 = half, s2 = half
                                var p = rowBase + xmin * 3
                                for x in 0 ..< xmax {
                                    let w = kk[k + x]
                                    s0 &+= Int32(src[p]) &* w
                                    s1 &+= Int32(src[p + 1]) &* w
                                    s2 &+= Int32(src[p + 2]) &* w
                                    p += 3
                                }
                                let o = (yy * width + xx) * 3
                                dst[o] = clip8(s0)
                                dst[o + 1] = clip8(s1)
                                dst[o + 2] = clip8(s2)
                            }
                        }
                    }
                }
            }
            current = RGBImage(width: width, height: rows, pixels: out)
        }
        guard needV else { return current }
        let w = current.width
        var out = [UInt8](repeating: 0, count: w * height * 3)
        current.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                kkv.withUnsafeBufferPointer { kk in
                    for yy in 0 ..< height {
                        let (ymin, ymax) = bv[yy]
                        let k = yy * kv
                        for xx in 0 ..< w {
                            var s0 = half, s1 = half, s2 = half
                            var p = (ymin * w + xx) * 3
                            for y in 0 ..< ymax {
                                let wt = kk[k + y]
                                s0 &+= Int32(src[p]) &* wt
                                s1 &+= Int32(src[p + 1]) &* wt
                                s2 &+= Int32(src[p + 2]) &* wt
                                p += w * 3
                            }
                            let o = (yy * w + xx) * 3
                            dst[o] = clip8(s0)
                            dst[o + 1] = clip8(s1)
                            dst[o + 2] = clip8(s2)
                        }
                    }
                }
            }
        }
        return RGBImage(width: w, height: height, pixels: out)
    }
}
