import Foundation
import zlib

/// PMTiles v3 (https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md):
/// shared types, the Hilbert tile id, directory and header coding, gzip.
/// `PMTilesReader` reads archives (the statewide packs: season captions,
/// existence probes); `PMTilesWriter` builds them (detailed areas).
public enum PMTiles {
    /// Header byte 99.
    public enum TileType: UInt8, Sendable {
        case unknown = 0, mvt = 1, png = 2, jpeg = 3, webp = 4, avif = 5, mlt = 6
    }

    /// Header bytes 97 (internal) and 98 (tiles).
    public enum Compression: UInt8, Sendable {
        case unknown = 0, none = 1, gzip = 2, brotli = 3, zstd = 4
    }

    /// The fixed 127-byte header.
    public static let headerLength = 127
    /// The header plus the root directory must fit in the first 16 KiB.
    public static let rootLimit = 16_384

    /// Highest zoom whose tile ids fit a UInt64 (ids reach (4^(z+1) − 1) / 3).
    public static let maxZoom = 31

    // MARK: Hilbert tile id

    /// One past the last z31 tile id: (4^32 − 1) / 3.
    static let tileIDLimit = UInt64.max / 3

    /// Tile id = number of tiles on all lower zooms + the tile's Hilbert index on its zoom.
    /// x is the column, y the row from the top (XYZ, as MapLibre and LIST's z/y/x paths use).
    public static func tileID(z: Int, x: Int, y: Int) -> UInt64 {
        precondition((0 ... maxZoom).contains(z), "zoom \(z) outside 0…31")
        precondition(x >= 0 && y >= 0 && x < (1 << z) && y < (1 << z), "tile \(z)/\(x)/\(y) outside its zoom")
        var acc: UInt64 = ((1 << (2 * UInt64(z))) - 1) / 3
        var x = UInt64(x), y = UInt64(y)
        var s = UInt64(1) << UInt64(max(z - 1, 0))
        while z > 0 && s > 0 {
            let rx: UInt64 = (x & s) != 0 ? 1 : 0
            let ry: UInt64 = (y & s) != 0 ? 1 : 0
            acc += s * s * ((3 * rx) ^ ry)
            rotate(n: s, x: &x, y: &y, rx: rx, ry: ry)
            s >>= 1
        }
        return acc
    }

    /// Inverse of `tileID(z:x:y:)`.
    public static func zxy(tileID id: UInt64) -> (z: Int, x: Int, y: Int) {
        // z = largest z with (4^z − 1) / 3 ≤ id, i.e. ⌊log4(3·id + 1)⌋
        var z = 0
        while z < maxZoom, ((1 << (2 * UInt64(z + 1))) - 1) / 3 <= id { z += 1 }
        var t = id - ((1 << (2 * UInt64(z))) - 1) / 3
        var x: UInt64 = 0, y: UInt64 = 0
        var s: UInt64 = 1
        while s < (UInt64(1) << UInt64(z)) {
            let rx = 1 & (t >> 1)
            let ry = 1 & (t ^ rx)
            rotate(n: s, x: &x, y: &y, rx: rx, ry: ry)
            x += s * rx
            y += s * ry
            t >>= 2
            s <<= 1
        }
        return (z, Int(x), Int(y))
    }

    private static func rotate(n: UInt64, x: inout UInt64, y: inout UInt64, rx: UInt64, ry: UInt64) {
        guard ry == 0 else { return }
        if rx == 1 {
            // wrapping, as the reference (Go uint32) does: x still carries the
            // higher bits already consumed; only the bits below n matter from here
            x = n &- 1 &- x
            y = n &- 1 &- y
        }
        swap(&x, &y)
    }

    /// A lon/lat box in degrees.
    public struct Bounds: Sendable, Equatable {
        public var west, south, east, north: Double
        public init(west: Double, south: Double, east: Double, north: Double) {
            self.west = west; self.south = south; self.east = east; self.north = north
        }

