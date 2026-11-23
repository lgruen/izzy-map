import Foundation
import Testing
@testable import IzzyKit
#if canImport(ImageIO) && canImport(CoreText)
import CoreGraphics
import CoreText
import ImageIO
#endif

// The pins export: StoredZip + DocxWriter (docs/PINS_PLAN.md §6). Checked
// here: zip structure (own reader + macOS unzip/zipinfo), XML well-
// formedness of every part, relationship integrity, text safety, the
// two-across photo table, determinism, and macOS's own .docx reader
// (textutil). Word, Pages and Google Docs themselves can't run in a test.

@Suite struct StoredZipTests {
    static let stamp = StoredZip.Timestamp(year: 2026, month: 11, day: 23, hour: 10, minute: 30, second: 14)

    @Test func crcKnownVectors() {
        #expect(StoredZip.crc32(Data()) == 0)
        #expect(StoredZip.crc32(Data("a".utf8)) == 0xE8B7_BE43)
        #expect(StoredZip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(StoredZip.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        #expect(StoredZip.crc32(Data(repeating: 0, count: 32)) == 0x190A_55AD)
    }

    @Test func dosTimestamp() {
        // 2026-11-23 10:30:14 → date (46 << 9 | 11 << 5 | 23), time (10 << 11 | 30 << 5 | 7)
        #expect(Self.stamp.date == UInt16(46 << 9 | 11 << 5 | 23))
        #expect(Self.stamp.time == UInt16(10 << 11 | 30 << 5 | 7))
        let instant = Date(timeIntervalSince1970: 1_795_429_814)   // 2026-11-23T10:30:14Z
        #expect(StoredZip.Timestamp(instant) == Self.stamp)
        #expect(StoredZip.Timestamp(year: 1970, month: 1, day: 1).date == UInt16(1 << 5 | 1))   // clamps to 1980
    }

    @Test func structureRoundTrips() throws {
        let entries = [
            StoredZip.Entry(path: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            StoredZip.Entry(path: "word/media/image1.jpg", data: Data((0 ..< 5000).map { UInt8($0 % 251) })),
            StoredZip.Entry(path: "empty.txt", data: Data()),
            StoredZip.Entry(path: "notes/Ä-Ω.txt", data: Data("grüße".utf8)),
        ]
        let zip = try StoredZip.archive(entries, modified: Self.stamp)
        let read = try ZipReader.entries(zip)
        #expect(read.map(\.path) == entries.map(\.path))
        #expect(read.map(\.data) == entries.map(\.data))
        #expect(read.allSatisfy { $0.flags == 0x0800 && $0.method == 0 && $0.time == Self.stamp.time && $0.date == Self.stamp.date })
        #expect(read.first?.path == "[Content_Types].xml")
    }

    @Test(.enabled(if: Tools.has("/usr/bin/unzip") && Tools.has("/usr/bin/zipinfo")))
    func macOSUnzipAccepts() throws {
        let entries = [
            StoredZip.Entry(path: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            StoredZip.Entry(path: "word/document.xml", data: Data(repeating: 0x41, count: 70_000)),
            StoredZip.Entry(path: "word/media/image1.jpg", data: Data((0 ..< 9999).map { UInt8($0 & 0xFF) })),
            StoredZip.Entry(path: "unicode/Ä.txt", data: Data("x".utf8)),
        ]
        let file = try Tools.temporaryFile("zip", contents: StoredZip.archive(entries, modified: Self.stamp))
        defer { try? FileManager.default.removeItem(at: file) }
        let test = try Tools.run("/usr/bin/unzip", ["-t", file.path(percentEncoded: false)])
        #expect(test.status == 0, "\(test.out)")
        #expect(test.out.contains("No errors detected"))
        let info = try Tools.run("/usr/bin/zipinfo", ["-1", file.path(percentEncoded: false)])
        #expect(info.status == 0)
        let names = info.out.split(separator: "\n").map(String.init)
        #expect(names.count == 4)
        #expect(Array(names.prefix(3)) == ["[Content_Types].xml", "word/document.xml", "word/media/image1.jpg"])
        let verbose = try Tools.run("/usr/bin/zipinfo", ["-v", file.path(percentEncoded: false)])
        #expect(verbose.out.contains("compression method:                             none (stored)"))
    }

    @Test func refusesWhatWouldBeCorrupt() throws {
        let stamp = Self.stamp
        // one entry larger than the 32-bit field allows (limit lowered for the test)
        #expect(throws: StoredZip.Failure.tooLarge(path: "big")) {
            try StoredZip.archive([StoredZip.Entry(path: "big", data: Data(count: 200))], modified: stamp, limit: 100)
        }
        // the second entry's end passes the limit
        #expect(throws: StoredZip.Failure.tooLarge(path: "b")) {
            try StoredZip.archive([StoredZip.Entry(path: "a", data: Data(count: 40)),
                                   StoredZip.Entry(path: "b", data: Data(count: 40))], modified: stamp, limit: 100)
        }
        // entries fit, the central directory doesn't
        #expect(throws: StoredZip.Failure.tooLarge(path: "a")) {
            try StoredZip.archive([StoredZip.Entry(path: "a", data: Data(count: 60))], modified: stamp, limit: 100)
        }
        let many = (0 ..< 65_535).map { StoredZip.Entry(path: "f\($0)", data: Data()) }
        #expect(throws: StoredZip.Failure.tooManyEntries(65_535)) { try StoredZip.archive(many, modified: stamp) }
        #expect(throws: StoredZip.Failure.duplicatePath("a")) {
            try StoredZip.archive([StoredZip.Entry(path: "a", data: Data()), StoredZip.Entry(path: "a", data: Data())],
                                  modified: stamp)
        }
        // OPC part names are case-insensitive
        #expect(throws: StoredZip.Failure.duplicatePath("word/document.xml")) {
            try StoredZip.archive([StoredZip.Entry(path: "Word/Document.XML", data: Data()),
                                   StoredZip.Entry(path: "word/document.xml", data: Data())], modified: stamp)
        }
        for bad in ["", "/abs", "a\\b", "../up", "a/../b", "nul\u{0}", "a//b", "a/", "dir/", "a/b.", "./a", "a/./b", "."] {
            #expect(throws: StoredZip.Failure.invalidPath(bad)) {
                try StoredZip.archive([StoredZip.Entry(path: bad, data: Data())], modified: stamp)
            }
        }
        // an empty archive is just the end record
        #expect(try StoredZip.archive([], modified: stamp).count == StoredZip.endRecordLength)
    }
}

