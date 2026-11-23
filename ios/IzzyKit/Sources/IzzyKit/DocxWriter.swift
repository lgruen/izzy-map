import Foundation

// The pins export (docs/PINS_PLAN.md §6): ONE Word document, written by the
// app itself, that goes to the share sheet as it is and to Google Drive,
// which converts it into a native Google Doc. Word, Pages and Google Docs'
// importer all read plain WordprocessingML, so the document sticks to the
// core of it: built-in paragraph styles under their built-in ids and names
// ("Heading1" / "heading 1" — that is how each importer recognises a real
// heading, not a bold paragraph), inline DrawingML pictures, a borderless
// table for the two-across photos, one external hyperlink per section.
// A common system font (Arial: Windows, macOS/iOS and Google Docs all have
// it), nothing embedded. The model below is independent of the app's pin
// types; the app maps a project's pins onto it.

/// What goes into the exported document — plain values, no app types.
public struct ExportDocument: Sendable, Hashable {
    /// The document's title (style Title; also docProps' dc:title).
    public var title: String
    /// Lines under the title (style Subtitle), e.g. date range, pin count.
    public var subtitle: [String]
    public var sections: [Section]

    public init(title: String, subtitle: [String] = [], sections: [Section]) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
    }

    /// One pin: heading, small meta lines, a link, the note, the photos.
    public struct Section: Sendable, Hashable {
        /// Heading 1. Line breaks become spaces.
        public var heading: String
        /// Small grey lines under the heading (date, coordinates, grid ref).
        public var meta: [String]
        public var link: Link?
        /// The note. A blank line starts a new paragraph; a single line
        /// break stays a line break inside the paragraph; tabs stay tabs.
        public var body: String
        /// Laid out two across, in this order.
        public var photos: [Photo]

        public init(heading: String, meta: [String] = [], link: Link? = nil, body: String = "", photos: [Photo] = []) {
            self.heading = heading
            self.meta = meta
            self.link = link
            self.body = body
            self.photos = photos
        }
    }

    public struct Link: Sendable, Hashable {
        /// Shown text; empty = the URL itself.
        public var text: String
        public var url: URL
        public init(text: String, url: URL) {
            self.text = text
            self.url = url
        }
    }

    public struct Photo: Sendable, Hashable {
        /// Baseline or progressive JPEG, already upright (no EXIF rotation
        /// left for the reader to apply) — Word and Docs ignore EXIF
        /// orientation inside a document.
        public var jpeg: Data
        /// Displayed size in pixels (only the aspect ratio is used).
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var caption: String

        public init(jpeg: Data, pixelWidth: Int, pixelHeight: Int, caption: String = "") {
            self.jpeg = jpeg
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.caption = caption
        }
    }
}

/// Writes an `ExportDocument` as a .docx (a stored zip of WordprocessingML
/// parts). Deterministic: the same document, date and creator give the
/// same bytes.
public enum DocxWriter {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The photo's bytes don't start with a JPEG SOI marker.
        case notJPEG(section: Int, photo: Int)
        /// Width or height ≤ 0.
        case invalidPhotoSize(section: Int, photo: Int)