        /// The Web Mercator extent of one XYZ tile.
        public init(tileZ z: Int, x: Int, y: Int) {
            let n = Double(1 << z)
            func lat(_ row: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(row) / n))) * 180 / .pi }
            self.init(west: Double(x) / n * 360 - 180, south: lat(y + 1), east: Double(x + 1) / n * 360 - 180, north: lat(y))
        }

        public func union(_ o: Bounds) -> Bounds {
            Bounds(west: min(west, o.west), south: min(south, o.south), east: max(east, o.east), north: max(north, o.north))
        }
    }

    // MARK: Header

    /// Header fields (spec §3). Positions are degrees (stored as E7 integers).
    public struct Header: Sendable, Equatable {
        public var rootOffset: UInt64 = 0, rootLength: UInt64 = 0
        public var metadataOffset: UInt64 = 0, metadataLength: UInt64 = 0
        public var leafDirectoryOffset: UInt64 = 0, leafDirectoryLength: UInt64 = 0
        public var tileDataOffset: UInt64 = 0, tileDataLength: UInt64 = 0
        /// Tiles before run-length encoding.
        public var addressedTiles: UInt64 = 0
        /// Directory entries with run length > 0.
        public var tileEntries: UInt64 = 0
        /// Distinct blobs in the tile data section.
        public var tileContents: UInt64 = 0
        public var clustered = false
        public var internalCompression = Compression.gzip
        public var tileCompression = Compression.none
        public var tileType = TileType.unknown
        public var minZoom = 0, maxZoom = 0
        public var minLongitude = 0.0, minLatitude = 0.0, maxLongitude = 0.0, maxLatitude = 0.0
        public var centerZoom = 0
        public var centerLongitude = 0.0, centerLatitude = 0.0

        public init() {}

        public var bounds: Bounds {
            get { Bounds(west: minLongitude, south: minLatitude, east: maxLongitude, north: maxLatitude) }
            set {
                minLongitude = newValue.west; minLatitude = newValue.south
                maxLongitude = newValue.east; maxLatitude = newValue.north
            }
        }

        init(parsing d: Data) throws(PMTilesError) {
            guard d.count >= PMTiles.headerLength else { throw .malformed("file shorter than the 127-byte header") }
            guard d.prefix(7).elementsEqual("PMTiles".utf8) else { throw .notPMTiles }
            let version = d[d.startIndex + 7]
            guard version == 3 else { throw .unsupportedVersion(Int(version)) }
            var r = ByteReader(d)
            r.skip(8)
            rootOffset = r.u64(); rootLength = r.u64()
            metadataOffset = r.u64(); metadataLength = r.u64()
            leafDirectoryOffset = r.u64(); leafDirectoryLength = r.u64()
            tileDataOffset = r.u64(); tileDataLength = r.u64()
            addressedTiles = r.u64(); tileEntries = r.u64(); tileContents = r.u64()
            clustered = r.u8() == 1
            let ic = r.u8(), tc = r.u8(), tt = r.u8()
            internalCompression = Compression(rawValue: ic) ?? .unknown
            tileCompression = Compression(rawValue: tc) ?? .unknown
            tileType = TileType(rawValue: tt) ?? .unknown
            minZoom = Int(r.u8()); maxZoom = Int(r.u8())
            minLongitude = r.e7(); minLatitude = r.e7()
            maxLongitude = r.e7(); maxLatitude = r.e7()
            centerZoom = Int(r.u8())
            centerLongitude = r.e7(); centerLatitude = r.e7()
        }

        var serialized: Data {
            var w = Data("PMTiles".utf8)
            w.reserveCapacity(PMTiles.headerLength)
            w.append(3)
            for v in [rootOffset, rootLength, metadataOffset, metadataLength, leafDirectoryOffset,
                      leafDirectoryLength, tileDataOffset, tileDataLength, addressedTiles, tileEntries, tileContents] {
                w.appendLE(v)
            }
            w.append(clustered ? 1 : 0)
            w.append(internalCompression.rawValue)
            w.append(tileCompression.rawValue)
            w.append(tileType.rawValue)
            w.append(UInt8(minZoom)); w.append(UInt8(maxZoom))
            w.appendE7(minLongitude); w.appendE7(minLatitude)
            w.appendE7(maxLongitude); w.appendE7(maxLatitude)
            w.append(UInt8(centerZoom))
            w.appendE7(centerLongitude); w.appendE7(centerLatitude)
            assert(w.count == PMTiles.headerLength)
            return w
        }
    }

    // MARK: Directories

    /// A directory entry. runLength 0 = a leaf directory pointer (offset into the
    /// leaf section); otherwise `runLength` consecutive tile ids share one blob
    /// (offset into the tile data section).
    struct Entry: Sendable, Equatable {
        var tileID: UInt64
        var offset: UInt64
        var length: UInt32
        var runLength: UInt32
    }

    /// Spec §4.2: count, delta tile ids, run lengths, lengths, offsets
    /// (0 = "right after the previous entry", else offset + 1), each a varint.
    static func encodeDirectory(_ entries: [Entry]) -> Data {
        var b = Data()
        b.reserveCapacity(entries.count * 6 + 8)
        b.appendVarint(UInt64(entries.count))
        var last: UInt64 = 0
        for e in entries {
            b.appendVarint(e.tileID - last)
            last = e.tileID
        }
        for e in entries { b.appendVarint(UInt64(e.runLength)) }
        for e in entries { b.appendVarint(UInt64(e.length)) }
        var next: UInt64 = 0
        for (i, e) in entries.enumerated() {
            b.appendVarint(i > 0 && e.offset == next ? 0 : e.offset + 1)
            next = e.offset + UInt64(e.length)
        }
        return b
    }

    static func decodeDirectory(_ d: Data) throws(PMTilesError) -> [Entry] {
        var r = ByteReader(d)
        let n = try r.varint()
        // every entry takes ≥ 4 bytes, so a count beyond that is corruption, not a huge alloc
        guard n <= UInt64(d.count) / 4 else { throw .malformed("directory claims \(n) entries in \(d.count) bytes") }
        let count = Int(n)
        var entries = [Entry](repeating: Entry(tileID: 0, offset: 0, length: 0, runLength: 0), count: count)
        var last: UInt64 = 0
        for i in 0 ..< count {
            let (sum, overflow) = last.addingReportingOverflow(try r.varint())
            guard !overflow, i == 0 || sum > last else { throw .malformed("directory tile ids not increasing") }
            last = sum
            entries[i].tileID = sum
        }
        for i in 0 ..< count {
            let v = try r.varint()
            guard v <= UInt32.max else { throw .malformed("run length too large") }
            entries[i].runLength = UInt32(v)
        }
        for i in 0 ..< count {
            let v = try r.varint()
            guard v > 0, v <= UInt32.max else { throw .malformed("entry length \(v)") }
            entries[i].length = UInt32(v)
        }
        for i in 0 ..< count {
            let v = try r.varint()
            if v == 0, i > 0 {
                let (next, overflow) = entries[i - 1].offset.addingReportingOverflow(UInt64(entries[i - 1].length))
                guard !overflow else { throw .malformed("entry offset overflows") }
                entries[i].offset = next
            } else {
                guard v > 0 else { throw .malformed("first entry has a relative offset") }
                entries[i].offset = v - 1
            }
        }
        return entries
    }

    /// The entry covering `id`: an exact match, the run it falls into, or the
    /// leaf pointer whose range starts at or before it. Binary search.
    static func find(_ id: UInt64, in entries: [Entry]) -> Entry? {
        var lo = 0, hi = entries.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let t = entries[mid].tileID
            if t < id { lo = mid + 1 } else if t > id { hi = mid - 1 } else { return entries[mid] }
        }
        // hi = last entry with tileID < id
        guard hi >= 0 else { return nil }
        let e = entries[hi]
        if e.runLength == 0 || id - e.tileID < UInt64(e.runLength) { return e }
        return nil
    }

    // MARK: gzip (zlib, windowBits 15 + 16 = gzip wrapper)

    static func gzip(_ input: Data, level: Int32 = Z_BEST_COMPRESSION) throws(PMTilesError) -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15 + 16, 9, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw .compression("deflateInit2 failed") }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, uLong(input.count))) + 32)
        let status: Int32 = input.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw .compression("deflate returned \(status)") }
        out.count = Int(stream.total_out)
        return out
    }

    /// Inflates a gzip stream (concatenated members too). `limit` bounds the output.
    static func gunzip(_ input: Data, limit: Int = 256 << 20) throws(PMTilesError) -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw .compression("inflateInit2 failed") }
        defer { inflateEnd(&stream) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: max(64 << 10, min(input.count * 8, 4 << 20)))
        let result: Result<Void, PMTilesError> = input.withUnsafeBytes { src in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBytes { dst in
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(dst.count)
                    let s = inflate(&stream, Z_NO_FLUSH)
                    return (s, dst.count - Int(stream.avail_out))
                }
                out.append(contentsOf: chunk[0 ..< produced])
                if out.count > limit { return .failure(.malformed("gzip output over \(limit) bytes")) }
                switch status {
                case Z_STREAM_END:
                    // another gzip member may follow
                    if stream.avail_in == 0 { return .success(()) }
                    guard inflateReset(&stream) == Z_OK else { return .failure(.compression("inflateReset")) }
                case Z_OK:
                    if stream.avail_in == 0, produced == 0 { return .failure(.malformed("truncated gzip stream")) }
                case Z_BUF_ERROR where stream.avail_in == 0:
                    return .failure(.malformed("truncated gzip stream"))
                default:
                    return .failure(.malformed("gzip data error (\(status))"))
                }
            }
        }
        try result.get()
        return out
    }
}