@Suite struct DocxWriterTests {
    static let created = Date(timeIntervalSince1970: 1_795_429_814)   // 2026-11-23T10:30:14Z

    /// Structure tests don't need decodable images: the writer only checks
    /// the JPEG SOI marker.
    static func fakeJPEG(_ n: UInt8) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, n, 0xFF, 0xD9]) }

    static let document = ExportDocument(
        title: "Knocklofty Reserve",
        subtitle: ["12 – 19 November 2026", "3 pins"],
        sections: [
            .init(heading: "Blue gum stand", meta: ["19 Nov 2026, 10:12", "−42.8806, 147.3069 · MGA55 525 123"],
                  link: .init(text: "Open in Maps", url: URL(string: "https://maps.apple.com/?ll=-42.8806,147.3069&q=Pin")!),
                  body: "First paragraph.\nSecond line.\n\n\nNext paragraph\twith a tab.",
                  photos: [.init(jpeg: fakeJPEG(1), pixelWidth: 1600, pixelHeight: 1200, caption: "Trunk"),
                           .init(jpeg: fakeJPEG(2), pixelWidth: 1200, pixelHeight: 1600, caption: "Canopy"),
                           .init(jpeg: fakeJPEG(3), pixelWidth: 1000, pixelHeight: 1000, caption: "")]),
            .init(heading: "Track junction", body: "Short note."),
            .init(heading: "Rock", link: .init(text: "", url: URL(string: "https://example.org/a?b=1&c=2")!),
                  photos: [.init(jpeg: fakeJPEG(4), pixelWidth: 800, pixelHeight: 600, caption: "Dolerite")]),
        ])

    @Test func partsAreWellFormedAndLinked() throws {
        let docx = try DocxWriter.data(for: Self.document, created: Self.created, creator: "Izzy")
        let parts = try ZipReader.entries(docx)
        let byPath = Dictionary(uniqueKeysWithValues: parts.map { ($0.path, $0.data) })
        #expect(parts.first?.path == "[Content_Types].xml")
        for required in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml",
                         "word/settings.xml", "word/_rels/document.xml.rels", "docProps/core.xml"] {
            #expect(byPath[required] != nil, "missing \(required)")
        }
        var containersSeen = Set<String>()
        for part in parts where part.path.hasSuffix(".xml") || part.path.hasSuffix(".rels") {
            let scan = XMLScan(part.data)
            #expect(scan.ok, "\(part.path) is not well-formed")
            // XMLParser accepts undeclared prefixes; Word rejects the file
            #expect(scan.undeclaredPrefixes.isEmpty, "\(part.path): undeclared \(scan.undeclaredPrefixes)")
            // child order inside the containers Word validates strictly
            for (container, children) in scan.childLists where WordOrder.sequences[container] != nil {
                containersSeen.insert(container)
                #expect(WordOrder.inOrder(children, WordOrder.sequences[container]!),
                        "\(part.path): \(container) children out of order: \(children)")
            }
        }
        #expect(containersSeen == Set(WordOrder.sequences.keys), "never exercised: \(Set(WordOrder.sequences.keys).subtracting(containersSeen))")
        // the checks themselves catch what they are for
        #expect(!WordOrder.inOrder(["w:spacing", "w:pStyle"], WordOrder.sequences["w:pPr"]!))
        #expect(!WordOrder.inOrder(["w:pStyle", "w:bogus"], WordOrder.sequences["w:pPr"]!))
        #expect(XMLScan(Data("<r xmlns:w=\"u\"><w:a/><x:b/><c y:z=\"1\"/></r>".utf8)).undeclaredPrefixes == ["x", "y"])

        // every Override names an existing part; every part but [Content_Types].xml
        // has an Override or a Default for its extension
        let types = XMLScan(byPath["[Content_Types].xml"]!)
        let overrides = Set(types.attributes("Override", "PartName"))
        for name in overrides { #expect(byPath[String(name.dropFirst())] != nil, "\(name) overridden but absent") }
        let defaults = Set(types.attributes("Default", "Extension").map { $0.lowercased() })
        for part in parts where part.path != "[Content_Types].xml" {
            let ext = part.path.split(separator: "/").last!.split(separator: ".").last.map { $0.lowercased() } ?? ""
            #expect(overrides.contains("/" + part.path) || defaults.contains(ext), "\(part.path) has no content type")
        }
        #expect(types.elements.contains { $0.name == "Default" && $0.attrs["Extension"] == "jpg" && $0.attrs["ContentType"] == "image/jpeg" })

        // package rels → the main document and core properties
        let packageRels = XMLScan(byPath["_rels/.rels"]!)
        #expect(Set(packageRels.attributes("Relationship", "Target")) == ["word/document.xml", "docProps/core.xml"])

        // document rels ↔ document.xml
        let rels = XMLScan(byPath["word/_rels/document.xml.rels"]!).elements.filter { $0.name == "Relationship" }
        let relByID = Dictionary(uniqueKeysWithValues: rels.map { ($0.attrs["Id"]!, $0.attrs) })
        #expect(relByID.count == rels.count, "duplicate relationship ids")
        let doc = XMLScan(byPath["word/document.xml"]!)
        let embeds = doc.attributes("a:blip", "r:embed")
        let links = doc.attributes("w:hyperlink", "r:id")
        #expect(embeds.count == 4)
        #expect(links.count == 2)
        for id in embeds {
            let rel = try #require(relByID[id], "embed \(id) has no relationship")
            #expect(rel["Type"]!.hasSuffix("/image"))
            #expect(byPath["word/" + rel["Target"]!] != nil, "\(rel["Target"]!) missing")
        }
        for id in links {
            let rel = try #require(relByID[id])
            #expect(rel["Type"]!.hasSuffix("/hyperlink") && rel["TargetMode"] == "External")
        }
        #expect(links.compactMap { relByID[$0]?["Target"] }.last == "https://example.org/a?b=1&c=2")
        // every media part is referenced exactly once; the images in order
        let media = parts.map(\.path).filter { $0.hasPrefix("word/media/") }
        #expect(media == (1 ... 4).map { "word/media/image\($0).jpg" })
        #expect(embeds.map { "word/" + relByID[$0]!["Target"]! } == media)
        #expect(media.map { byPath[$0]! } == (1 ... 4).map { Self.fakeJPEG(UInt8($0)) })
        for target in ["styles.xml", "settings.xml"] {
            #expect(rels.contains { $0.attrs["Target"] == target })
        }
        // drawing ids are unique
        let docPrIDs = doc.attributes("wp:docPr", "id")
        #expect(Set(docPrIDs).count == docPrIDs.count)

        // styles: the built-in ids and names the importers map
        let styles = XMLScan(byPath["word/styles.xml"]!).elements
        var names: [String: String] = [:]
        var current: String?
        for e in styles {
            if e.name == "w:style" { current = e.attrs["w:styleId"] }
            if e.name == "w:name", let id = current { names[id] = e.attrs["w:val"] }
        }
        #expect(names["Title"] == "Title" && names["Subtitle"] == "Subtitle" && names["Normal"] == "Normal")
        #expect(names["Heading1"] == "heading 1" && names["Heading2"] == "heading 2" && names["Caption"] == "caption")
        let usedStyles = Set(doc.attributes("w:pStyle", "w:val") + doc.attributes("w:rStyle", "w:val"))
        #expect(usedStyles.isSubset(of: Set(names.keys)), "\(usedStyles.subtracting(names.keys))")

        // core properties
        let core = String(decoding: byPath["docProps/core.xml"]!, as: UTF8.self)
        #expect(core.contains("<dc:title>Knocklofty Reserve</dc:title>"))
        #expect(core.contains("<dc:creator>Izzy</dc:creator>"))
        #expect(core.contains(">2026-11-23T10:30:14Z</dcterms:created>"))
    }

    @Test func photosTwoAcrossWithCaptions() throws {
        let xml = try Self.documentXML(Self.document)
        // section 1: 3 photos → 2 rows, the last cell empty; section 3: 1 photo → 1 row
        #expect(xml.components(separatedBy: "<w:tbl>").count - 1 == 2)
        #expect(xml.components(separatedBy: "<w:tr>").count - 1 == 3)
        #expect(xml.components(separatedBy: "<w:tc>").count - 1 == 6)
        #expect(xml.components(separatedBy: "<w:p/></w:tc>").count - 1 == 2)
        #expect(xml.components(separatedBy: "<w:pStyle w:val=\"Caption\"/>").count - 1 == 3)   // empty caption: none
        #expect(xml.contains("<w:tblLayout w:type=\"fixed\"/>"))
        #expect(xml.contains("<w:insideV w:val=\"nil\"/>"))
        // sizes: column width, aspect ratio kept (landscape, portrait, square)
        let w = DocxWriter.Layout.photoWidthEMU
        #expect(w == (4819 - 113) * 635 - 36_000)   // ~1 mm slack inside the cell
        // picture paragraphs at single line spacing (Word scales a picture's line by 1.1 otherwise)
        #expect(xml.components(separatedBy: "<w:spacing w:after=\"60\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:drawing>").count - 1 == 3)
        #expect(xml.components(separatedBy: "<w:spacing w:after=\"240\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:drawing>").count - 1 == 1)
        #expect(xml.contains("<wp:extent cx=\"\(w)\" cy=\"\(Int((Double(w) * 0.75).rounded()))\"/>"))
        #expect(xml.contains("<wp:extent cx=\"\(w)\" cy=\"\(Int((Double(w) * 4 / 3).rounded()))\"/>"))
        #expect(xml.contains("<wp:extent cx=\"\(w)\" cy=\"\(w)\"/>"))
        // the document ends on a paragraph, not a table
        #expect(xml.contains("</w:tbl><w:p/><w:sectPr>"))
        // the heading keeps with what follows (style), meta lines too
        #expect(xml.contains("<w:pStyle w:val=\"PinMeta\"/><w:keepNext/>"))
    }

    @Test func photoExtentMaths() {
        let w = DocxWriter.Layout.photoWidthEMU
        // 914,400 EMU per inch: the photo column is ≈ 3.27 in (83 mm) wide
        #expect(abs(Double(w) / 914_400 * 25.4 - 82.0) < 0.1)
        #expect(DocxWriter.Layout.photoExtent(pixelWidth: 1600, pixelHeight: 900) == (w, Int((Double(w) * 9 / 16).rounded())))
        #expect(DocxWriter.Layout.photoExtent(pixelWidth: 900, pixelHeight: 1600) == (w, DocxWriter.Layout.photoMaxHeightEMU))
        // taller than 9:16 narrows instead of growing
        let tall = DocxWriter.Layout.photoExtent(pixelWidth: 500, pixelHeight: 2000)
        #expect(tall.cy == DocxWriter.Layout.photoMaxHeightEMU)
        #expect(tall.cx == Int((Double(DocxWriter.Layout.photoMaxHeightEMU) / 4).rounded()))
        #expect(DocxWriter.Layout.photoExtent(pixelWidth: 10_000_000, pixelHeight: 1).cy == 1)
    }

    @Test func userTextSurvivesAsText() throws {
        let hostile = "a<b>&c\"d'e \u{0}\u{1}\u{8}\u{B}\u{1F}\u{7F}\u{9F}\u{FFFE}\u{FFFF}f 🌿 × — “q”"
        let doc = ExportDocument(
            title: "T <&> \"'" + "\u{1}",
            subtitle: ["s & t"],
            sections: [.init(heading: "H <1>\u{FFFF}", meta: ["m'\u{2}"],
                             link: .init(text: "L&\u{3}", url: URL(string: "https://x.org/?a=1&b='2'")!),
                             body: hostile,
                             photos: [.init(jpeg: Self.fakeJPEG(1), pixelWidth: 4, pixelHeight: 3, caption: "c<\"\u{4}>")])])
        let xml = try Self.documentXML(doc)
        let scan = XMLScan(Data(xml.utf8))
        #expect(scan.ok)
        let text = scan.text(of: "w:t")
        #expect(text.contains("T <&> \"'"))
        #expect(text.contains("H <1>"))
        #expect(text.contains("m'"))
        #expect(text.contains("L&"))
        #expect(text.contains("a<b>&c\"d'e "))
        #expect(text.contains("f 🌿 × — “q”"))
        #expect(text.contains("c<\">"))
        for forbidden: Unicode.Scalar in ["\u{0}", "\u{1}", "\u{2}", "\u{3}", "\u{4}", "\u{8}", "\u{B}", "\u{1F}", "\u{7F}", "\u{9F}", "\u{FFFE}", "\u{FFFF}"] {
            #expect(!xml.unicodeScalars.contains(forbidden), "U+\(String(forbidden.value, radix: 16)) left in")
        }
        // the vertical tab became Word's line break; text runs preserve spaces
        #expect(xml.contains("d&apos;e </w:t><w:br/><w:t xml:space=\"preserve\">f 🌿"))
        #expect(!xml.contains("<w:t>"))
        // the hyperlink target is escaped in the rels part
        let rels = try ZipReader.entries(DocxWriter.data(for: doc, created: Self.created))
            .first { $0.path == "word/_rels/document.xml.rels" }!.data
        #expect(XMLScan(rels).attributes("Relationship", "Target").contains("https://x.org/?a=1&b='2'"))
    }

    @Test func linesTabsAndParagraphs() {
        typealias T = DocxWriter.Text
        #expect(T.clean("a\r\nb\rc\u{85}d\u{2028}e\u{2029}f\u{C}g") == "a\nb\nc\nd\ne\n\nf\n\ng")
        #expect(T.paragraphs("\n\none\ntwo\n\n \t\n\nthree\n\n") == ["one\ntwo", "three"])
        #expect(T.paragraphs("") == [])
        #expect(T.paragraphs("  \n\t") == [])
        #expect(T.runs("") == "")
        #expect(T.runs("a\tb\nc") == "<w:r><w:t xml:space=\"preserve\">a</w:t><w:tab/><w:t xml:space=\"preserve\">b</w:t><w:br/><w:t xml:space=\"preserve\">c</w:t></w:r>")
        #expect(T.runs("\n") == "<w:r><w:br/></w:r>")
        #expect(T.singleLine(" Two\nlines\there ") == "Two lines here")
        let xml = try? Self.documentXML(ExportDocument(title: "", sections: [.init(heading: "H", body: "p1 l1\np1 l2\n\np2")]))
        #expect(xml?.contains("<w:p><w:r><w:t xml:space=\"preserve\">p1 l1</w:t><w:br/><w:t xml:space=\"preserve\">p1 l2</w:t></w:r></w:p><w:p><w:r><w:t xml:space=\"preserve\">p2</w:t></w:r></w:p>") == true)
    }

    @Test func emptyTextStillValid() throws {
        let empties = [
            ExportDocument(title: "", sections: []),
            ExportDocument(title: "", subtitle: ["", "\u{1}"], sections: [
                .init(heading: "", meta: [""], link: .init(text: "", url: URL(string: "https://example.org")!), body: "",
                      photos: [.init(jpeg: Self.fakeJPEG(1), pixelWidth: 3, pixelHeight: 2, caption: "")]),
                .init(heading: "\u{0}", body: "\n\n  \n"),
            ]),
        ]
        for doc in empties {
            let docx = try DocxWriter.data(for: doc, created: Self.created)
            for part in try ZipReader.entries(docx) where part.path.hasSuffix("xml") || part.path.hasSuffix("rels") {
                #expect(XMLScan(part.data).ok, "\(part.path)")
            }
            let xml = try Self.documentXML(doc)
            #expect(!xml.contains("<w:t xml:space=\"preserve\"></w:t>"))
            #expect(!xml.contains("<w:r></w:r>"))
            #expect(!xml.contains("<w:body><w:sectPr>"))
            // an empty heading is left out (no blank outline entry)
            #expect(!xml.contains("Heading1"))
        }
        let core = try ZipReader.entries(DocxWriter.data(for: empties[0], created: Self.created))
            .first { $0.path == "docProps/core.xml" }!.data
        #expect(!String(decoding: core, as: UTF8.self).contains("dc:title"))
        // an empty link text shows the URL
        #expect(try Self.documentXML(empties[1]).contains(">https://example.org</w:t>"))
    }

    @Test func refusesBadPhotos() {
        let notJPEG = ExportDocument(title: "x", sections: [.init(heading: "a"), .init(heading: "b", photos: [
            .init(jpeg: Self.fakeJPEG(1), pixelWidth: 1, pixelHeight: 1),
            .init(jpeg: Data("\u{89}PNG".utf8), pixelWidth: 1, pixelHeight: 1)])])
        #expect(throws: DocxWriter.Failure.notJPEG(section: 1, photo: 1)) {
            try DocxWriter.data(for: notJPEG, created: Self.created)
        }
        let noSize = ExportDocument(title: "x", sections: [.init(heading: "a", photos: [
            .init(jpeg: Self.fakeJPEG(1), pixelWidth: 0, pixelHeight: 10)])])
        #expect(throws: DocxWriter.Failure.invalidPhotoSize(section: 0, photo: 0)) {
            try DocxWriter.data(for: noSize, created: Self.created)
        }
    }

    @Test func deterministic() throws {
        let a = try DocxWriter.data(for: Self.document, created: Self.created, creator: "Izzy")
        let b = try DocxWriter.data(for: Self.document, created: Self.created, creator: "Izzy")
        #expect(a == b)
        let later = try DocxWriter.data(for: Self.document, created: Self.created.addingTimeInterval(60), creator: "Izzy")
        #expect(a != later)
    }

    #if canImport(ImageIO) && canImport(CoreText)
    @Test(.enabled(if: Tools.has("/usr/bin/textutil")))
    func macOSReadsItInOrder() throws {
        let doc = ExportDocument(
            title: "Survey Alpha",
            subtitle: ["Two pins"],
            sections: [
                .init(heading: "Heading One", meta: ["Meta line one"], link: .init(text: "Link one", url: URL(string: "https://example.org/1")!),
                      body: "Note one first paragraph.\n\nNote one second paragraph — “quoted” × 2.",
                      photos: [TestJPEG.photo(width: 160, height: 120, hue: 0.1, caption: "Caption A"),
                               TestJPEG.photo(width: 90, height: 160, hue: 0.4, caption: "Caption B"),
                               TestJPEG.photo(width: 100, height: 100, hue: 0.7, caption: "Caption C")]),
                .init(heading: "Heading Two", body: "Note two <&> text.",
                      photos: [TestJPEG.photo(width: 120, height: 80, hue: 0.9, caption: "Caption D")]),
            ])
        let file = try Tools.temporaryFile("docx", contents: DocxWriter.data(for: doc, created: Self.created))
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try Tools.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", file.path(percentEncoded: false)])
        #expect(result.status == 0)
        let text = result.out
        let expected = ["Survey Alpha", "Two pins", "Heading One", "Meta line one", "Link one", "Note one first paragraph.",
                        "Note one second paragraph — “quoted” × 2.", "Caption A", "Caption B", "Caption C",
                        "Heading Two", "Note two <&> text.", "Caption D"]
        var cursor = text.startIndex
        for needle in expected {
            let found = text.range(of: needle, range: cursor ..< text.endIndex)
            #expect(found != nil, "\(needle) missing or out of order in:\n\(text)")
            if let found { cursor = found.upperBound }
        }
    }

    /// A realistic file for the manual spike (Word, Pages, Drive → Google
    /// Docs): `IZZY_DOCX_SAMPLE_DIR=<dir> swift test --filter writeSample`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IZZY_DOCX_SAMPLE_DIR"] != nil))
    func writeSample() throws {
        let dir = URL(filePath: ProcessInfo.processInfo.environment["IZZY_DOCX_SAMPLE_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func maps(_ lat: Double, _ lon: Double) -> ExportDocument.Link {
            .init(text: String(format: "%.5f, %.5f — open in Maps", lat, lon),
                  url: URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=Pin")!)
        }
        let doc = ExportDocument(
            title: "Knocklofty Reserve — site walk",
            subtitle: ["12 – 19 November 2026", "4 pins · 5 photos"],
            sections: [
                .init(heading: "Blue gum stand above the quarry",
                      meta: ["Wednesday 19 November 2026, 10:12", "MGA55 E 524 870 N 5 254 310"],
                      link: maps(-42.87412, 147.30245),
                      body: """
                        Eucalyptus × hybrid — 12 m, multi-stemmed, a “tidy” crown after last winter’s storm.
                        Bark shedding in long ribbons; hollows at ~4 m on the north side.

                        Understorey: Bursaria spinosa, Acacia dealbata saplings, a little Lomandra.
                        \tTo check: possum activity at dusk.
                        """,
                      photos: [TestJPEG.photo(width: 1600, height: 1200, hue: 0.33, label: "1 · landscape 4:3", caption: "Photo 1 — the stand from the track (4:3)"),
                               TestJPEG.photo(width: 1200, height: 1600, hue: 0.08, label: "2 · portrait 3:4", caption: "Photo 2 — hollow on the north side (3:4)")]),
                .init(heading: "Track junction, fire trail",
                      meta: ["Wednesday 19 November 2026, 10:40"],
                      link: maps(-42.87655, 147.29870),
                      body: "Erosion where the fire trail meets the walking track.\n\nSuggest rock armouring — ask the ranger about the ‘Friends of’ working bee.",
                      photos: [TestJPEG.photo(width: 1600, height: 1600, hue: 0.6, label: "3 · square 1:1", caption: "Photo 3 — gully head (1:1)")]),
                .init(heading: "Grassland patch (Themeda)",
                      meta: ["Thursday 20 November 2026, 09:05"],
                      link: maps(-42.88021, 147.29512),
                      body: "Kangaroo grass in flower. Weeds: Chilean needle grass at the edge — map extent next visit.\n\nNo photos at this pin.",
                      photos: []),
                .init(heading: "Dolerite outcrop & lookout",
                      meta: ["Friday 21 November 2026, 16:30", "Notes in dictation"],
                      link: maps(-42.88290, 147.30110),
                      body: "Views over the Derwent; lichen-rich surfaces.\nCould become a sketching stop.\n\nLast paragraph with <angle> & “curly” quotes.",
                      photos: [TestJPEG.photo(width: 1600, height: 900, hue: 0.0, label: "4 · panorama 16:9", caption: "Photo 4 — view east (16:9)"),
                               TestJPEG.photo(width: 1066, height: 1600, hue: 0.8, label: "5 · portrait 2:3", caption: "Photo 5 — lichen detail (2:3)")]),
            ])
        let data = try DocxWriter.data(for: doc, created: Self.created, creator: "IzzyMap")
        try data.write(to: dir.appending(path: "pins-sample.docx"))
    }
    #endif

    static func documentXML(_ doc: ExportDocument) throws -> String {
        let part = try ZipReader.entries(DocxWriter.data(for: doc, created: created)).first { $0.path == "word/document.xml" }
        return String(decoding: try #require(part).data, as: UTF8.self)
    }
}

// MARK: Helpers

/// Reads a zip through its central directory (stored entries only) and
/// checks every local header and CRC against it.
enum ZipReader {
    struct Entry { var path: String; var data: Data; var flags: UInt16; var method: UInt16; var time: UInt16; var date: UInt16 }
    struct Bad: Error, CustomStringConvertible { var description: String }

    static func entries(_ zip: Data) throws -> [Entry] {
        let b = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let end = b.count - 22
        guard end >= 0, u32(end) == 0x0605_4B50 else { throw Bad(description: "no end record") }
        let count = u16(end + 10), cdSize = u32(end + 12), cdOffset = u32(end + 16)
        guard u16(end + 8) == count, cdOffset + cdSize == end else { throw Bad(description: "end record mismatch") }
        var out: [Entry] = []
        var p = cdOffset
        for _ in 0 ..< count {
            guard u32(p) == 0x0201_4B50 else { throw Bad(description: "central header at \(p)") }
            let flags = UInt16(u16(p + 8)), method = UInt16(u16(p + 10))
            let time = UInt16(u16(p + 12)), date = UInt16(u16(p + 14))
            let crc = u32(p + 16), csize = u32(p + 20), usize = u32(p + 24)
            let nameLen = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46) ..< (p + 46 + nameLen)], as: UTF8.self)
            guard method == 0, csize == usize, u32(local) == 0x0403_4B50, u16(local + 26) == nameLen,
                  u32(local + 14) == crc, u32(local + 18) == csize,
                  Array(b[(local + 30) ..< (local + 30 + nameLen)]) == Array(name.utf8)
            else { throw Bad(description: "local header of \(name)") }
            let start = local + 30 + nameLen + u16(local + 28)
            let data = Data(b[start ..< (start + csize)])
            guard StoredZip.crc32(data) == UInt32(crc) else { throw Bad(description: "CRC of \(name)") }
            out.append(Entry(path: name, data: data, flags: flags, method: method, time: time, date: date))
            p += 46 + nameLen + extra + comment
        }
        guard p == end else { throw Bad(description: "central directory length") }
        return out
    }
}

