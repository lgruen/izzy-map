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
}
