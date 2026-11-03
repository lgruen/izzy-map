import Foundation
import Synchronization

/// Random access into a local PMTiles v3 archive, safe to share across threads.
///
/// Reads with `pread` on one file descriptor (no shared file position, so no
/// lock around I/O) instead of memory-mapping: seven season packs plus the
/// multi-GB topo/Tasmap/aerial packs would eat the app's virtual address
/// space on an iPhone. Opening reads the header and the root directory
/// (≤ 16 KiB); a lookup is a binary search in the root, plus — for large
/// archives — one leaf directory, decoded once and kept in a small LRU.
/// Nothing ever reads the whole file.
public final class PMTilesReader: Sendable {
    public let url: URL
    public let header: PMTiles.Header
    private let fd: Int32
    /// File size at open: every read is checked against it, so a corrupt
    /// offset or length is `.malformed`, never a trap or a huge allocation.
    private let fileSize: UInt64
    private let root: [PMTiles.Entry]
    private let leaves: Mutex<LeafCache>

    /// Leaf directories kept decoded (a statewide z15 pack has a few dozen).
    public static let defaultLeafCacheSize = 64

    public init(url: URL, leafCacheSize: Int = PMTilesReader.defaultLeafCacheSize) throws(PMTilesError) {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .io("open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else {
            close(fd)
            throw .io("stat \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        let fileSize = UInt64(info.st_size)
        do throws(PMTilesError) {
            let head = try Self.read(fd, offset: 0, count: PMTiles.headerLength, fileSize: fileSize)
            let header = try PMTiles.Header(parsing: head)
            guard header.internalCompression == .gzip || header.internalCompression == .none
            else { throw .unsupportedCompression(header.internalCompression) }
            let rootBytes = try Self.read(fd, offset: header.rootOffset, count: Int(clamping: header.rootLength), fileSize: fileSize)
            root = try PMTiles.decodeDirectory(Self.decompress(rootBytes, header.internalCompression))
            self.header = header
        } catch {
            close(fd)
            throw error
        }
        self.url = url
        self.fd = fd
        self.fileSize = fileSize
        leaves = Mutex(LeafCache(capacity: max(1, leafCacheSize)))
    }

    deinit { close(fd) }

    // MARK: Header conveniences

    public var minZoom: Int { header.minZoom }
    public var maxZoom: Int { header.maxZoom }
    public var tileType: PMTiles.TileType { header.tileType }
    public var bounds: PMTiles.Bounds { header.bounds }
    public var center: (longitude: Double, latitude: Double, zoom: Int) {
        (header.centerLongitude, header.centerLatitude, header.centerZoom)
    }

    // MARK: Tiles

    /// Whether the archive holds this tile. Costs no tile-data I/O; at most one
    /// leaf directory read per cache miss.
    public func tileExists(z: Int, x: Int, y: Int) throws(PMTilesError) -> Bool {
        try entry(z: z, x: x, y: y) != nil
    }

    /// The tile's bytes exactly as stored (still `header.tileCompression`-encoded,
    /// e.g. gzipped MVT), or nil when the archive has no such tile.
    public func tileData(z: Int, x: Int, y: Int) throws(PMTilesError) -> Data? {
        guard let e = try entry(z: z, x: x, y: y) else { return nil }
        let (start, overflow) = header.tileDataOffset.addingReportingOverflow(e.offset)
        guard !overflow, header.tileDataLength == 0
            || (e.offset <= header.tileDataLength && UInt64(e.length) <= header.tileDataLength - e.offset)
        else { throw .malformed("tile entry outside the tile data section") }
        return try Self.read(fd, offset: start, count: Int(e.length), limit: Int(UInt32.max), fileSize: fileSize)
    }

    /// The metadata JSON (decompressed UTF-8 bytes).
    public func metadataJSON() throws(PMTilesError) -> Data {
        guard header.metadataLength > 0 else { return Data("{}".utf8) }
        let raw = try Self.read(fd, offset: header.metadataOffset, count: Int(clamping: header.metadataLength), fileSize: fileSize)
        return try Self.decompress(raw, header.internalCompression)
    }

    /// The metadata as a JSON object (`name`, `attribution`, …).
    public func metadata() throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: metadataJSON()) as? [String: Any]
        else { throw PMTilesError.malformed("metadata is not a JSON object") }
        return obj
    }