/// Foundation's XMLParser: well-formedness plus a flat list of elements
/// (qualified names, attributes), character data per element name, each
/// element's direct child names, and prefixes used without an in-scope
/// `xmlns:` declaration (XMLParser itself lets those through).
final class XMLScan: NSObject, XMLParserDelegate {
    struct Element { var name: String; var attrs: [String: String] }
    private(set) var ok = false
    private(set) var elements: [Element] = []
    /// (element name, its direct children's names in document order).
    var childLists: [(String, [String])] { zip(elements.map(\.name), children).map { ($0, $1) } }
    private(set) var undeclaredPrefixes: Set<String> = []
    private var children: [[String]] = []
    private var stack: [String] = []
    private var indexStack: [Int] = []
    private var prefixScopes: [Set<String>] = [["xml"]]
    private var texts: [String: String] = [:]

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        ok = parser.parse()
    }

    func attributes(_ element: String, _ attribute: String) -> [String] {
        elements.filter { $0.name == element }.compactMap { $0.attrs[attribute] }
    }
    func text(of element: String) -> String { texts[element] ?? "" }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if let parent = indexStack.last { children[parent].append(name) }
        indexStack.append(elements.count)
        elements.append(Element(name: name, attrs: attributes))
        children.append([])
        stack.append(name)
        var scope = prefixScopes.last!
        for key in attributes.keys where key.hasPrefix("xmlns:") { scope.insert(String(key.dropFirst(6))) }
        prefixScopes.append(scope)
        for qname in [name] + attributes.keys.filter({ $0 != "xmlns" && !$0.hasPrefix("xmlns:") }) {
            if let colon = qname.firstIndex(of: ":"), !scope.contains(String(qname[..<colon])) {
                undeclaredPrefixes.insert(String(qname[..<colon]))
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        indexStack.removeLast()
        prefixScopes.removeLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let top = stack.last { texts[top, default: ""] += string }
    }
}

