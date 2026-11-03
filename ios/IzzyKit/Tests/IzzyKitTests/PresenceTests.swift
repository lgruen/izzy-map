import Foundation
import Testing
@testable import IzzyKit

@Suite struct PresenceTests {
    /// A where.bin by the format in pipeline/build_where.py's header.
    static func whereBin(columns: Int, rows: Int, communities: [(String, [(skip: Int, count: Int, level: UInt8)])],
                         land: [(skip: Int, count: Int, level: UInt8)]) -> Data {
        func varint(_ v: Int) -> [UInt8] {
            var v = v, out: [UInt8] = []
            repeat {
                var b = UInt8(v & 0x7F); v >>= 7
                if v > 0 { b |= 0x80 }
                out.append(b)
            } while v > 0
            return out
        }
        func stream(_ runs: [(skip: Int, count: Int, level: UInt8)]) -> [UInt8] {
            runs.flatMap { varint($0.skip) + varint($0.count) + [$0.level] }
        }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let streams = communities.map { stream($0.1) }
        let landStream = stream(land)
        var offset = 64 + 16 * communities.count
        var table: [UInt8] = []
        for (i, c) in communities.enumerated() {
            var code = Array(c.0.utf8)
            code += [UInt8](repeating: 0, count: 4 - code.count)
            table += code + le(UInt32(offset)) + le(UInt32(streams[i].count)) + le(UInt32(c.1.reduce(0) { $0 + $1.count }))
            offset += streams[i].count
        }
        let landOffset = offset
        let size = landOffset + landStream.count
        var head: [UInt8] = Array("WHR1".utf8) + le(UInt16(1)) + le(UInt16(communities.count))
        head += le(UInt16(columns)) + le(UInt16(rows))
        head += le(Int32(143_800_000)) + le(Int32(-39_180_000)) + le(Int32(20_000)) + le(Int32(15_000))
        head += [4, 0] + le(UInt16(0)) + le(UInt16(50)) + le(UInt16(250)) + le(UInt16(500)) + le(UInt16(0))
        head += le(UInt32(landOffset)) + le(UInt32(landStream.count)) + le(UInt32(land.reduce(0) { $0 + $1.count }))
        head += le(UInt32(size)) + [UInt8](repeating: 0, count: 8)
        precondition(head.count == 64)
        return Data(head + table + streams.flatMap { $0 } + landStream)
    }

    @Test func decodesRunsAndGrid() throws {
        let data = Self.whereBin(columns: 10, rows: 5,
                                 communities: [("AAP", [(2, 3, 4), (200, 1, 1)]), ("DOB", [(0, 1, 2)])],
                                 land: [(0, 50, 4)])
        let p = try CommunityPresence(data: data)
        #expect(p.codes == ["AAP", "DOB"])
        #expect(p.cells("AAP").map(\.index) == [2, 3, 4, 205].filter { $0 < 50 })  // the far run overflows: dropped
        #expect(p.cells("DOB") == [.init(index: 0, level: 2)])
        #expect(p.cells("NOPE").isEmpty)
        #expect(p.landCells().count == 50)
        #expect(p.grid.levelsPermille == [0, 50, 250, 500])
        let c = p.grid.centre(11)  // row 1, col 1
        #expect(abs(c.latitude - (-39.18 - 1.5 * 0.015)) < 1e-9)
        #expect(abs(c.longitude - (143.8 + 1.5 * 0.02)) < 1e-9)
    }

    @Test func refusesBadFiles() {
        #expect(throws: DataError.self) { try CommunityPresence(data: Data("WHR2".utf8 + [UInt8](repeating: 0, count: 80))) }
        var good = Self.whereBin(columns: 4, rows: 4, communities: [("AAP", [(0, 1, 1)])], land: [])
        good.removeLast()
        #expect(throws: DataError.self) { try CommunityPresence(data: good) }
    }