    /// The directory entry covering z/x/y, or nil. Out-of-range tiles are simply absent.
    func entry(z: Int, x: Int, y: Int) throws(PMTilesError) -> PMTiles.Entry? {
        guard (0 ... PMTiles.maxZoom).contains(z), x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        let id = PMTiles.tileID(z: z, x: x, y: y)
        var dir = root
        // the spec allows leaves of leaves; real writers use one level
        for _ in 0 ..< 4 {
            guard let e = PMTiles.find(id, in: dir) else { return nil }
            if e.runLength > 0 { return e }
            dir = try leaf(at: e.offset, length: e.length)
        }
        throw .malformed("leaf directories nested deeper than 4")
    }

    private func leaf(at offset: UInt64, length: UInt32) throws(PMTilesError) -> [PMTiles.Entry] {
        if let hit = leaves.withLock({ $0.get(offset) }) { return hit }
        // decoded outside the lock; two threads missing the same leaf both decode it (harmless)
        let (start, overflow) = header.leafDirectoryOffset.addingReportingOverflow(offset)
        guard !overflow else { throw .malformed("leaf directory offset out of range") }
        let raw = try Self.read(fd, offset: start, count: Int(length), fileSize: fileSize)
        let entries = try PMTiles.decodeDirectory(Self.decompress(raw, header.internalCompression))
        leaves.withLock { $0.put(offset, entries) }
        return entries
    }

    // MARK: I/O

    /// Directories and metadata above this are corruption, not data (a real leaf is ≤ ~1 MB).
    static let sectionLimit = 64 << 20

    /// Reads exactly `count` bytes at `offset`. Everything about the request
    /// is checked before any allocation: a range past the end of the file
    /// (truncation, a corrupt offset or length) is `.malformed`.
    private static func read(_ fd: Int32, offset: UInt64, count: Int, limit: Int = PMTilesReader.sectionLimit,
                             fileSize: UInt64) throws(PMTilesError) -> Data {
        guard count > 0 else { return Data() }
        guard count <= limit else { throw .malformed("\(count)-byte read, over the \(limit)-byte limit") }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= fileSize, end <= UInt64(Int64.max)
        else { throw .malformed("\(count)-byte read at \(offset) past the end of the \(fileSize)-byte file") }
        var data = Data(count: count)
        var done = 0
        let failure: PMTilesError? = data.withUnsafeMutableBytes { buf in
            while done < count {
                let n = pread(fd, buf.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return .io("pread: \(String(cString: strerror(errno)))")
                }
                if n == 0 { return .malformed("file truncated (wanted \(count) bytes at \(offset))") }
                done += n
            }
            return nil
        }
        if let failure { throw failure }
        return data
    }

    static func decompress(_ data: Data, _ c: PMTiles.Compression) throws(PMTilesError) -> Data {
        switch c {
        case .none: data
        case .gzip: try PMTiles.gunzip(data)
        default: throw .unsupportedCompression(c)
        }
    }
}

/// A tiny LRU keyed by leaf offset (a recency counter; capacity is small, so
/// eviction's linear scan is cheaper than a linked list).
struct LeafCache {
    let capacity: Int
    private var items: [UInt64: (entries: [PMTiles.Entry], used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ key: UInt64) -> [PMTiles.Entry]? {
        guard let hit = items[key] else { return nil }
        clock += 1
        items[key]?.used = clock
        return hit.entries
    }

    mutating func put(_ key: UInt64, _ entries: [PMTiles.Entry]) {
        clock += 1
        if items[key] == nil, items.count >= capacity,
           let oldest = items.min(by: { $0.value.used < $1.value.used })?.key {
            items[oldest] = nil
        }
        items[key] = (entries, clock)
    }

    var count: Int { items.count }
}
