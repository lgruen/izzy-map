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

// MARK: - Core distribution

extension CommunityPresence.Grid {
    /// A rectangle of whole cells (inclusive ranges; rows run south).
    public struct CellBox: Sendable, Hashable {
        public var columns: ClosedRange<Int>
        public var rows: ClosedRange<Int>
        public init(columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
            self.columns = columns
            self.rows = rows
        }
        public func contains(_ index: Int, columnsPerRow: Int) -> Bool {
            columns.contains(index % columnsPerRow) && rows.contains(index / columnsPerRow)
        }
    }

    /// The box's outer edges, [west, south, east, north] in degrees.
    public func bounds(of box: CellBox) -> [Double] {
        [lon0 + Double(box.columns.lowerBound) * lonStep,
         lat0 - Double(box.rows.upperBound + 1) * latStep,
         lon0 + Double(box.columns.upperBound + 1) * lonStep,
         lat0 - Double(box.rows.lowerBound) * latStep]
    }

    /// A level's typical share of its cell: the middle of its band
    /// (levels 0–5 %, 5–25 %, 25–50 %, 50–100 % → 2.5, 15, 37.5, 75 %).
    /// Weighting cells by it turns where.bin into an area estimate.
    public func share(ofLevel level: Int) -> Double {
        let lows = levelsPermille
        guard level >= 1, level <= lows.count else { return 0 }
        let low = Double(lows[level - 1])
        let high = level < lows.count ? Double(lows[level]) : 1000
        return (low + high) / 2000
    }

