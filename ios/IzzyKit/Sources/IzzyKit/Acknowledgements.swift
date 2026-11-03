import Foundation

/// acknowledgements.json (pipeline/build_acknowledgements.py): the licence
/// texts of the third-party components the app distributes — MapLibre
/// Native, the BioCLIP 2.5 weights in the plant-ID pack, the Noto Sans glyphs —
/// read verbatim from the upstream files at pinned refs.
public struct Acknowledgements: Decodable, Sendable, Versioned {
    public struct Component: Decodable, Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var version: String
        /// What it does in IzzyMap.
        public var role: String
        public var licence: String
        public var url: URL
        public var notes: [String]
        public var texts: [LicenceText]
        public var citations: [Citation]
    }

    public struct LicenceText: Decodable, Sendable, Hashable {
        public var title: String
        public var body: String

        /// The body re-flowed for a narrow screen (`Acknowledgements.reflow`).
        public var reflowed: String { Acknowledgements.reflow(body) }
    }

    public struct Citation: Decodable, Sendable, Hashable {
        public var title: String
        /// BibTeX, verbatim from the model card.
        public var text: String
    }

    public static let supportedVersion = 1
    public var version: Int
    public var components: [Component]
    /// One line per bundled dataset credit (shown below the components).
    public var data: [String]
    /// sha256 of each bundled glyph PBF, as verified against its source.
    public var glyphs: [String: String]

    public func component(_ id: String) -> Component? { components.first { $0.id == id } }

    /// Hard-wrapped licence prose re-flowed for a phone: a line break inside
    /// a paragraph becomes a space when the line ran on to the wrap column
    /// (≥ 50 characters) and the next line continues it — not a list item, a
    /// rule or a code fence. Short lines (copyright lines, headings, the last
    /// line of a paragraph) keep their breaks. Whitespace only: every word
    /// stays as the licence has it.
    public static func reflow(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var out = ""
        for (i, line) in lines.enumerated() {
            if i == 0 { out = line; continue }
            let prev = lines[i - 1].trimmingCharacters(in: .whitespaces)
            let next = line.trimmingCharacters(in: .whitespaces)
            if prev.count >= 50, !next.isEmpty, !startsBlock(next), !isRule(prev), !prev.hasPrefix("```") {
                out += " " + next
            } else {
                out += "\n" + line
            }
        }
        return out
    }

    /// A line that starts something of its own: a list item, heading, rule or fence.
    private static func startsBlock(_ line: String) -> Bool {
        if isRule(line) || line.hasPrefix("```") { return true }
        if let c = line.first, "*-•#=|+>".contains(c) { return true }
        // "1. ", "2) ", "(a) ", "a. "
        return line.wholeMatch(of: /(\d{1,2}|[a-z]|\([a-z0-9]{1,3}\))[.)]?\s.*/) != nil
            && line.prefix(5).contains(where: { ".)".contains($0) })
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { "=-_*".contains($0) }
    }
}

extension BundledData {
    public func acknowledgements() throws -> Acknowledgements {
        try decodeVersioned(File.acknowledgements, supported: Acknowledgements.supportedVersion)
    }
}