/// The child sequences ECMA-376 (transitional) prescribes for the
/// containers Word validates strictly — written out here, independent of
/// the writer, so a reordering there fails a test. A container's children
/// must all be listed and appear in this order (repeats allowed).
enum WordOrder {
    static let sequences: [String: [String]] = [
        "w:pPr": w("pStyle keepNext keepLines pageBreakBefore framePr widowControl numPr suppressLineNumbers pBdr shd "
                   + "tabs suppressAutoHyphens kinsoku wordWrap overflowPunct topLinePunct autoSpaceDE autoSpaceDN bidi "
                   + "adjustRightInd snapToGrid spacing ind contextualSpacing mirrorIndents suppressOverlap jc "
                   + "textDirection textAlignment textboxTightWrap outlineLvl divId cnfStyle rPr sectPr pPrChange"),
        "w:rPr": w("rStyle rFonts b bCs i iCs caps smallCaps strike dstrike outline shadow emboss imprint noProof "
                   + "snapToGrid vanish webHidden color spacing w kern position sz szCs highlight u effect bdr shd "
                   + "fitText vertAlign rtl cs em lang eastAsianLayout specVanish oMath"),
        "w:tblPr": w("tblStyle tblpPr tblOverlap bidiVisual tblStyleRowBandSize tblStyleColBandSize tblW jc "
                     + "tblCellSpacing tblInd tblBorders shd tblLayout tblCellMar tblLook"),
        "w:tcPr": w("cnfStyle tcW gridSpan hMerge vMerge tcBorders shd noWrap tcMar textDirection tcFitText vAlign hideMark"),
        "w:sectPr": w("headerReference footerReference footnotePr endnotePr type pgSz pgMar paperSrc pgBorders "
                      + "lnNumType pgNumType cols formProt vAlign noEndnote titlePg textDirection bidi rtlGutter "
                      + "docGrid printerSettings sectPrChange"),
        "w:style": w("name aliases basedOn next link autoRedefine hidden uiPriority semiHidden unhideWhenUsed qFormat "
                     + "locked personal personalCompose personalReply rsid pPr rPr tblPr trPr tcPr tblStylePr"),
        "wp:inline": ["wp:extent", "wp:effectExtent", "wp:docPr", "wp:cNvGraphicFramePr", "a:graphic"],
        "pic:pic": ["pic:nvPicPr", "pic:blipFill", "pic:spPr"],
    ]