        public var description: String {
            switch self {
            case .notJPEG(let s, let p): "docx: photo \(p + 1) of section \(s + 1) is not a JPEG"
            case .invalidPhotoSize(let s, let p): "docx: photo \(p + 1) of section \(s + 1) has no size"
            }
        }
    }

    /// The .docx bytes. `created` stamps docProps (created = modified) and
    /// every zip entry; `creator` goes to dc:creator when not empty.
    /// Throws `Failure` for a bad photo, `StoredZip.Failure` past 4 GB.
    public static func data(for document: ExportDocument, created: Date, creator: String = "") throws -> Data {
        var rels: [Relationship] = [
            Relationship(type: Rel.styles, target: "styles.xml"),
            Relationship(type: Rel.settings, target: "settings.xml"),
        ]
        var media: [StoredZip.Entry] = []
        var body = ""
        var pictureID = 0

        let title = Text.singleLine(Text.clean(document.title))
        if !title.isEmpty { body += paragraph(style: "Title", content: Text.runs(title)) }
        for line in document.subtitle {
            let text = Text.clean(line)
            if !text.isEmpty { body += paragraph(style: "Subtitle", content: Text.runs(text)) }
        }

        for (s, section) in document.sections.enumerated() {
            // an empty heading would be a blank entry in the outline
            let heading = Text.singleLine(Text.clean(section.heading))
            if !heading.isEmpty { body += paragraph(style: "Heading1", content: Text.runs(heading)) }
            // the meta block (lines, then the link) keeps with the heading
            // and what follows; tight lines, a normal gap after the last
            var metaBlock = section.meta.map(Text.clean).filter { !$0.isEmpty }.map { Text.runs($0) }
            if let link = section.link {
                let url = Text.clean(link.url.absoluteString)
                var shown = Text.clean(link.text)
                if shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { shown = url }
                rels.append(Relationship(type: Rel.hyperlink, target: url, external: true))
                metaBlock.append("<w:hyperlink r:id=\"\(Relationship.id(rels.count))\" w:history=\"1\">"
                    + Text.runs(shown, rPr: "<w:rPr><w:rStyle w:val=\"Hyperlink\"/></w:rPr>")
                    + "</w:hyperlink>")
            }
            for (i, content) in metaBlock.enumerated() {
                body += paragraph(style: "PinMeta", keepNext: true,
                                  spacingAfter: i == metaBlock.count - 1 ? 160 : nil, content: content)
            }
            for para in Text.paragraphs(Text.clean(section.body)) {
                body += paragraph(style: nil, content: Text.runs(para))
            }

            guard !section.photos.isEmpty else { continue }
            var cells: [String] = []
            for (p, photo) in section.photos.enumerated() {
                guard photo.jpeg.starts(with: [0xFF, 0xD8, 0xFF]) else { throw Failure.notJPEG(section: s, photo: p) }
                guard photo.pixelWidth > 0, photo.pixelHeight > 0 else {
                    throw Failure.invalidPhotoSize(section: s, photo: p)
                }
                pictureID += 1
                let file = "image\(pictureID).jpg"
                media.append(StoredZip.Entry(path: "word/media/" + file, data: photo.jpeg))
                rels.append(Relationship(type: Rel.image, target: "media/" + file))
                let caption = Text.clean(photo.caption)
                let hasCaption = !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let extent = Layout.photoExtent(pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight)
                var cell = paragraph(style: nil, keepNext: hasCaption,
                                     spacingAfter: hasCaption ? 60 : Layout.rowGap, singleLine: true,
                                     content: drawing(id: pictureID, file: file, relID: Relationship.id(rels.count),
                                                      extent: extent, description: Text.singleLine(caption)))
                if hasCaption {
                    cell += paragraph(style: "Caption", spacingAfter: Layout.rowGap, content: Text.runs(caption))
                }
                cells.append(cell)
            }
            body += photoTable(cells)
        }
        // A table may not be the last thing before sectPr in Word's eyes
        // (it always keeps a paragraph after one); end on a paragraph.
        if body.isEmpty || body.hasSuffix("</w:tbl>") { body += "<w:p/>" }

        let documentXML = """
            \(xmlHeader)<w:document \(namespaces)><w:body>\(body)<w:sectPr>\
            <w:pgSz w:w="\(Layout.pageWidth)" w:h="\(Layout.pageHeight)"/>\
            <w:pgMar w:top="\(Layout.margin)" w:right="\(Layout.margin)" w:bottom="\(Layout.margin)" \
            w:left="\(Layout.margin)" w:header="709" w:footer="709" w:gutter="0"/>\
            </w:sectPr></w:body></w:document>
            """
        let documentRels = xmlHeader + "<Relationships xmlns=\"\(Rel.packageNS)\">"
            + rels.enumerated().map { i, r in r.xml(id: Relationship.id(i + 1)) }.joined() + "</Relationships>"

        var entries = [
            StoredZip.Entry(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            StoredZip.Entry(path: "_rels/.rels", data: Data(packageRels.utf8)),
            StoredZip.Entry(path: "docProps/core.xml", data: Data(coreProperties(title: title, creator: creator, created: created).utf8)),
            StoredZip.Entry(path: "word/document.xml", data: Data(documentXML.utf8)),
            StoredZip.Entry(path: "word/_rels/document.xml.rels", data: Data(documentRels.utf8)),
            StoredZip.Entry(path: "word/styles.xml", data: Data(styles.utf8)),
            StoredZip.Entry(path: "word/settings.xml", data: Data(settings.utf8)),
        ]
        entries += media
        return try StoredZip.archive(entries, modified: StoredZip.Timestamp(created))
    }

    // MARK: Layout

    /// Page and photo geometry. Word measures the page in twips (1/20 pt,
    /// 1,440 per inch) and drawings in EMU (914,400 per inch), so one twip
    /// is exactly 635 EMU.
    enum Layout {
        static let pageWidth = 11906        // A4, 210 mm
        static let pageHeight = 16838       // 297 mm
        static let margin = 1134            // 20 mm all round
        static let textWidth = pageWidth - 2 * margin   // 9,638 twips = 170 mm
        static let columnWidth = textWidth / 2          // 4,819
        /// Space on each column's inner side: a 4 mm gap between photos,
        /// outer photo edges flush with the text margins.
        static let gutter = 113
        static let emuPerTwip = 635
        /// Space under each row of photos (twips).
        static let rowGap = 240
        /// Photo width: the column minus its inner gutter (≈ 83 mm), less
        /// ~1 mm of slack so an importer adding its own cell padding
        /// (Google Docs, Pages) neither clips nor rescales the photo.
        static let photoWidthEMU = (columnWidth - gutter) * emuPerTwip - 36_000
        /// A very tall photo stops at 9:16 of the column width (a full
        /// phone screenshot) and narrows instead.
        static let photoMaxHeightEMU = photoWidthEMU * 16 / 9

        /// The drawing's size: full photo width, aspect ratio kept.
        static func photoExtent(pixelWidth: Int, pixelHeight: Int) -> (cx: Int, cy: Int) {
            let w = Double(pixelWidth), h = Double(pixelHeight)
            let cy = (Double(photoWidthEMU) * h / w).rounded()
            if cy <= Double(photoMaxHeightEMU) { return (photoWidthEMU, max(1, Int(cy))) }
            return (max(1, Int((Double(photoMaxHeightEMU) * w / h).rounded())), photoMaxHeightEMU)
        }
    }

    // MARK: Body pieces

    /// `w:p` with the given style (nil = Normal) and content (may be empty:
    /// an empty paragraph is valid). `singleLine`: line spacing 1.0 instead
    /// of the document's 1.1 — Word scales an inline picture's line by it,
    /// which would put ~10 % of the photo's height of blank space above it.
    static func paragraph(style: String?, keepNext: Bool = false, spacingAfter: Int? = nil, singleLine: Bool = false,
                          content: String) -> String {
        var pPr = ""
        if let style { pPr += "<w:pStyle w:val=\"\(style)\"/>" }
        if keepNext { pPr += "<w:keepNext/>" }
        if spacingAfter != nil || singleLine {
            pPr += "<w:spacing" + (spacingAfter.map { " w:after=\"\($0)\"" } ?? "")
                + (singleLine ? " w:line=\"240\" w:lineRule=\"auto\"" : "") + "/>"
        }
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + content + "</w:p>"
    }

    /// The photos two across: a fixed, borderless two-column table; an odd
    /// last photo leaves the second cell empty. Rows don't split across
    /// pages (photo + caption stay together).
    static func photoTable(_ cells: [String]) -> String {
        let w = Layout.columnWidth
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(Layout.textWidth)\" w:type=\"dxa\"/><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"nil\"/>" }.joined()
            + "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar>"
            + ["top", "left", "bottom", "right"].map { "<w:\($0) w:w=\"0\" w:type=\"dxa\"/>" }.joined()
            + "</w:tblCellMar><w:tblLook w:val=\"0000\" w:firstRow=\"0\" w:lastRow=\"0\" w:firstColumn=\"0\" "
            + "w:lastColumn=\"0\" w:noHBand=\"1\" w:noVBand=\"1\"/></w:tblPr>"
            + "<w:tblGrid><w:gridCol w:w=\"\(w)\"/><w:gridCol w:w=\"\(w)\"/></w:tblGrid>"
        for row in stride(from: 0, to: cells.count, by: 2) {
            xml += "<w:tr><w:trPr><w:cantSplit/></w:trPr>"
            for column in 0 ..< 2 {
                let (left, right) = column == 0 ? (0, Layout.gutter) : (Layout.gutter, 0)
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(w)\" w:type=\"dxa\"/><w:tcMar>"
                    + "<w:left w:w=\"\(left)\" w:type=\"dxa\"/><w:right w:w=\"\(right)\" w:type=\"dxa\"/>"
                    + "</w:tcMar></w:tcPr>"
                    + (row + column < cells.count ? cells[row + column] : "<w:p/>")
                    + "</w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    /// An inline picture run (DrawingML `wp:inline` + `pic:pic`).
    static func drawing(id: Int, file: String, relID: String, extent: (cx: Int, cy: Int), description: String) -> String {
        let size = "cx=\"\(extent.cx)\" cy=\"\(extent.cy)\""
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent \(size)/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "<wp:docPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(Text.escape(description))\"/>"
            + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"\(file)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext \(size)/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
            + "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    // MARK: Text

    /// User text → WordprocessingML text.
    enum Text {
        /// Drops what XML 1.0 forbids (C0 controls but tab/LF/CR,
        /// U+FFFE/U+FFFF) and the C1 controls it discourages; normalises
        /// line ends to LF (CRLF, CR, NEL, U+2028; a vertical tab is Word's
        /// own line break) and paragraph ends to a blank line (U+2029, form
        /// feed). Unpaired surrogates can't occur: a Swift String is always
        /// valid Unicode (decoding replaces them with U+FFFD).
        static func clean(_ text: String) -> String {
            var out = String.UnicodeScalarView()
            var afterCR = false
            for scalar in text.unicodeScalars {
                let v = scalar.value
                defer { afterCR = v == 0x0D }
                switch v {
                case 0x0A where afterCR: continue           // the LF of a CRLF
                case 0x09, 0x0A: out.append(scalar)
                case 0x0D, 0x0B, 0x85, 0x2028: out.append("\n")
                case 0x0C, 0x2029: out.append(contentsOf: "\n\n".unicodeScalars)
                case 0x00 ... 0x1F, 0x7F ... 0x9F, 0xFFFE, 0xFFFF: continue
                default: out.append(scalar)
                }
            }
            return String(out)
        }

        /// Line breaks (and tabs) → single spaces, trimmed: headings, the
        /// title and attribute values are one line.
        static func singleLine(_ text: String) -> String {
            text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        /// Paragraphs of cleaned text: separated by blank (or whitespace-
        /// only) lines, runs of them collapsed; leading/trailing blank
        /// lines dropped. Line breaks inside a paragraph stay "\n".
        static func paragraphs(_ text: String) -> [String] {
            var paragraphs: [String] = []
            var lines: [Substring] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")); lines = [] }
                } else {
                    lines.append(line)
                }
            }
            if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
            return paragraphs
        }

        /// One `w:r` for cleaned text: "\n" → `w:br`, tab → `w:tab`, the
        /// rest in `w:t xml:space="preserve"` (escaped). Empty text → "".
        static func runs(_ text: String, rPr: String = "") -> String {
            guard !text.isEmpty else { return "" }
            var out = "<w:r>" + rPr
            var pending = String.UnicodeScalarView()
            func flush() {
                guard !pending.isEmpty else { return }
                out += "<w:t xml:space=\"preserve\">" + escape(String(pending)) + "</w:t>"
                pending = String.UnicodeScalarView()
            }
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\n": flush(); out += "<w:br/>"
                case "\t": flush(); out += "<w:tab/>"
                default: pending.append(scalar)
                }
            }
            flush()
            return out + "</w:r>"
        }

        /// XML-escaped for text and attribute values alike.
        static func escape(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.utf8.count)
            for scalar in text.unicodeScalars {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&apos;"
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }
    }

    // MARK: Package parts

    struct Relationship {
        var type: String
        var target: String
        var external = false
        /// Relationship ids are positional: the n-th (1-based) is "rIdn".
        static func id(_ position: Int) -> String { "rId\(position)" }
        func xml(id: String) -> String {
            "<Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"\(Text.escape(target))\""
                + (external ? " TargetMode=\"External\"" : "") + "/>"
        }
    }

    enum Rel {
        static let packageNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        static let officeDocument = base + "officeDocument"
        static let styles = base + "styles"
        static let settings = base + "settings"
        static let image = base + "image"
        static let hyperlink = base + "hyperlink"
        static let coreProperties = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    }

    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static let namespaces = [
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"",
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"",
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"",
        "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"",
        "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"",
    ].joined(separator: " ")

    static let contentTypes = xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Override PartName="/word/document.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/settings.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" \
        ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """

    static let packageRels = xmlHeader + "<Relationships xmlns=\"\(Rel.packageNS)\">"
        + Relationship(type: Rel.officeDocument, target: "word/document.xml").xml(id: "rId1")
        + Relationship(type: Rel.coreProperties, target: "docProps/core.xml").xml(id: "rId2")
        + "</Relationships>"

    static func coreProperties(title: String, creator: String, created: Date) -> String {
        let stamp = created.formatted(.iso8601)     // 2026-11-23T04:05:06Z
        let creator = Text.singleLine(Text.clean(creator))
        return xmlHeader + """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            """
            + (title.isEmpty ? "" : "<dc:title>\(Text.escape(title))</dc:title>")
            + (creator.isEmpty ? "" : "<dc:creator>\(Text.escape(creator))</dc:creator>")
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    /// Word opens a file without a compatibility mode in "Compatibility
    /// Mode" (Word 2007 layout); 15 = current.
    static let settings = xmlHeader + """
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:defaultTabStop w:val="709"/><w:characterSpacingControl w:val="doNotCompress"/>\
        <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" \
        w:val="15"/></w:compat></w:settings>
        """

    /// Built-in styles under Word's own ids and (lower-case where Word's
    /// are) names — how Word, Pages and Google Docs recognise a Title or a
    /// Heading 1 — plus PinMeta (small grey lines) and Hyperlink. The font
    /// sits on Normal as well as in docDefaults: macOS's reader (Quick
    /// Look, textutil) ignores docDefaults and fell back to Times.
    static let styles = xmlHeader + """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr>\
        <w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/>\
        <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-AU" w:eastAsia="en-AU" w:bidi="ar-SA"/>\
        </w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>\
        <w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>\
        <w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/></w:rPr></w:style>\
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">\
        <w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>\
        <w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>\
        <w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>\
        <w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="80" w:line="240" w:lineRule="auto"/><w:contextualSpacing/></w:pPr>\
        <w:rPr><w:kern w:val="28"/><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="11"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="60"/></w:pPr>\
        <w:rPr><w:color w:val="595959"/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
        <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="480" w:after="80"/><w:outlineLvl w:val="0"/></w:pPr>\
        <w:rPr><w:b/><w:bCs/><w:kern w:val="32"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:unhideWhenUsed/><w:qFormat/>\
        <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr>\
        <w:rPr><w:b/><w:bCs/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="35"/><w:unhideWhenUsed/><w:qFormat/>\
        <w:pPr><w:spacing w:after="240" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:rPr><w:color w:val="404040"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:customStyle="1" w:styleId="PinMeta"><w:name w:val="Pin Details"/>\
        <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="20" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:rPr><w:color w:val="595959"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>\
        <w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/>\
        <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        </w:styles>
        """
}