    /// The community's CORE distribution: of all whole-cell boxes holding at
    /// least `fraction` of its area (cells weighted by `share(ofLevel:)`),
    /// one a view of width / height `aspect` shows closest-in — the least
    /// max(width, height × aspect) — shrunk to the cells inside it. A few
    /// outlying patches (an islet, one stand 200 km away) no longer decide
    /// the zoom; they are still drawn, just framed out.
    ///
    /// The grid's cells are square in Web Mercator (0.02° × 0.015° at
    /// 41.5° S), so cell counts compare directly with screen points. The
    /// largest box of a given fit holds the most area, so feasibility is
    /// monotone in the fit: a binary search over the candidate fits, each
    /// tested with a summed-area table over the community's own bounding
    /// box (O((columns + rows) log) × columns × rows, ~1 ms for DOB).
    public func coreBox(_ cells: [CommunityPresence.Cell], fraction: Double = 0.9, aspect: Double = 1) -> CellBox? {
        guard !cells.isEmpty, fraction > 0, aspect > 0 else { return nil }
        let cs = cells.map { $0.index % columns }, rs = cells.map { $0.index / columns }
        let c0 = cs.min()!, r0 = rs.min()!
        let nc = cs.max()! - c0 + 1, nr = rs.max()! - r0 + 1
        // summed-area table: sat[(r) * (nc + 1) + c] = weight of rows < r, columns < c
        let stride = nc + 1
        var sat = [Double](repeating: 0, count: (nr + 1) * stride)
        var total = 0.0
        for (i, cell) in cells.enumerated() {
            // an unknown level still counts as a trace
            let w = max(share(ofLevel: cell.level), 0.001)
            sat[(rs[i] - r0 + 1) * stride + (cs[i] - c0 + 1)] += w
            total += w
        }
        for r in 1 ... nr {
            for c in 1 ... nc {
                sat[r * stride + c] += sat[(r - 1) * stride + c] + sat[r * stride + c - 1] - sat[(r - 1) * stride + c - 1]
            }
        }
        let target = fraction * total * (1 - 1e-9)
        /// The heaviest window of the largest size with this fit, if it holds the target.
        func window(fit: Double) -> (col: Int, row: Int, w: Int, h: Int)? {
            let w = min(nc, max(1, Int((fit + 1e-9).rounded(.down))))
            let h = min(nr, max(1, Int((fit / aspect + 1e-9).rounded(.down))))
            var best: (col: Int, row: Int, sum: Double)?
            for r in 0 ... nr - h {
                for c in 0 ... nc - w {
                    let sum = sat[(r + h) * stride + c + w] - sat[r * stride + c + w] - sat[(r + h) * stride + c] + sat[r * stride + c]
                    if sum >= target, sum > (best?.sum ?? -1) { best = (c, r, sum) }
                }
            }
            return best.map { ($0.col, $0.row, w, h) }
        }
        // candidate fits: every whole width, every whole height × aspect
        let candidates = Array(Set((1 ... nc).map(Double.init) + (1 ... nr).map { Double($0) * aspect })).sorted()
        var lo = 0, hi = candidates.count - 1
        guard var found = window(fit: max(candidates[hi], Double(nc), Double(nr) * aspect)) else { return nil }
        while lo < hi {
            let mid = (lo + hi) / 2
            if let w = window(fit: candidates[mid]) {
                found = w
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        if let w = window(fit: candidates[lo]) { found = w }
        // shrink to the cells inside the window
        let inside = cells.indices.filter {
            (found.col ..< found.col + found.w).contains(cs[$0] - c0) && (found.row ..< found.row + found.h).contains(rs[$0] - r0)
        }
        let ic = inside.map { cs[$0] }, ir = inside.map { rs[$0] }
        return CellBox(columns: ic.min()! ... ic.max()!, rows: ir.min()! ... ir.max()!)
    }
}

// MARK: - Dissolved regions

extension CommunityPresence.Grid {
    /// The union of the cells `indices` as polygons — adjacent cells
    /// dissolved into one shape, so a map draws ONE casing around a region
    /// instead of a keyline per cell. Each polygon is [exterior, holes…],
    /// rings of [lon, lat] closed on their first point, exterior
    /// counter-clockwise and holes clockwise (RFC 7946), straight runs
    /// merged to their corners. Cells touching only at a corner stay
    /// separate polygons (the tracer turns left at a pinch).
    public func regions(_ indices: Set<Int>) -> [[[[Double]]]] {
        guard !indices.isEmpty else { return [] }
        // Lattice vertices (x = column, y = −row: north up). Each cell's
        // boundary edges, counter-clockwise; a side shared with another
        // cell of the set is not a boundary.
        struct V: Hashable { var x: Int, y: Int }
        func has(_ c: Int, _ r: Int) -> Bool { c >= 0 && c < columns && r >= 0 && indices.contains(r * columns + c) }
        var out: [V: [V]] = [:]
        func edge(_ a: V, _ b: V) { out[a, default: []].append(b) }
        for i in indices {
            let c = i % columns, r = i / columns
            let sw = V(x: c, y: -(r + 1)), se = V(x: c + 1, y: -(r + 1)), ne = V(x: c + 1, y: -r), nw = V(x: c, y: -r)
            if !has(c, r + 1) { edge(sw, se) }
            if !has(c + 1, r) { edge(se, ne) }
            if !has(c, r - 1) { edge(ne, nw) }
            if !has(c - 1, r) { edge(nw, sw) }
        }
        // trace rings: interior on the left; at a pinch prefer left, then
        // straight, then right
        var rings: [[V]] = []
        let starts = out.keys.sorted { ($0.y, $0.x) > ($1.y, $1.x) }
        for start in starts {
            while let first = out[start]?.first {
                out[start]!.removeFirst()
                var ring = [start]
                var from = start, at = first
                while at != start {
                    ring.append(at)
                    let d = (at.x - from.x, at.y - from.y)
                    let prefs = [(-d.1, d.0), d, (d.1, -d.0)]
                    guard var options = out[at], !options.isEmpty else { break }
                    let pick = prefs.lazy.compactMap { p in options.firstIndex { $0 == V(x: at.x + p.0, y: at.y + p.1) } }.first ?? 0
                    let next = options.remove(at: pick)
                    out[at] = options
                    from = at
                    at = next
                }
                // merge straight runs to their corners
                var corners: [V] = []
                let n = ring.count
                for k in 0 ..< n {
                    let a = ring[(k + n - 1) % n], b = ring[k], c = ring[(k + 1) % n]
                    if (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) != 0 { corners.append(b) }
                }
                if corners.count >= 4 { rings.append(corners) }
            }
        }
        func area2(_ ring: [V]) -> Int {
            var a = 0
            for k in ring.indices {
                let p = ring[k], q = ring[(k + 1) % ring.count]
                a += p.x * q.y - q.x * p.y
            }
            return a
        }
        /// Even-odd test of a point (in half units: never on a lattice line).
        func contains(_ ring: [V], _ px: Double, _ py: Double) -> Bool {
            var inside = false
            for k in ring.indices {
                let a = ring[k], b = ring[(k + 1) % ring.count]
                let (ax, ay, bx, by) = (Double(a.x), Double(a.y), Double(b.x), Double(b.y))
                if (ay > py) != (by > py), px < ax + (py - ay) / (by - ay) * (bx - ax) { inside.toggle() }
            }
            return inside
        }
        var polygons: [(outer: [V], holes: [[V]], box: (Int, Int, Int, Int))] = []
        var holes: [[V]] = []
        for ring in rings {
            if area2(ring) > 0 {
                let xs = ring.map(\.x), ys = ring.map(\.y)
                polygons.append((ring, [], (xs.min()!, ys.min()!, xs.max()!, ys.max()!)))
            } else {
                holes.append(ring)
            }
        }
        for hole in holes {
            // a point just inside the filled side of the hole's first edge
            let a = hole[0], b = hole[1]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), len = (dx * dx + dy * dy).squareRoot()
            let px = Double(a.x) + dx / len * 0.5 - dy / len * 0.25, py = Double(a.y) + dy / len * 0.5 + dx / len * 0.25
            // the smallest exterior around it (exteriors can nest inside holes)
            var best: Int?
            for (k, p) in polygons.enumerated() {
                let bx = p.box
                guard px > Double(bx.0), px < Double(bx.2), py > Double(bx.1), py < Double(bx.3), contains(p.outer, px, py) else { continue }
                if best == nil || area2(p.outer) < area2(polygons[best!].outer) { best = k }
            }
            if let best { polygons[best].holes.append(hole) }
        }
        func degrees(_ ring: [V]) -> [[Double]] {
            let pts = ring.map { [lon0 + Double($0.x) * lonStep, lat0 + Double($0.y) * latStep] }
            return pts + [pts[0]]
        }
        return polygons.map { [degrees($0.outer)] + $0.holes.map(degrees) }
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
