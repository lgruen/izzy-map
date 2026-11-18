import Foundation
import Testing
@testable import IzzyKit

/// The bundled reconnaissance soils (soil_units.json + soils.pmtiles), read
/// from the app's resource folder — tripwires pinned to the 2025-07-17
/// LIST release.
@Suite struct SoilsTests {
    static let file: SoilsFile = try! TestData.data.soilUnits()

    @Test func tableShape() throws {
        let f = Self.file
        #expect(f.version == SoilsFile.supportedVersion && f.version == 1)
        #expect(f.units.count == 163)
        #expect(f.sheets.count == 11)
        #expect(f.orders.count == 13)
        #expect(f.source.polygons == 2_468)
        #expect(f.units.values.reduce(0) { $0 + $1.polygons } == f.source.polygons)
        #expect(f.source.licence == "CC BY 3.0 AU")
        #expect(f.source.attribution.contains("State of Tasmania"))
        for (code, unit) in f.units {
            #expect(!unit.sheets.isEmpty, "\(code)")
            for sheet in unit.sheets { #expect(f.sheets[sheet] != nil, "\(code): sheet \(sheet)") }
            for order in unit.orders { #expect(f.orders[order] != nil, "\(code): order \(order)") }
            #expect(MapColour.components(unit.color) != nil, "\(code): colour \(unit.color)")
            #expect(unit.polygons >= 1 && unit.ha > 0, "\(code)")
            // codes are map labels: inside the shipped glyph range
            #expect(MapText.isLatin1(code), "\(code)")
        }
        // 34 units the source leaves unclassified, 70 without a profile class
        #expect(f.units.values.filter(\.orders.isEmpty).count == 34)
        #expect(f.units.values.filter { $0.profile == nil }.count == 70)
        for sheet in f.sheets.values {
            #expect(sheet.url.scheme == "https" && sheet.url.pathExtension.lowercased() == "pdf", "\(sheet.name)")
            #expect(sheet.bytes > 0)
            let b = sheet.bounds
            #expect(b.west > 143.5 && b.east < 149 && b.south > -44 && b.north < -39.5, "\(sheet.name)")
        }
        // inside a frame vs off every sheet (Cradle Mountain; Bass Strait)
        #expect(f.anySheetContains(longitude: 147.33, latitude: -42.88))  // Hobart
        #expect(f.anySheetContains(longitude: 147.30, latitude: -42.85))  // the Derwent, inside the Hobart frame
        #expect(!f.anySheetContains(longitude: 145.95, latitude: -41.68))
        #expect(!f.anySheetContains(longitude: 146.5, latitude: -40.5))
        let all = try #require(f.sheetsBounds)
        #expect(all.west < 145.6 && all.east > 147.9 && all.south < -42.9 && all.north > -40.9)
    }

    /// `BL` and `Bl` are two units: nothing may fold their case.
    @Test func codesAreCaseSensitive() throws {
        let f = Self.file
        let bl = try #require(f.units["BL"]), bL = try #require(f.units["Bl"])
        #expect(bl != bL)
        #expect(bl.name.localizedCaseInsensitiveContains("limestone"))
        #expect(bL.name.localizedCaseInsensitiveContains("Blessington"))
        let sections = Legend.soils(f)
        let codes = sections.flatMap { $0.runs.flatMap(\.rows) }.map(\.code)
        #expect(codes.contains("BL") && codes.contains("Bl"))
    }

    @Test func aWrongVersionIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "izzy-soils-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Data(contentsOf: TestData.root.appending(path: BundledData.File.soils))
        let text = String(decoding: original, as: UTF8.self).replacing(#""version": 1"#, with: #""version": 2"#, maxReplacements: 1)
        #expect(text != String(decoding: original, as: UTF8.self), "the fixture rewrite found the version field")
        try Data(text.utf8).write(to: dir.appending(path: BundledData.File.soils))
        #expect(throws: DataError.unsupportedVersion(file: BundledData.File.soils, found: 2, supported: 1)) {
            try BundledData(root: dir).soilUnits()
        }
        // and a different shape under a wrong version still says "version"
        try Data(#"{"version": 7}"#.utf8).write(to: dir.appending(path: BundledData.File.soils))
        #expect(throws: DataError.unsupportedVersion(file: BundledData.File.soils, found: 7, supported: 1)) {
            try BundledData(root: dir).soilUnits()
        }
        #expect(BundledData(root: dir).soilsArchive == nil)
    }

    @Test func extentWording() {
        let au = Locale(identifier: "en_AU")
        #expect(SoilsFile.formatExtent(hectares: 54_337.7, polygons: 206, locale: au) == "~543 km² in 206 patches")
        #expect(SoilsFile.formatExtent(hectares: 150, polygons: 1, locale: au) == "~2 km² in 1 patch")
        #expect(SoilsFile.formatExtent(hectares: 70.4, polygons: 2, locale: au) == "70 ha in 2 patches")
        #expect(SoilsFile.formatExtent(hectares: 0.3, polygons: 1, locale: au) == "1 ha in 1 patch")
        #expect(SoilsFile.formatExtent(hectares: 1_234_500, polygons: 1_500, locale: au) == "~12,345 km² in 1,500 patches")
        for u in Self.file.units.values { #expect(!u.extentText(locale: au).contains("~0 km²")) }
    }

    /// Sections by main order, in the ASC key's order; every unit exactly once;
    /// the unclassified ones last.
    @Test func legendSectionsCoverEveryUnitOnce() {
        let f = Self.file
        let sections = Legend.soils(f)
        let codes = sections.flatMap { $0.runs.flatMap(\.rows) }.map(\.code)
        #expect(codes.count == f.units.count)
        #expect(Set(codes) == Set(f.units.keys))
        #expect(sections.count == 13)  // 12 main orders + unclassified
        #expect(sections.last?.title == Legend.unclassifiedSoilsTitle)
        #expect(sections.last?.count == 34)
        let key = Legend.soilOrderKey.map(\.name)
        let mains = sections.dropLast().map { String($0.title.dropLast()) }  // "Ferrosols" → "Ferrosol"
        #expect(mains.allSatisfy(key.contains))
        #expect(mains == mains.sorted { key.firstIndex(of: $0)! < key.firstIndex(of: $1)! })
        for s in sections.dropLast() {
            let order = String(s.title.dropLast())
            #expect(s.runs.flatMap(\.rows).allSatisfy { f.units[$0.code]?.orders.first == order }, "\(s.title)")
            #expect(s.shortTitle.count == 2, "\(s.shortTitle)")
        }
        // the index labels are distinct
        #expect(Set(sections.map(\.shortTitle)).count == sections.count)
        // a run shares one fill
        for s in sections { for run in s.runs { #expect(run.rows.allSatisfy { $0.color == run.color }) } }
        // codes read A–Z with digits as numbers, case only breaking ties
        #expect(Legend.codeOrder("Pd2", "Pd10"))
        #expect(Legend.codeOrder("BL", "Bl") && !Legend.codeOrder("Bl", "BL"))
        #expect(Legend.codeOrder("Ba", "BL"))
    }

    @Test func archiveIsVectorWithTheFourLayersInsideTasmania() throws {
        let url = try #require(TestData.data.soilsArchive)
        let r = try PMTilesReader(url: url)
        #expect(r.tileType == .mvt)
        #expect(r.minZoom == 0 && r.maxZoom == 12)
        let b = r.bounds
        #expect(b.west > 143.5 && b.east < 149 && b.south > -44 && b.north < -39.5, "\(b)")
        let layers = try #require(r.metadata()["vector_layers"] as? [[String: Any]])
        // soils_boundaries: only edges between different codes (the unit lines)
        #expect(Set(layers.compactMap { $0["id"] as? String }) == ["soils", "soils_labels", "soils_extent", "soils_boundaries"])
        let soils = try #require(layers.first { $0["id"] as? String == "soils" })
        let fields = try #require(soils["fields"] as? [String: Any])
        #expect(Set(fields.keys).isSuperset(of: ["CODE", "color", "sheet"]))
    }
}
