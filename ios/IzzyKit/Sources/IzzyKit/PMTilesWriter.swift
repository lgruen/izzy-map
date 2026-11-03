import CryptoKit
import Foundation

/// Builds a clustered PMTiles v3 archive from tiles added in any order —
/// the detailed-area store (LIST tiles kept VERBATIM, up to ~60,000 tiles /
/// ~1 GB per area and layer).
///
/// Memory stays small: tile bytes go straight to a work file next to the
/// destination (`<dest>.tiles`); RAM holds only tile id → blob, and per
/// distinct blob its SHA-256, offset and length (~100 bytes a tile).
/// Identical bytes (LIST's constant sea / blank tiles) are stored once.
/// A journal (`<dest>.journal`, 52 bytes a tile) lets a killed download pick
/// up where it stopped: `init(…, resume: true)`. Durability: journal records
/// are held back and written in batches of `syncEvery` tiles, each batch only
/// after an `fsync` of the tile bytes it points at — a power loss can never
/// leave a journalled tile whose bytes didn't reach the disk. On resume every
/// distinct blob is re-hashed against its journalled SHA-256; a mismatch
/// (torn page, bit rot) drops the tiles using it, to be fetched again.
///
/// `finish` sorts by Hilbert tile id, lays the blobs out in that order
/// (clustered), run-length-encodes consecutive ids sharing a blob, splits
/// root/leaf directories so the header + root fit in 16 KiB, gzips the
/// directories and metadata, writes `<dest>.partial` and renames it over
/// `dest` (atomic), then deletes the work files.
///
/// Not thread-safe: own it from one actor or task.
public final class PMTilesWriter {
    public let destination: URL
    public let tileType: PMTiles.TileType
    public let tileCompression: PMTiles.Compression

    private struct Blob { var offset: UInt64; var length: UInt32 }

    private var blobs: [Blob] = []
    private var blobByDigest: [DigestKey: Int32] = [:]
    private var journalRecords = 0
    /// Records not yet in the journal (written after the next data fsync).
    private var pendingJournal = Data()
    private var pendingRecords = 0
    /// Tiles per data fsync + journal batch.
    public let syncEvery: Int
    /// Journalled tiles dropped on resume because their bytes didn't match.
    public private(set) var droppedOnResume = 0
    private var tiles: [UInt64: Int32] = [:]
    private var dataEnd: UInt64 = 0
    private var dataFD: Int32 = -1
    private var journalFD: Int32 = -1
    private var closed = false

    var dataURL: URL { destination.appendingPathExtension("tiles") }
    var journalURL: URL { destination.appendingPathExtension("journal") }
    var partialURL: URL { destination.appendingPathExtension("partial") }

    private static let journalMagic = Data("PMTWJ1".utf8)
    private static let journalHeaderLength = 16
    private static let recordLength = 8 + 8 + 4 + 32

    /// Starts an archive at `destination` (written only by `finish`). With
    /// `resume`, an earlier writer's work files for the same destination,
    /// tile type and compression are continued (a torn last record or bytes
    /// past the last journalled tile are dropped); otherwise they are deleted.
    public init(destination: URL, tileType: PMTiles.TileType, tileCompression: PMTiles.Compression = .none,
                resume: Bool = false, syncEvery: Int = 64) throws(PMTilesError) {
        self.destination = destination
        self.syncEvery = max(1, syncEvery)
        self.tileType = tileType
        self.tileCompression = tileCompression
        let fm = FileManager.default
        if !(resume && (try? loadJournal()) == true) {
            if dataFD >= 0 { close(dataFD) }
            if journalFD >= 0 { close(journalFD) }
            try? fm.removeItem(at: dataURL)
            try? fm.removeItem(at: journalURL)
            blobs = []; blobByDigest = [:]; tiles = [:]; dataEnd = 0; journalRecords = 0; droppedOnResume = 0
            dataFD = -1; journalFD = -1
            dataFD = try Self.openForWriting(dataURL, truncate: true)
            journalFD = try Self.openForWriting(journalURL, truncate: true)
            var head = Self.journalMagic
            head.append(tileType.rawValue)
            head.append(tileCompression.rawValue)
            head.append(Data(count: Self.journalHeaderLength - head.count))
            try Self.writeAll(journalFD, head, at: 0)
        }
    }

