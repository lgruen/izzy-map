import Foundation
import ImageIO

/// One layer of a detailed area, as the registry keeps it.
public struct AreaLayerRecord: Codable, Sendable, Equatable {
    public var layer: AreaLayer
    /// Every candidate tile fetched and the archive written.
    public var complete: Bool
    /// Candidate tiles (0 until the layer was first planned).
    public var planned: Int
    /// Tiles answered so far: stored plus absent (404, blank).
    public var done: Int
    /// Tiles holding an image.
    public var stored: Int
    /// Bytes on the device (work file while downloading, archive once complete).
    public var bytes: Int64
    /// Why the last run stopped short (shown under the row), nil when it didn't.
    public var stopped: String?
    /// The deepest level kept when the detail asked for was over the
    /// per-layer cap (a season flown everywhere in a large frame): the layer
    /// finishes at this level instead. nil: the detail asked for.
    public var cappedAt: Int?

    public init(layer: AreaLayer, complete: Bool = false, planned: Int = 0, done: Int = 0, stored: Int = 0,
                bytes: Int64 = 0, stopped: String? = nil, cappedAt: Int? = nil) {
        self.layer = layer
        self.complete = complete
        self.planned = planned
        self.done = done
        self.stored = stored
        self.bytes = bytes
        self.stopped = stopped
        self.cappedAt = cappedAt
    }

    /// File names inside the area's folder.
    public var archiveName: String { "\(layer.rawValue).pmtiles" }
    public var absentLogName: String { "\(layer.rawValue).absent" }
    public var strikesName: String { "\(layer.rawValue).strikes" }

    /// Every file a layer may leave in its area's folder: the archive, the
    /// writer's work files, the absent log and the strike list.
    public static func fileNames(_ layer: AreaLayer) -> [String] {
        let a = "\(layer.rawValue).pmtiles"
        return [a, a + ".tiles", a + ".journal", a + ".partial", "\(layer.rawValue).absent", "\(layer.rawValue).strikes"]
    }

    /// The deepest level the layer holds (or will) at `detail`.
    public func maxZoom(detail: AreaDetail) -> Int {
        cappedAt ?? AreaPlan.zooms(layer, detail: detail).upperBound
    }
}

/// A detailed area: the framed box, its layers and how far each got.
public struct AreaRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var box: AreaBox
    public var detail: AreaDetail
    public var created: Date
    /// In paint order (topo first).
    public var layers: [AreaLayerRecord]

    public init(id: String = AreaRecord.newID(), name: String, box: AreaBox, detail: AreaDetail,
                created: Date = .now, layers: [AreaLayer]) {
        self.id = id
        self.name = AreaRecord.cleanName(name)
        self.box = box
        self.detail = detail
        self.created = created
        self.layers = layers.sorted().map { AreaLayerRecord(layer: $0) }
    }

    /// Eight lowercase hex digits: a folder name and a style-id fragment.
    public static func newID() -> String {
        String(format: "%08x", UInt32.random(in: 0 ... .max))
    }

    public var isComplete: Bool { layers.allSatisfy(\.complete) }
    public var bytes: Int64 { layers.reduce(0) { $0 + $1.bytes } }
    public var planned: Int { layers.reduce(0) { $0 + $1.planned } }
    public var done: Int { layers.reduce(0) { $0 + $1.done } }

    public subscript(layer: AreaLayer) -> AreaLayerRecord? {
        get { layers.first { $0.layer == layer } }
        set {
            guard let newValue, let i = layers.firstIndex(where: { $0.layer == layer }) else { return }
            layers[i] = newValue
        }
    }

    /// Longest name kept.
    public static let maxNameLength = 40

    /// Trimmed, single-line, at most 40 characters.
    public static func cleanName(_ name: String) -> String {
        let flat = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(maxNameLength))
    }
}

