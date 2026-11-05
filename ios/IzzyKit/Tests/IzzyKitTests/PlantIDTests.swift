import Foundation
import Testing
@testable import IzzyKit

@Suite struct PlantIDPreprocessTests {
    struct Fixture: Decodable {
        struct Case: Decodable { var crop: [Int]? }
        var source: [Int]
        var cases: [Case]
        var tensor_samples: [[Double]]
    }

    /// build_ship.synthetic_rgb: the same bytes, no photo.
    static func synthetic(_ w: Int, _ h: Int) -> RGBImage {
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 3
                px[i] = UInt8((x * 7 + y * 3) & 255)
                px[i + 1] = UInt8((x * y + 5 * x) & 255)
                px[i + 2] = UInt8((((x ^ y) * 9) + 40) & 255)
            }
        }
        return RGBImage(width: w, height: h, pixels: px)
    }

    /// Pillow's bicubic resize + centre crop, byte for byte.
    @Test func resizeCropMatchesPillow() throws {
        let f: Fixture = try TestData.fixture("plantid-preprocess.json")
        let want = try Data(contentsOf: TestData.fixtures.appending(path: "plantid-preprocess.bin"))
        let src = Self.synthetic(f.source[0], f.source[1])
        let n = 224 * 224 * 3
        for (i, c) in f.cases.enumerated() {
            let img = c.crop.map { src.cropped(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) } ?? src
            let got = PlantIDPreprocess.resizeCrop(img)
            #expect(got.width == 224 && got.height == 224)
            let expected = [UInt8](want[i * n ..< (i + 1) * n])
            let diff = zip(got.pixels, expected).filter { $0 != $1 }.count
            #expect(diff == 0, "case \(i): \(diff) of \(n) bytes differ from Pillow")
        }
        // normalisation: channels first, CLIP mean/std
        let t = PlantIDPreprocess.tensor(src)
        #expect(t.count == 3 * 224 * 224)
        for s in f.tensor_samples {
            let (c, y, x) = (Int(s[0]), Int(s[1]), Int(s[2]))
            #expect(abs(Double(t[c * 224 * 224 + y * 224 + x]) - s[3]) < 1e-6)
        }
    }

    @Test func squareInputPassesThrough() {
        let img = Self.synthetic(224, 224)
        #expect(PlantIDPreprocess.resizeCrop(img) == img)
    }
}