    @Test func bundledFilesWhenPresent() throws {
        let outline = try TestData.data.tasmaniaOutline()
        #expect(outline.rings.count >= 3)
        #expect(outline.rings.allSatisfy { $0.allSatisfy { (143.5 ... 149).contains($0[0]) && (-44 ... -39.2).contains($0[1]) } })
        // where.bin arrives from pipeline/build_where.py; until then the card hides the mini-map
        let p = try #require(try TestData.data.communityPresence())
        #expect(p.codes.count == 156)
        #expect(p.codes == (try TestData.data.communities()).keys.sorted())
        #expect(!p.cells("DOB").isEmpty)
        for code in p.codes { #expect(p.cells(code).count == p.cellCount(code), "\(code)") }
        // King Island eucalypt woodland: all on King Island, west of 144.2° E
        let dkw = p.cells("DKW")
        #expect(dkw.count == 142)
        #expect(dkw.allSatisfy { p.grid.centre($0.index).longitude < 144.2 })
        // the land stream has King Island and the Furneaux Group
        let land = p.landCells().map { p.grid.centre($0.index) }
        #expect(land.contains { $0.longitude < 144.2 && (-40.2 ... -39.5).contains($0.latitude) })
        #expect(land.contains { $0.longitude > 147.8 && (-40.3 ... -39.6).contains($0.latitude) })
        #expect(land.allSatisfy { (143.8 ... 148.52).contains($0.longitude) && (-43.68 ... -39.18).contains($0.latitude) })
        // the outline frames them too
        #expect(outline.bbox[0] < 144.0 && outline.bbox[2] > 148.2 && outline.bbox[3] > -39.7)
        let patches = try #require(try TestData.data.communityPatches())
        #expect(patches.communities.count == 156)
        #expect(patches.communities["DKW"]?.top.first.map { $0.p[0] < 144.2 } == true)
    }

    // MARK: Core distribution ("Show on map" frames it)

    @Test func coreBoxDropsAnOutlierAndHonoursTheAspect() throws {
        // 10 × 10 grid: a 3 × 2 block of full cells top-left, one trace far away
        var runs: [(skip: Int, count: Int, level: UInt8)] = [(11, 3, 4), (7, 3, 4)]
        runs.append((88 - 24, 1, 1))  // cell 88 (row 8, col 8)
        let p = try CommunityPresence(data: Self.whereBin(columns: 10, rows: 10, communities: [("AAP", runs)], land: []))
        let cells = p.cells("AAP")
        #expect(cells.count == 7)
        let box = try #require(p.grid.coreBox(cells))
        #expect(box == .init(columns: 1 ... 3, rows: 1 ... 2))
        // all of it: the outlier is in
        let all = try #require(p.grid.coreBox(cells, fraction: 1))
        #expect(all == .init(columns: 1 ... 8, rows: 1 ... 8))
        // a box's degrees: outer cell edges
        let b = p.grid.bounds(of: box)
        #expect(abs(b[0] - (143.8 + 0.02)) < 1e-9 && abs(b[2] - (143.8 + 0.08)) < 1e-9)
        #expect(abs(b[3] - (-39.18 - 0.015)) < 1e-9 && abs(b[1] - (-39.18 - 0.045)) < 1e-9)
        #expect(p.grid.share(ofLevel: 1) == 0.025 && p.grid.share(ofLevel: 4) == 0.75)
        #expect(p.grid.coreBox([]) == nil)
    }

    @Test func coreBoxPrefersTheViewsShape() throws {
        // two equal blocks: one wide (6 × 1), one tall (1 × 6); 50 % = either
        let wide: [(skip: Int, count: Int, level: UInt8)] = [(0, 6, 4)]
        var tall = wide
        for r in 2 ..< 8 { tall.append((r == 2 ? 20 - 6 + 9 : 9, 1, 4)) }
        let p = try CommunityPresence(data: Self.whereBin(columns: 10, rows: 10, communities: [("AAP", tall)], land: []))
        let cells = p.cells("AAP")
        #expect(cells.count == 12)
        // a tall (portrait) view shows the tall block closer in, a wide one the wide block
        let portrait = try #require(p.grid.coreBox(cells, fraction: 0.5, aspect: 0.5))
        #expect(portrait.columns.count == 1 && portrait.rows.count == 6)
        let landscape = try #require(p.grid.coreBox(cells, fraction: 0.5, aspect: 2))
        #expect(landscape.columns.count == 6 && landscape.rows.count == 1)
    }

    /// Real data: DAM (E. amygdalina forest on mudstone — Leo's TestFlight
    /// case: the union of all patches spans nearly the state), DOB (the most
    /// widespread eucalypt forest), DMO (3 tiny patches near Hobart).
    @Test func coreBoxesOnRealCommunities() throws {
        let p = try #require(try TestData.data.communityPresence())
        let g = p.grid
        func weight(_ cells: [CommunityPresence.Cell], in box: CommunityPresence.Grid.CellBox?) -> Double {
            cells.filter { box?.contains($0.index, columnsPerRow: g.columns) ?? true }
                .reduce(0) { $0 + g.share(ofLevel: $1.level) }
        }
        func span(_ cells: [CommunityPresence.Cell]) -> (cols: Int, rows: Int) {
            let c = cells.map { $0.index % g.columns }, r = cells.map { $0.index / g.columns }
            return (c.max()! - c.min()! + 1, r.max()! - r.min()! + 1)
        }
        for code in ["DAM", "DOB", "DMO"] {
            let cells = p.cells(code)
            let box = try #require(g.coreBox(cells), "\(code)")
            #expect(weight(cells, in: box) >= 0.9 * weight(cells, in: nil) - 1e-9, "\(code)")
            let full = span(cells)
            #expect(box.columns.count <= full.cols && box.rows.count <= full.rows, "\(code)")
            let b = g.bounds(of: box)
            #expect(b[0] >= 143.5 && b[2] <= 149 && b[1] >= -44 && b[3] <= -39.18, "\(code)")
        }
        // DAM: eastern Tasmania, not the whole state — the full extent is
        // 111 × 169 cells (~280 km tall); the core is markedly shorter and
        // its centre in the east (Midlands / East Coast)
        let dam = try #require(g.coreBox(p.cells("DAM")))
        #expect(dam.rows.count < 120, "\(dam)")
        let damB = g.bounds(of: dam)
        #expect((damB[0] + damB[2]) / 2 > 146.8)
        // a portrait view takes a taller, narrower core than a landscape one
        let damTall = try #require(g.coreBox(p.cells("DAM"), aspect: 0.6))
        #expect(damTall.columns.count <= dam.columns.count)
        // DOB is everywhere in the east and north: its core stays big
        let dob = try #require(g.coreBox(p.cells("DOB")))
        #expect(dob.columns.count > 100)
        // DMO: three trace cells around Hobart — 90 % of three equal cells
        // needs all three
        let dmoCells = p.cells("DMO")
        #expect(dmoCells.count == 3)
        let dmo = try #require(g.coreBox(dmoCells))
        #expect(dmoCells.allSatisfy { dmo.contains($0.index, columnsPerRow: g.columns) })
        let dmoB = g.bounds(of: dmo)
        #expect(dmoB[0] > 147.2 && dmoB[2] < 147.7 && dmoB[1] > -43.1 && dmoB[3] < -42.7)
    }

    // MARK: Dissolved regions (one casing per region, not per cell)

    @Test func regionsDissolveCellsKeepHolesAndSplitAtPinches() throws {
        let g = CommunityPresence.Grid(columns: 10, rows: 10, lon0: 0, lat0: 0, lonStep: 1, latStep: 1, levelsPermille: [0])
        func idx(_ c: Int, _ r: Int) -> Int { r * 10 + c }
        func signedArea(_ ring: [[Double]]) -> Double {
            zip(ring, ring.dropFirst()).reduce(0) { $0 + ($1.0[0] * $1.1[1] - $1.1[0] * $1.0[1]) } / 2
        }
        // a 3 × 3 ring with a hole in the middle
        var ring = Set<Int>()
        for c in 0 ..< 3 { for r in 0 ..< 3 where !(c == 1 && r == 1) { ring.insert(idx(c, r)) } }
        let a = g.regions(ring)
        #expect(a.count == 1 && a[0].count == 2)
        #expect(signedArea(a[0][0]) == 9 && signedArea(a[0][1]) == -1)  // CCW exterior, CW hole
        #expect(a[0][0].count == 5)  // straight runs merged: four corners + closing point
        #expect(a[0][0].first == a[0][0].last)
        // two cells touching at a corner: two polygons
        let pinch = g.regions([idx(5, 5), idx(6, 6)])
        #expect(pinch.count == 2 && pinch.allSatisfy { $0.count == 1 && signedArea($0[0]) == 1 })
        // an L of three cells: one polygon of six corners, area 3
        let l = g.regions([idx(0, 8), idx(0, 9), idx(1, 9)])
        #expect(l.count == 1 && l[0][0].count == 7 && signedArea(l[0][0]) == 3)
        #expect(g.regions([]).isEmpty)
    }

    @Test func regionsCoverExactlyTheCellsOfARealCommunity() throws {
        let p = try #require(try TestData.data.communityPresence())
        for code in ["DOB", "DAM", "DMO"] {
            let cells = Set(p.cells(code).filter { $0.level >= 2 }.map(\.index))
            let polygons = p.grid.regions(cells)
            func area(_ r: [[Double]]) -> Double {
                zip(r, r.dropFirst()).reduce(0) { $0 + ($1.0[0] * $1.1[1] - $1.1[0] * $1.0[1]) } / 2
            }
            let total = polygons.reduce(0.0) { sum, poly in sum + poly.map(area).reduce(0, +) }
            let cellArea = p.grid.lonStep * p.grid.latStep
            #expect(abs(total / cellArea - Double(cells.count)) < 1e-6, "\(code)")
            #expect(polygons.allSatisfy { area($0[0]) > 0 && $0.dropFirst().allSatisfy { area($0) < 0 } })
        }
    }
}