/// Why an archive could not be read or written.
public enum PMTilesError: Error, Sendable, Equatable, CustomStringConvertible {
    case notPMTiles
    case unsupportedVersion(Int)
    /// Brotli/zstd/unknown internal compression — the app's packs use gzip or none.
    case unsupportedCompression(PMTiles.Compression)
    case malformed(String)
    case compression(String)
    case io(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .notPMTiles: "not a PMTiles archive (bad magic)"
        case let .unsupportedVersion(v): "PMTiles spec version \(v), only version 3 is supported"
        case let .unsupportedCompression(c): "unsupported internal compression \(c)"
        case let .malformed(why): "malformed PMTiles archive: \(why)"
        case let .compression(why): "compression error: \(why)"
        case let .io(why): "I/O error: \(why)"
        case let .invalidArgument(why): why
        }
    }
}

// MARK: - byte helpers

struct ByteReader {
    let data: Data
    var at: Int

    init(_ data: Data) { self.data = data; at = data.startIndex }

    mutating func skip(_ n: Int) { at += n }
    mutating func u8() -> UInt8 { defer { at += 1 }; return data[at] }
    mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for i in 0 ..< 4 { v |= UInt32(data[at + i]) << (8 * UInt32(i)) }
        at += 4
        return v
    }
    mutating func u64() -> UInt64 {
        var v: UInt64 = 0
        for i in 0 ..< 8 { v |= UInt64(data[at + i]) << (8 * UInt64(i)) }
        at += 8
        return v
    }
    mutating func e7() -> Double { Double(Int32(bitPattern: u32())) / 10_000_000 }

    /// Little-endian base-128 varint (protobuf), at most 10 bytes.
    mutating func varint() throws(PMTilesError) -> UInt64 {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard at < data.endIndex else { throw .malformed("directory truncated inside a varint") }
            let b = data[at]
            at += 1
            guard shift < 64, shift < 63 || b <= 1 else { throw .malformed("varint over 64 bits") }
            v |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
        }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendE7(_ degrees: Double) {
        let scaled = (degrees * 10_000_000).rounded()
        appendLE(Int32(Swift.max(Double(Int32.min), Swift.min(Double(Int32.max), scaled))))
    }

    mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        append(UInt8(v))
    }
}
