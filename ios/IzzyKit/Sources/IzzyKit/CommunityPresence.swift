import Foundation

/// Where each TASVEG community occurs statewide — the "Where else does
/// this grow?" mini-map (where.bin, built by pipeline/build_where.py; the
/// format is documented in that script's header). Cells are 0.02° lon ×
/// 0.015° lat (~1.7 km square), each with an area-share level 1…4.
public struct CommunityPresence: Sendable {
    public static let fileName = "where.bin"
    static let magic = Array("WHR1".utf8)

    public struct Grid: Sendable, Hashable {
        public var columns: Int, rows: Int
        /// West edge of column 0 and NORTH edge of row 0, degrees.
        public var lon0: Double, lat0: Double
        public var lonStep: Double, latStep: Double
        /// Lower bounds of the levels, ‰ of the cell's area.
        public var levelsPermille: [Int]

        /// The cell's centre.
        public func centre(_ index: Int) -> (latitude: Double, longitude: Double) {
            let row = index / columns, col = index % columns
            return (lat0 - (Double(row) + 0.5) * latStep, lon0 + (Double(col) + 0.5) * lonStep)
        }
    }

    /// One cell a community covers.
    public struct Cell: Sendable, Hashable {
        public var index: Int
        /// 1 = a trace (< 5 %), 2 = 5–25 %, 3 = 25–50 %, 4 = ≥ 50 % of the cell.
        public var level: Int
    }

    public let grid: Grid
    /// code → (offset, length, cell count) into `data`
    let table: [String: (offset: Int, length: Int, count: Int)]
    let land: (offset: Int, length: Int)
    let data: Data

    public var codes: [String] { table.keys.sorted() }

    public init(data: Data) throws {
        func bad(_ why: String) -> DataError { .malformed(file: Self.fileName, reason: why) }
        let bytes = [UInt8](data)
        guard bytes.count >= 64, Array(bytes[0 ..< 4]) == Self.magic else { throw bad("bad magic") }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func i32(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(u32(o)))) }
        let version = u16(4)
        guard version == 1 else {
            throw DataError.unsupportedVersion(file: Self.fileName, found: version, supported: 1)
        }
        let ncomm = u16(6)
        let nlevels = Int(bytes[28])
        guard nlevels <= 4 else { throw bad("levels") }
        grid = Grid(columns: u16(8), rows: u16(10),
                    lon0: Double(i32(12)) / 1e6, lat0: Double(i32(16)) / 1e6,
                    lonStep: Double(i32(20)) / 1e6, latStep: Double(i32(24)) / 1e6,
                    levelsPermille: (0 ..< nlevels).map { u16(30 + 2 * $0) })
        guard grid.columns > 0, grid.rows > 0, grid.lonStep > 0, grid.latStep > 0 else { throw bad("grid") }
        guard u32(52) == bytes.count else { throw bad("truncated") }
        land = (u32(40), u32(44))
        guard 64 + 16 * ncomm <= bytes.count, land.offset + land.length <= bytes.count else { throw bad("truncated") }
        var table: [String: (Int, Int, Int)] = [:]
        for i in 0 ..< ncomm {
            let o = 64 + 16 * i
            let code = String(decoding: bytes[o ..< o + 4].prefix { $0 != 0 }, as: UTF8.self)
            let entry = (u32(o + 4), u32(o + 8), u32(o + 12))
            guard entry.0 + entry.1 <= bytes.count else { throw bad("stream of \(code) out of range") }
            table[code] = entry
        }
        self.table = table
        self.data = data
    }

    /// The community's cells (empty for an unknown code).
    public func cells(_ code: String) -> [Cell] {
        guard let e = table[code] else { return [] }
        return decode(offset: e.offset, length: e.length)
    }

    /// Cells holding any land (level ≥ 1) — the silhouette.
    public func landCells() -> [Cell] { decode(offset: land.offset, length: land.length) }

    /// Number of cells a community covers (from the table, no decoding).
    public func cellCount(_ code: String) -> Int { table[code]?.count ?? 0 }

    /// Runs of (varint skip, varint count, u8 level) — unsigned LEB128.
    func decode(offset: Int, length: Int) -> [Cell] {
        var out: [Cell] = []
        let limit = grid.columns * grid.rows
        data.withUnsafeBytes { raw in
            var p = offset
            let end = offset + length
            func varint() -> Int? {
                var v = 0, shift = 0
                while p < end, shift < 35 {
                    let b = Int(raw[p]); p += 1
                    v |= (b & 0x7F) << shift
                    if b & 0x80 == 0 { return v }
                    shift += 7
                }
                return nil
            }
            var cursor = 0
            while p < end {
                guard let skip = varint(), let count = varint(), p < end else { return }
                let level = Int(raw[p]); p += 1
                cursor += skip
                guard count >= 1, cursor + count <= limit else { return }
                for i in cursor ..< cursor + count { out.append(Cell(index: i, level: level)) }
                cursor += count
            }
        }
        return out
    }
}

/// where_patches.json: per community, its total area, patch count and
/// largest patches (for "Show on map" / stepping through patches).
public struct CommunityPatches: Decodable, Sendable {
    public static let fileName = "where_patches.json"
    public struct Patch: Decodable, Sendable, Hashable {
        public var ha: Double
        /// Label point [lon, lat].
        public var p: [Double]
        /// [west, south, east, north]
        public var bbox: [Double]
    }
    public struct Community: Decodable, Sendable, Hashable {
        public var ha: Double
        public var patches: Int
        public var top: [Patch]
    }
    public var version: Int
    public var communities: [String: Community]
}

extension BundledData {
    /// where.bin, or nil while the pipeline hasn't produced it.
    public func communityPresence() throws -> CommunityPresence? {
        let url = root.appending(path: CommunityPresence.fileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try CommunityPresence(data: data(CommunityPresence.fileName))
    }

    public func communityPatches() throws -> CommunityPatches? {
        let url = root.appending(path: CommunityPatches.fileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try decode(CommunityPatches.fileName)
    }

    /// tasmania_outline.json — the silhouette under every mini-map.
    public func tasmaniaOutline() throws -> TasmaniaOutline { try decode(TasmaniaOutline.fileName) }
}

/// A simplified Tasmania coastline (pipeline/build_outline.py; LIST
/// Locality and Postcode Areas, CC BY 3.0 AU): rings of [lon, lat].
public struct TasmaniaOutline: Decodable, Sendable {
    public static let fileName = "tasmania_outline.json"
    public var version: Int
    /// [west, south, east, north]
    public var bbox: [Double]
    public var rings: [[[Double]]]
}