    private static func w(_ names: String) -> [String] { names.split(separator: " ").map { "w:" + $0 } }

    static func inOrder(_ children: [String], _ sequence: [String]) -> Bool {
        var position = 0
        for child in children {
            guard let found = sequence[position...].firstIndex(of: child) else { return false }
            position = found
        }
        return true
    }
}

enum Tools {
    static func has(_ path: String) -> Bool {
        #if os(macOS)
        FileManager.default.isExecutableFile(atPath: path)
        #else
        false
        #endif
    }

    static func temporaryFile(_ ext: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "izzykit-\(UUID().uuidString).\(ext)")
        try contents.write(to: url)
        return url
    }

    static func run(_ tool: String, _ args: [String]) throws -> (out: String, status: Int32) {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), p.terminationStatus)
        #else
        return ("", -1)
        #endif
    }
}

#if canImport(ImageIO) && canImport(CoreText)
/// Real JPEGs drawn on the fly (no binary fixtures): a diagonal gradient
/// in the given hue, a frame, corner marks and a big label, so a human can
/// tell photos, their order and their aspect ratios apart.
enum TestJPEG {
    static func photo(width: Int, height: Int, hue: CGFloat, label: String? = nil, caption: String) -> ExportDocument.Photo {
        .init(jpeg: jpeg(width: width, height: height, hue: hue, label: label ?? caption),
              pixelWidth: width, pixelHeight: height, caption: caption)
    }

    static func jpeg(width: Int, height: Int, hue: CGFloat, label: String) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        let gradient = CGGradient(colorsSpace: space, colors: [color(hue, 0.55, 0.95), color(hue + 0.12, 0.85, 0.35)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        let line = max(2, min(w, h) / 60)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(line)
        ctx.stroke(CGRect(x: line, y: line, width: w - 2 * line, height: h - 2 * line))
        // a circle in the middle: squashed if the aspect ratio is lost
        let r = min(w, h) * 0.3
        ctx.setLineWidth(line * 1.5)
        ctx.strokeEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r, width: 2 * r, height: 2 * r))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, min(w, h) / 9, nil)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetImageBounds(ctLine, ctx)
        ctx.textPosition = CGPoint(x: max(line * 3, (w - bounds.width) / 2), y: h * 0.08)
        CTLineDraw(ctLine, ctx)
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private static func color(_ hue: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
        // HSB → RGB (CGColor has no HSB initialiser)
        let hh = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = b * s, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = b - c
        let (r, g, bl): (CGFloat, CGFloat, CGFloat) = switch Int(hh) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: bl + m, alpha: 1)
    }
}
#endif