    deinit {
        // a writer dropped without finish (a stopped download) keeps its batch
        try? sync()
        if dataFD >= 0 { close(dataFD) }
        if journalFD >= 0 { close(journalFD) }
    }

    /// Tiles added so far (a re-added tile counts once).
    public var tileCount: Int { tiles.count }
    /// Bytes in the work file so far (distinct blobs only).
    public var storedBytes: UInt64 { dataEnd }

    public func contains(z: Int, x: Int, y: Int) -> Bool {
        guard Self.valid(z, x, y) else { return false }
        return tiles[PMTiles.tileID(z: z, x: x, y: y)] != nil
    }

    /// Adds (or replaces) one tile. `data` is stored byte-for-byte.
    public func add(z: Int, x: Int, y: Int, data: Data) throws(PMTilesError) {
        guard !closed else { throw .invalidArgument("writer already finished") }
        guard Self.valid(z, x, y) else { throw .invalidArgument("tile \(z)/\(x)/\(y) outside its zoom") }
        guard !data.isEmpty, data.count <= Int(UInt32.max) else { throw .invalidArgument("tile \(z)/\(x)/\(y) has \(data.count) bytes") }
        let id = PMTiles.tileID(z: z, x: x, y: y)
        let digest = SHA256.hash(data: data)
        let key = DigestKey(digest)
        let blob: Int32
        if let known = blobByDigest[key] {
            blob = known
        } else {
            try Self.writeAll(dataFD, data, at: dataEnd)
            blob = Int32(blobs.count)
            blobs.append(Blob(offset: dataEnd, length: UInt32(data.count)))
            blobByDigest[key] = blob
            dataEnd += UInt64(data.count)
        }
        // journalled only after its bytes are synced (`sync`)
        pendingJournal.appendLE(id)
        pendingJournal.appendLE(blobs[Int(blob)].offset)
        pendingJournal.appendLE(blobs[Int(blob)].length)
        digest.withUnsafeBytes { pendingJournal.append(contentsOf: $0) }
        pendingRecords += 1
        tiles[id] = blob
        if pendingRecords >= syncEvery { try sync() }
    }

    /// Makes every tile added so far resumable: fsyncs the tile bytes, then
    /// appends their journal records (and fsyncs the journal). Called every
    /// `syncEvery` tiles, and by a download that stops.
    public func sync() throws(PMTilesError) {
        guard pendingRecords > 0, !closed, dataFD >= 0, journalFD >= 0 else { return }
        guard fsync(dataFD) == 0 else { throw .io("fsync: \(String(cString: strerror(errno)))") }
        try Self.writeAll(journalFD, pendingJournal, at: UInt64(Self.journalHeaderLength + journalRecords * Self.recordLength))
        _ = fsync(journalFD)
        journalRecords += pendingRecords
        pendingRecords = 0
        pendingJournal.removeAll(keepingCapacity: true)
    }

    /// Records in the journal file (tests: what a kill now would keep).
    public var journalledTiles: Int { journalRecords }