/// Every detailed area on the device (`areas.json`).
public struct AreaRegistry: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = AreaRegistry.currentVersion
    public var areas: [AreaRecord] = []
    /// Measured tile sizes per layer kind (`AreaLayer.calibrationKey`);
    /// optional, so a version-1 file without it still reads.
    public var calibration: [String: AreaCalibration]?

    public init(areas: [AreaRecord] = [], calibration: [String: AreaCalibration]? = nil) {
        self.areas = areas
        self.calibration = calibration
    }

    /// The registry at `url`; empty when there is none yet. A file of
    /// another version or a corrupt one throws (never overwritten blindly).
    public static func load(from url: URL) throws -> AreaRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return AreaRegistry() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let registry = try decoder.decode(AreaRegistry.self, from: Data(contentsOf: url))
        guard registry.version == currentVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "areas.json version \(registry.version)"])
        }
        return registry
    }

    /// Written whole, atomically (a new file renamed over the old one).
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// "Area n": the smallest n no area is called yet.
    public func defaultName() -> String {
        let taken = Set(areas.map(\.name))
        var n = 1
        while taken.contains("Area \(n)") { n += 1 }
        return "Area \(n)"
    }
}

/// An append-only log of tile ids (8 bytes each, little-endian): the tiles a
/// download found absent (404, blank), so a resumed download skips them. A
/// torn last record is dropped on open.
public final class TileIDLog {
    public let url: URL
    public private(set) var ids: Set<UInt64> = []
    private var handle: FileHandle?

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url) {
            let whole = data.count / 8 * 8
            var r = ByteReader(data.prefix(whole))
            while r.at + 8 <= data.startIndex + whole { ids.insert(r.u64()) }
            if whole != data.count, let h = FileHandle(forWritingAtPath: url.path(percentEncoded: false)) {
                try? h.truncate(atOffset: UInt64(whole))
                try? h.close()
            }
        } else {
            fm.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        _ = try handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    public var count: Int { ids.count }
    public func contains(_ tile: TileID) -> Bool { ids.contains(PMTiles.tileID(z: tile.z, x: tile.x, y: tile.y)) }

    public func append(_ tile: TileID) throws {
        let id = PMTiles.tileID(z: tile.z, x: tile.x, y: tile.y)
        guard ids.insert(id).inserted else { return }
        var d = Data(capacity: 8)
        d.appendLE(id)
        try handle?.write(contentsOf: d)
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }
}

/// What a tile body is, checked before it may enter an area archive.
public enum TileImage {
    /// JPEG or PNG by magic bytes: an HTML error page or a captive portal's
    /// login page must never be stored as a tile.
    public static func isImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(8))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        return b.count == 8 && b == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    /// The `code` of an ArcGIS error body: LIST's tile service answers some
    /// misses with HTTP 200 and `{"error":{"code":404,"message":…}}` instead
    /// of a 404. nil for anything else (small JSON bodies only).
    public static func arcGISErrorCode(_ data: Data) -> Int? {
        guard data.count <= 4096, data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) == UInt8(ascii: "{"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return nil }
        if let code = error["code"] as? Int { return code }
        if let code = error["code"] as? String { return Int(code) }
        return nil
    }

    public static func isPNG(_ data: Data) -> Bool {
        data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
    }

    /// Small PNGs only are decoded: LIST's "no imagery here" tiles are fully
    /// transparent 256 px PNGs of under 1 KB (876 and 889 bytes seen); a
    /// tile with any picture in it is far larger than this.
    public static let blankCheckLimit = 4096

    /// A fully transparent PNG (LIST's season services answer it where a
    /// season has no photo). JPEGs and larger PNGs are never blank here.
    public static func isBlank(_ data: Data) -> Bool {
        guard isPNG(data), data.count <= blankCheckLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 1024, h <= 1024 else { return false }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        var i = 3
        while i < pixels.count {
            if pixels[i] != 0 { return false }
            i += 4
        }
        return true
    }
}
