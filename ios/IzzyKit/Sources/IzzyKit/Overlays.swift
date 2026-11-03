import Foundation

// The three overlay tables (TASVEG communities, geology units, pre-1750
// classes) and the F2F page index. None of these files carries a `version`
// field: they are plain keyed tables, decoded strictly (a missing field
// fails loudly) and bundled with the code that reads them.

/// A TASVEG 5.0 community, keyed by VEGCODE (official QML colours).
public struct Community: Codable, Sendable, Hashable {
    /// "(AAP) Alkaline pans" — the official name, code prefix included.
    public var name: String
    public var group: String
    public var color: String
    public var outline: String
    /// Map label text (Latin-1).
    public var label: String

    /// The name without its "(XXX) " code prefix (the card's chip already shows the code).
    public var displayName: String { Community.stripCodePrefix(name) }

    /// Strips a leading "(XXX) " (three capitals) — also for a tile's VEGCODE_D.
    public static func stripCodePrefix(_ name: String) -> String {
        name.replacing(/^\([A-Z]{3}\)\s*/, with: "", maxReplacements: 1)
    }
}
/// VEGCODE → community.
public typealias CommunityTable = [String: Community]

/// A 1:500,000 MRT geology unit, keyed by SYMB.
public struct GeologyUnit: Codable, Sendable, Hashable {
    /// Plain-English lithology sentence (the card's headline).
    public var description: String
    public var group: String
    /// ">"-separated stratigraphic hierarchy.
    public var strat: String
    public var maxAge: String
    public var minAge: String
    /// Oldest/youngest age in millions of years; nil when unknown.
    public var maxMa: Double?
    public var minMa: Double?
    public var color: String
    /// Geoscience Australia ASUD page, "" when none.
    public var link: String

    /// The card's "Age" row ("" when unknown).
    public func ageText(locale: Locale = .current) -> String {
        GeologyUnit.formatAge(maxMa: maxMa, minMa: minMa, locale: locale)
    }

    /// Plain-English age for a lay reader: numbers first, no stage jargon
    /// ("About 180 million years old", "Geologically recent (roughly the
    /// last 12,000 years)", "About 501–458 million years old"). Whole
    /// millions from 10 Ma up, one decimal below; halves round away from
    /// zero, on the number as written (2.25 → "2.3"). Digits follow
    /// `locale` — see `ProseNumbers`.
    public static func formatAge(maxMa: Double?, minMa: Double?, locale: Locale = .current) -> String {
        guard let maxMa else { return "" }
        func fmt(_ ma: Double) -> String {
            ma.formatted(.number.precision(.fractionLength(ma >= 10 ? 0 : 1))
                .rounded(rule: .toNearestOrAwayFromZero).locale(locale))
        }
        if maxMa < 0.02 { return "Geologically recent (roughly the last 12,000 years)" }
        let hi = fmt(maxMa)
        guard let minMa, fmt(minMa) != hi else { return "About \(hi) million years old" }
        if minMa < 0.02 { return "About \(hi) million years ago – recent" }
        return "About \(hi)–\(fmt(minMa)) million years old"
    }
}
/// SYMB → geology unit.
public typealias GeologyTable = [String: GeologyUnit]

/// An NVIS pre-1750 Major Vegetation Subgroup, keyed by MVS number (as a string).
public struct Pre1750Unit: Codable, Sendable, Hashable {
    public var name: String
    public var group: String
    /// Lower-case gloss of the group ("tall eucalypt forests (trees taller than 30 m)").
    public var groupDesc: String
    public var color: String
    public var order: Int
    public var groupOrder: Int
    /// Estimated pre-1750 extent in Tasmania, in 1 ha cells.
    public var ha: Int

    /// The card's "Pre-1750 extent" row.
    public func extentText(locale: Locale = .current) -> String {
        Pre1750Unit.formatExtent(hectares: ha, locale: locale)
    }

    /// "~7,684 km² statewide", or "70 ha statewide" under 100 ha — a tiny
    /// class never reads "0 km²". Halves round up (150 ha → "~2 km²");
    /// digits follow `locale` — see `ProseNumbers`.
    public static func formatExtent(hectares ha: Int, locale: Locale = .current) -> String {
        if ha < 100 { return "\(ha.formatted(.number.locale(locale))) ha statewide" }
        let km2 = (Double(ha) / 100).formatted(.number.precision(.fractionLength(0))
            .rounded(rule: .toNearestOrAwayFromZero).locale(locale))
        return "~\(km2) km² statewide"
    }
}
/// MVS number (string) → pre-1750 class.
public typealias Pre1750Table = [String: Pre1750Unit]

/// Where each community's account starts in the From Forest to Fjaeldmark chapters.
public struct F2FIndex: Codable, Sendable, Hashable {
    /// One community's chapter PDF and the 0-based index of the page its
    /// account starts on (PDFKit's `page(at:)`; the reader shows it + 1).
    public struct Entry: Codable, Sendable, Hashable {
        public var file: String
        public var page: Int
    }
    /// "https://nre.tas.gov.au/Documents/"
    public var baseUrl: String
    /// VEGCODE → entry.
    public var index: [String: Entry]
    /// Chapter file → byte size (pipeline/build_f2f_index.py, checked
    /// against the server's Content-Length). Optional: added later, the
    /// file carries no version, so older copies decode without it.
    public var sizes: [String: Int]?

    /// The chapter's download URL and page for a community, if indexed.
    public func location(for code: String) -> (url: URL, page: Int)? {
        guard let e = index[code], let url = URL(string: baseUrl + e.file) else { return nil }
        return (url, e.page)
    }
    /// Every chapter file, sorted (the download set).
    public var chapterFiles: [String] { Set(index.values.map(\.file)).sorted() }
}

/// Map label text must stay inside the shipped glyph range.
public enum MapText {
    /// True when every scalar is in U+0000–U+00FF: the map's glyphs ship as
    /// `0-255.pbf` only, and a character outside it makes the renderer ask
    /// for a glyph range that does not exist — the label silently fails offline.
    /// ("×" is U+00D7 and fine; curly quotes and dashes are not.) Tree
    /// botanical names and plant titles are verbatim upstream text — UI only.
    public static func isLatin1(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value <= 0xFF }
    }
}