    /// Writes the archive and removes the work files. `name` and `attribution`
    /// go into the metadata (overriding `metadata`'s keys). Zooms come from
    /// the tiles; bounds default to the union of the tiles' extents, the
    /// centre to the bounds' middle at the lowest zoom.
    @discardableResult
    public func finish(name: String, attribution: String, metadata extra: [String: Any] = [:],
                       bounds: PMTiles.Bounds? = nil,
                       center: (longitude: Double, latitude: Double, zoom: Int)? = nil,
                       progress: ((Double) -> Void)? = nil) throws(PMTilesError) -> PMTiles.Header {
        guard !closed else { throw .invalidArgument("writer already finished") }
        guard !tiles.isEmpty else { throw .invalidArgument("no tiles added") }
        if tileType == .mvt, extra["vector_layers"] == nil {
            throw .invalidArgument("an MVT archive's metadata must carry vector_layers")
        }
        var meta = extra
        meta["name"] = name
        meta["attribution"] = attribution
        guard JSONSerialization.isValidJSONObject(meta),
              let metaJSON = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        else { throw .invalidArgument("metadata is not JSON-serialisable") }

        // clustered layout: blobs in order of their first tile id
        let ids = tiles.keys.sorted()
        var placedAt = [UInt64](repeating: .max, count: blobs.count)
        var order: [Int32] = []
        order.reserveCapacity(blobs.count)
        var cursor: UInt64 = 0
        var entries: [PMTiles.Entry] = []
        var minZ = Int.max, maxZ = 0
        var box: PMTiles.Bounds?
        for id in ids {
            let b = tiles[id]!
            if placedAt[Int(b)] == .max {
                placedAt[Int(b)] = cursor
                order.append(b)
                cursor += UInt64(blobs[Int(b)].length)
            }
            let offset = placedAt[Int(b)]
            if let last = entries.last, last.offset == offset, last.tileID + UInt64(last.runLength) == id,
               last.runLength < UInt32.max {
                entries[entries.count - 1].runLength += 1
            } else {
                entries.append(PMTiles.Entry(tileID: id, offset: offset, length: blobs[Int(b)].length, runLength: 1))
            }
            let (z, x, y) = PMTiles.zxy(tileID: id)
            minZ = min(minZ, z); maxZ = max(maxZ, z)
            if bounds == nil {
                let t = PMTiles.Bounds(tileZ: z, x: x, y: y)
                box = box.map { $0.union(t) } ?? t
            }
        }

        let (root, leaves) = try Self.buildDirectories(entries)
        let metaGz = try PMTiles.gzip(metaJSON)

        var h = PMTiles.Header()
        h.rootOffset = UInt64(PMTiles.headerLength)
        h.rootLength = UInt64(root.count)
        h.metadataOffset = h.rootOffset + h.rootLength
        h.metadataLength = UInt64(metaGz.count)
        h.leafDirectoryOffset = h.metadataOffset + h.metadataLength
        h.leafDirectoryLength = UInt64(leaves.count)
        h.tileDataOffset = h.leafDirectoryOffset + h.leafDirectoryLength
        h.tileDataLength = cursor
        h.addressedTiles = UInt64(ids.count)
        h.tileEntries = UInt64(entries.count)
        h.tileContents = UInt64(order.count)
        h.clustered = true
        h.internalCompression = .gzip
        h.tileCompression = tileCompression
        h.tileType = tileType
        h.minZoom = minZ
        h.maxZoom = maxZ
        let b = bounds ?? box!
        h.bounds = b
        let c = center ?? ((b.west + b.east) / 2, (b.south + b.north) / 2, minZ)
        h.centerLongitude = c.longitude
        h.centerLatitude = c.latitude
        h.centerZoom = c.zoom

        let fm = FileManager.default
        try? fm.removeItem(at: partialURL)
        let out = try Self.openForWriting(partialURL, truncate: true)
        do throws(PMTilesError) {
            var sink = Sink(fd: out)
            try sink.write(h.serialized)
            try sink.write(root)
            try sink.write(metaGz)
            try sink.write(leaves)
            var buffer = Data()
            var copied: UInt64 = 0
            var reported: UInt64 = 0
            let step = max(cursor / 50, 1)
            for b in order {
                let blob = blobs[Int(b)]
                buffer.count = Int(blob.length)
                try Self.readAll(dataFD, into: &buffer, at: blob.offset)
                try sink.write(buffer)
                copied += UInt64(blob.length)
                if let progress, copied - reported >= step {
                    reported = copied
                    progress(Double(copied) / Double(max(cursor, 1)))
                }
            }
            try sink.flush()
            guard sink.written == h.tileDataOffset + h.tileDataLength else { throw .io("archive size mismatch") }
            guard fsync(out) == 0 else { throw .io("fsync: \(String(cString: strerror(errno)))") }
            close(out)
        } catch {
            close(out)
            try? fm.removeItem(at: partialURL)
            throw error
        }
        guard rename(partialURL.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0
        else { throw .io("rename: \(String(cString: strerror(errno)))") }
        discardWorkFiles()
        progress?(1)
        // as stored: positions round to E7
        return try PMTiles.Header(parsing: h.serialized)
    }

    /// Stops without writing an archive and deletes the work files.
    public func cancel() { discardWorkFiles() }

    private func discardWorkFiles() {
        closed = true
        pendingJournal = Data()
        pendingRecords = 0
        if dataFD >= 0 { close(dataFD); dataFD = -1 }
        if journalFD >= 0 { close(journalFD); journalFD = -1 }
        let fm = FileManager.default
        try? fm.removeItem(at: dataURL)
        try? fm.removeItem(at: journalURL)
        try? fm.removeItem(at: partialURL)
    }

    // MARK: Directories

    /// Root-only when it fits; else leaves of ≥ 4096 entries (the Go
    /// reference's rule), grown by 20 % until the root fits.
    static func buildDirectories(_ entries: [PMTiles.Entry]) throws(PMTilesError) -> (root: Data, leaves: Data) {
        let rootMax = PMTiles.rootLimit - PMTiles.headerLength
        if entries.count < 16_384 {
            let root = try PMTiles.gzip(PMTiles.encodeDirectory(entries))
            if root.count <= rootMax { return (root, Data()) }
        }
        var leafSize = max(4096, entries.count / 3500)
        while true {
            var rootEntries: [PMTiles.Entry] = []
            var leaves = Data()
            var i = 0
            while i < entries.count {
                let end = min(i + leafSize, entries.count)
                let leaf = try PMTiles.gzip(PMTiles.encodeDirectory(Array(entries[i ..< end])))
                rootEntries.append(PMTiles.Entry(tileID: entries[i].tileID, offset: UInt64(leaves.count),
                                                 length: UInt32(leaf.count), runLength: 0))
                leaves.append(leaf)
                i = end
            }
            let root = try PMTiles.gzip(PMTiles.encodeDirectory(rootEntries))
            if root.count <= rootMax { return (root, leaves) }
            leafSize += leafSize / 5
        }
    }

    // MARK: Journal

    /// Rebuilds the in-memory index from the work files; false if absent or for another archive kind.
    private func loadJournal() throws(PMTilesError) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalURL.path(percentEncoded: false)),
              fm.fileExists(atPath: dataURL.path(percentEncoded: false)),
              let journal = try? Data(contentsOf: journalURL, options: .uncached),
              journal.count >= Self.journalHeaderLength,
              journal.prefix(Self.journalMagic.count) == Self.journalMagic,
              journal[journal.startIndex + 6] == tileType.rawValue,
              journal[journal.startIndex + 7] == tileCompression.rawValue,
              let attrs = try? fm.attributesOfItem(atPath: dataURL.path(percentEncoded: false)),
              let dataSize = (attrs[.size] as? NSNumber)?.uint64Value
        else { return false }
        var r = ByteReader(journal)
        r.skip(Self.journalHeaderLength)
        // the valid records, in order (a bad one ends the journal: torn tail)
        var parsed: [(id: UInt64, offset: UInt64, length: UInt32, digest: Data)] = []
        while r.at + Self.recordLength <= journal.endIndex {
            let id = r.u64(), offset = r.u64(), length = r.u32()
            let digestBytes = Data(journal[r.at ..< r.at + 32])
            r.skip(32)
            guard length > 0, offset + UInt64(length) <= dataSize, id < PMTiles.tileIDLimit
            else { break }
            parsed.append((id, offset, length, digestBytes))
        }
        dataFD = try Self.openForWriting(dataURL, truncate: false)
        // every distinct blob re-hashed: bytes that don't match their digest
        // (never synced, or damaged) drop every tile using them
        var verified: [DigestKey: Bool] = [:]
        var buffer = Data()
        var kept = Data()
        var records = 0
        for rec in parsed {
            let key = DigestKey(rec.digest)
            if verified[key] == nil {
                buffer.count = Int(rec.length)
                let ok: Bool
                if (try? Self.readAll(dataFD, into: &buffer, at: rec.offset)) != nil {
                    ok = DigestKey(SHA256.hash(data: buffer)) == key
                } else {
                    ok = false
                }
                verified[key] = ok
                if ok {
                    blobByDigest[key] = Int32(blobs.count)
                    blobs.append(Blob(offset: rec.offset, length: rec.length))
                    dataEnd = max(dataEnd, rec.offset + UInt64(rec.length))
                }
            }
            guard verified[key] == true, let blob = blobByDigest[key] else {
                droppedOnResume += 1
                continue
            }
            tiles[rec.id] = blob
            kept.appendLE(rec.id)
            kept.appendLE(blobs[Int(blob)].offset)
            kept.appendLE(blobs[Int(blob)].length)
            kept.append(rec.digest)
            records += 1
        }
        journalFD = try Self.openForWriting(journalURL, truncate: false)
        // the journal keeps only verified records (rewritten when any went)
        if droppedOnResume > 0 { try Self.writeAll(journalFD, kept, at: UInt64(Self.journalHeaderLength)) }
        guard ftruncate(dataFD, off_t(dataEnd)) == 0,
              ftruncate(journalFD, off_t(Self.journalHeaderLength + records * Self.recordLength)) == 0
        else { throw .io("ftruncate: \(String(cString: strerror(errno)))") }
        journalRecords = records
        return true
    }

    /// A SHA-256 as four words (cheap to hash, 32 bytes a blob).
    private struct DigestKey: Hashable {
        var a: UInt64, b: UInt64, c: UInt64, d: UInt64
        init<Bytes: Sequence<UInt8>>(_ bytes: Bytes) {
            var w = [UInt64](repeating: 0, count: 4)
            for (i, byte) in bytes.enumerated() where i < 32 { w[i / 8] |= UInt64(byte) << (8 * UInt64(i % 8)) }
            a = w[0]; b = w[1]; c = w[2]; d = w[3]
        }
        init(_ digest: SHA256.Digest) { self.init(Array(digest)) }
    }

    // MARK: I/O

    private static func valid(_ z: Int, _ x: Int, _ y: Int) -> Bool {
        (0 ... PMTiles.maxZoom).contains(z) && x >= 0 && y >= 0 && x < (1 << z) && y < (1 << z)
    }

    private static func openForWriting(_ url: URL, truncate: Bool) throws(PMTilesError) -> Int32 {
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC | (truncate ? O_TRUNC : 0), 0o644)
        guard fd >= 0 else { throw .io("open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data, at offset: UInt64) throws(PMTilesError) {
        let failure: PMTilesError? = data.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return .io("write: \(String(cString: strerror(errno)))")
                }
                done += n
            }
            return nil
        }
        if let failure { throw failure }
    }

    private static func readAll(_ fd: Int32, into buffer: inout Data, at offset: UInt64) throws(PMTilesError) {
        let count = buffer.count
        let failure: PMTilesError? = buffer.withUnsafeMutableBytes { buf in
            var done = 0
            while done < count {
                let n = pread(fd, buf.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return .io("read: \(String(cString: strerror(errno)))")
                }
                if n == 0 { return .io("work file truncated") }
                done += n
            }
            return nil
        }
        if let failure { throw failure }
    }

    /// Sequential buffered output (4 MiB).
    private struct Sink {
        let fd: Int32
        var buffer = Data()
        var written: UInt64 = 0

        init(fd: Int32) { self.fd = fd; buffer.reserveCapacity(4 << 20) }

        mutating func write(_ d: Data) throws(PMTilesError) {
            buffer.append(d)
            if buffer.count >= 4 << 20 { try flush() }
        }

        mutating func flush() throws(PMTilesError) {
            guard !buffer.isEmpty else { return }
            try PMTilesWriter.writeAll(fd, buffer, at: written)
            written += UInt64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }
    }
}
