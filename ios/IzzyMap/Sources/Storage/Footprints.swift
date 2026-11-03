import Foundation
import IzzyKit
import Observation
import SwiftUI

/// Where an on-demand pack has tiles: one bit per z11 tile (~19 km) over
/// Tasmania. Bundled for every pack (pipeline/build_footprints.py: tile
/// existence in the built archives), re-read on the device from an
/// installed pack's own PMTiles directory with the same grid — the 2025–26
/// season grows after the build.
nonisolated struct Footprint: Equatable, Sendable {
    let grid: Grid
    /// Row-major, LSB first.
    let bits: Data

    nonisolated struct Grid: Equatable, Sendable, Decodable {
        let zoom: Int
        let x0: Int
        let y0: Int
        let cols: Int
        let rows: Int

        /// The cell's corners in degrees (Web Mercator tile → lon/lat).
        func bounds(col: Int, row: Int) -> (west: Double, south: Double, east: Double, north: Double) {
            let n = Double(1 << zoom)
            func lon(_ x: Int) -> Double { Double(x) / n * 360 - 180 }
            func lat(_ y: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi }
            return (lon(x0 + col), lat(y0 + row + 1), lon(x0 + col + 1), lat(y0 + row))
        }
    }

    func contains(col: Int, row: Int) -> Bool {
        guard (0 ..< grid.cols).contains(col), (0 ..< grid.rows).contains(row) else { return false }
        let i = row * grid.cols + col
        return i >> 3 < bits.count && bits[bits.startIndex + i >> 3] & (1 << UInt8(i & 7)) != 0
    }

    var count: Int { bits.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Cells any of `list` has (all on one grid; nil for an empty list).
    static func union(_ list: [Footprint]) -> Footprint? {
        guard let first = list.first else { return nil }
        var bits = first.bits
        for f in list.dropFirst() where f.grid == first.grid && f.bits.count == bits.count {
            for i in bits.indices { bits[i] |= f.bits[f.bits.startIndex + (i - bits.startIndex)] }
        }
        return Footprint(grid: first.grid, bits: bits)
    }

    /// Reads the cells' tile existence from a local archive (off the main
    /// thread: ~1,000 directory lookups).
    static func read(_ url: URL, grid: Grid) -> Footprint? {
        guard let reader = try? PMTilesReader(url: url) else { return nil }
        var bits = Data(count: (grid.cols * grid.rows + 7) / 8)
        for row in 0 ..< grid.rows {
            for col in 0 ..< grid.cols where (try? reader.tileExists(z: grid.zoom, x: grid.x0 + col, y: grid.y0 + row)) == true {
                let i = row * grid.cols + col
                bits[i >> 3] |= 1 << UInt8(i & 7)
            }
        }
        return Footprint(grid: grid, bits: bits)
    }
}

/// The bundled table (`pack_footprints.json`).
nonisolated struct BundledFootprints: Decodable, Sendable {
    static let fileName = "pack_footprints.json"
    let version: Int
    let zoom: Int, x0: Int, y0: Int, cols: Int, rows: Int
    let packs: [String: String]

    var grid: Footprint.Grid { Footprint.Grid(zoom: zoom, x0: x0, y0: y0, cols: cols, rows: rows) }

    func footprint(_ pack: Pack) -> Footprint? {
        packs[pack.rawValue].flatMap { Data(base64Encoded: $0) }.map { Footprint(grid: grid, bits: $0) }
    }

    static func load(_ data: BundledData? = BundledData.inBundle()) -> BundledFootprints? {
        guard let url = data?.root.appending(path: fileName), let bytes = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(BundledFootprints.self, from: bytes), table.version == 1 else { return nil }
        return table
    }
}

/// The footprints the Storage screen draws: bundled until a pack is on the
/// device, then read from the pack itself (once per file).
@MainActor @Observable
final class FootprintStore {
    static let shared = FootprintStore()

    private(set) var local: [Pack: Footprint] = [:]
    @ObservationIgnored private(set) lazy var bundled: BundledFootprints? = BundledFootprints.load()
    @ObservationIgnored private lazy var outlineCache: TasmaniaOutline? = try? BundledData.inBundle()?.tasmaniaOutline()
    @ObservationIgnored private var readFrom: [Pack: URL] = [:]

    var outline: TasmaniaOutline? { outlineCache }

    func footprint(_ pack: Pack) -> Footprint? { local[pack] ?? bundled?.footprint(pack) }

    /// Re-reads installed packs whose file changed; forgets removed ones.
    func update(_ location: DataLocation) async {
        guard let grid = bundled?.grid else { return }
        for pack in Pack.allCases where pack.storageSection != .maps {
            guard let archive = pack.archives.first, let url = location.url(for: archive) else {
                local[pack] = nil
                readFrom[pack] = nil
                continue
            }
            guard readFrom[pack] != url else { continue }
            readFrom[pack] = url
            let found = await Self.read(url, grid: grid)
            if readFrom[pack] == url { local[pack] = found }
        }
    }

    @concurrent nonisolated private static func read(_ url: URL, grid: Footprint.Grid) async -> Footprint? {
        Footprint.read(url, grid: grid)
    }
}

/// A pack's coverage as a printed plate (the mini-maps' idiom, DESIGN.md
/// "Mini-maps"): Tasmania in paper with a fine grey coast; where the pack
/// has tiles, ink — full ink on the device, a quiet grey before. Light in
/// both appearances: printed matter.
struct CoverageThumbnail: View {
    let outline: TasmaniaOutline?
    let footprint: Footprint?
    /// On the device (full ink) or not yet (grey).
    var installed: Bool
    /// While downloading: the plate fills with ink from the bottom up.
    var progress: Double?
    /// Drawn first, in grey: what else could come (the all-seasons row).
    var under: Footprint?

    var body: some View {
        Canvas { ctx, size in
            guard let outline else { return }
            let b = (w: 143.79, s: -43.69, e: 148.53, n: -39.53)
            let xs = TasmaniaMiniMap.xScale
            let k = min(size.width / ((b.e - b.w) * xs), size.height / (b.n - b.s))
            let ox = (size.width - (b.e - b.w) * xs * k) / 2, oy = (size.height - (b.n - b.s) * k) / 2
            func pt(_ lon: Double, _ lat: Double) -> CGPoint { CGPoint(x: ox + (lon - b.w) * xs * k, y: oy + (b.n - lat) * k) }
            var land = Path()
            for ring in outline.rings {
                guard let first = ring.first else { continue }
                land.move(to: pt(first[0], first[1]))
                for p in ring.dropFirst() { land.addLine(to: pt(p[0], p[1])) }
                land.closeSubpath()
            }
            ctx.fill(land, with: .color(TasmaniaMiniMap.paper))
            func cells(_ footprint: Footprint) -> Path {
                var cells = Path()
                let grid = footprint.grid
                for row in 0 ..< grid.rows {
                    for col in 0 ..< grid.cols where footprint.contains(col: col, row: row) {
                        let c = grid.bounds(col: col, row: row)
                        let a = pt(c.west, c.north), z = pt(c.east, c.south)
                        cells.addRect(CGRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y).insetBy(dx: -0.15, dy: -0.15))
                    }
                }
                return cells
            }
            var clipped = ctx
            clipped.clip(to: land)
            // the mini-maps' ink steps: full for what's here, the lightest
            // for what could come
            let here = TasmaniaMiniMap.ink.opacity(TasmaniaMiniMap.presenceInk[3])
            let could = TasmaniaMiniMap.ink.opacity(TasmaniaMiniMap.presenceInk[1])
            if let under { clipped.fill(cells(under), with: .color(could)) }
            if let footprint {
                let cells = cells(footprint)
                clipped.fill(cells, with: .color(installed ? here : could))
                if let progress, !installed {
                    // the download fills the coverage in ink, south to north
                    let top = size.height * (1 - min(max(progress, 0), 1))
                    clipped.clip(to: Path(CGRect(x: 0, y: top, width: size.width, height: size.height - top)))
                    clipped.fill(cells, with: .color(here))
                }
            }
            ctx.stroke(land, with: .color(TasmaniaMiniMap.coast), lineWidth: 0.5)
        }
        .padding(2)
        .background(DesignColor.keyPlate)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}
