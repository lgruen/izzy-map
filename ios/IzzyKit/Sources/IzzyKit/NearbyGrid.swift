import Foundation

/// The "recorded near here" grid (nearby.bin, format NBY1, little-endian):
/// magic "1YBN" as uint32 0x4E425931, n, n sorted uint32 cell ids
/// (row · nlon + col), n + 1 uint32 offsets into the pairs, then
/// (uint16 species index, uint16 sites) pairs.
public struct NearbyGrid: Sendable {
    static let magic: UInt32 = 0x4E42_5931
    /// Cell ids, strictly increasing.
    let cells: [UInt32]
    /// Pair ranges: cell i owns pairs offsets[i] ..< offsets[i + 1].
    let offsets: [UInt32]
    let species: [UInt16]
    let sites: [UInt16]

    /// Number of non-empty cells.
    public var cellCount: Int { cells.count }

    /// Parses and validates the grid (magic, lengths, sorted cells, monotone offsets).
    public init(data: Data) throws {
        func bad(_ why: String) -> DataError { .malformed(file: BundledData.File.nearby, reason: why) }
        let words: [UInt32] = data.withUnsafeBytes { raw in
            (0 ..< raw.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)) }
        }
        guard words.count >= 2, words[0] == NearbyGrid.magic else { throw bad("bad magic") }
        let n = Int(words[1])
        let pairsAt = 2 + n + (n + 1)  // in words
        guard words.count >= pairsAt else { throw bad("truncated") }
        let cells = Array(words[2 ..< 2 + n])
        let offsets = Array(words[2 + n ..< pairsAt])
        let npairs = Int(offsets[n])
        guard words.count >= pairsAt + npairs else { throw bad("truncated") }
        for i in 0 ..< n {
            if i > 0, cells[i] <= cells[i - 1] { throw bad("cell ids not sorted at \(i)") }
            if offsets[i] > offsets[i + 1] { throw bad("offsets decrease at \(i)") }
        }
        let pairs = words[pairsAt ..< pairsAt + npairs]
        self.cells = cells
        self.offsets = offsets
        species = pairs.map { UInt16(truncatingIfNeeded: $0) }
        sites = pairs.map { UInt16(truncatingIfNeeded: $0 >> 16) }
    }

    /// Species index → summed sites over the 3 × 3 cells around the point.
    /// Cell centres sit on multiples of `step`, so the window always reaches
    /// at least one step (≈ 0.8 km E–W, 1.1 km N–S) past the point, at most
    /// 1.5 steps. The centre cell is the nearest one (a point exactly halfway
    /// goes to the larger index — the web app's rule; below the grid's origin,
    /// where it differs, every cell is off the grid anyway). A non-finite or
    /// far-off point is simply off the grid: an empty result, never a trap.
    public func sitesAround(latitude: Double, longitude: Double, grid: RecordsFile.Grid) -> [Int: Int] {
        var out: [Int: Int] = [:]
        // a window cell needs an id ≤ UInt32.max, so anything past that range
        // (and NaN, ±∞) can't touch a stored cell
        let limit = Double(UInt32.max)
        let rowValue = ((latitude - grid.lat0) / grid.step).rounded(.toNearestOrAwayFromZero)
        let colValue = ((longitude - grid.lon0) / grid.step).rounded(.toNearestOrAwayFromZero)
        guard (-1 ... limit).contains(rowValue), (-1 ... limit).contains(colValue) else { return out }
        let row = Int(rowValue), col = Int(colValue)
        for dr in -1 ... 1 {
            for dc in -1 ... 1 {
                let r = row + dr, c = col + dc
                if r < 0 || c < 0 || c >= grid.nlon { continue }
                let id = r * grid.nlon + c
                guard id <= Int(UInt32.max), let i = index(of: UInt32(id)) else { continue }
                for k in Int(offsets[i]) ..< Int(offsets[i + 1]) {
                    out[Int(species[k]), default: 0] += Int(sites[k])
                }
            }
        }
        return out
    }

    /// Every cell recording species `index`, in cell-id order (south to
    /// north, west to east). A linear pass over the pairs (~510k): cheap
    /// enough per plant sheet, run off the main thread.
    public func cells(ofSpecies index: Int, grid: RecordsFile.Grid) -> [RecordCell] {
        guard let target = UInt16(exactly: index), grid.nlon > 0 else { return [] }
        var out: [RecordCell] = []
        for i in 0 ..< cells.count {
            for k in Int(offsets[i]) ..< Int(offsets[i + 1]) where species[k] == target {
                let id = Int(cells[i])
                out.append(RecordCell(latitude: grid.lat0 + Double(id / grid.nlon) * grid.step,
                                      longitude: grid.lon0 + Double(id % grid.nlon) * grid.step,
                                      sites: Int(sites[k])))
                break
            }
        }
        return out
    }

    private func index(of cell: UInt32) -> Int? {
        var lo = 0, hi = cells.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = cells[mid]
            if v == cell { return mid }
            if v < cell { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }
}

/// One ~1 km grid cell with records of a species: its centre and the
/// number of ~100 m sites recorded in it.
public struct RecordCell: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var sites: Int
}
