import Foundation

/// Text rules of the offline search (ported from the web app's search.ts):
/// normalisation, abbreviations, street words, house numbers, number words,
/// distances. Everything here is pure and shared by index build and query.
public enum SearchText {
    // MARK: normalisation

    /// NFD → strip marks → lower → drop apostrophes → non-alphanumerics to
    /// single spaces → trim. Apostrophes vanish rather than split (both sides
    /// go through here): "obriens" finds O'Briens, "dentrecasteaux"
    /// D'Entrecasteaux. The result is ASCII `[a-z0-9 ]` only.
    public static func normalise(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return normaliseASCII(s.utf8) }
        // NFD, strip combining marks (\p{M}), THEN lowercase — the web order
        var stripped = String.UnicodeScalarView()
        for u in s.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: stripped.append(u)
            }
        }
        var out: [UInt8] = []
        var gap = false
        for u in String(stripped).lowercased().unicodeScalars {
            if u == "'" || u == "\u{2019}" { continue }
            let v = u.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                if gap && !out.isEmpty { out.append(0x20) }
                gap = false
                out.append(UInt8(v))
            } else {
                gap = true
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The same rules for pure-ASCII text (every name in the data files).
    static func normaliseASCII<C: Collection<UInt8>>(_ bytes: C) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var gap = false
        for var b in bytes {
            if b == 0x27 { continue } // '
            if b >= 0x41 && b <= 0x5A { b += 0x20 }
            if (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) {
                if gap && !out.isEmpty { out.append(0x20) }
                gap = false
                out.append(b)
            } else {
                gap = true
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Words of a normalised string.
    static func words(_ norm: String) -> [String] {
        norm.isEmpty ? [] : norm.split(separator: " ").map(String.init)
    }

    /// `words(normalise(s))`.
    public static func tokenise(_ s: String) -> [String] { words(normalise(s)) }

    // MARK: query vocabulary

    /// Query-side abbreviations. Prefix forms (st, ave, cres, pl, dr, esp, gr)
    /// need no entry: "st" prefix-matches "street" and exactly matches the
    /// "St" of "St Helens". Both the expansion and the literal are tried, so
    /// a typed "pt" still finds a name that really contains "Pt".
    public static let abbreviations: [String: String] = [
        "rd": "road", "mt": "mount", "ck": "creek", "crk": "creek", "pt": "point", "hwy": "highway",
        "ct": "court", "ln": "lane", "tce": "terrace", "blvd": "boulevard", "hts": "heights",
        "pde": "parade", "cct": "circuit", "sq": "square", "rv": "river", "pk": "peak", "trk": "track",
        "tk": "track", "hbr": "harbour", "lk": "lake", "nth": "north", "sth": "south", "saint": "st",
    ]

    /// The forms tried for one typed word: expansion first, then the literal.
    static func forms(_ t: String) -> [String] {
        if let x = abbreviations[t], x != t { return [x, t] }
        return [t]
    }

    /// Typing one of these means "I want the street": roads then compete on
    /// equal terms instead of ranking below the suburb/hill of the same name.
    public static let streetWords: Set<String> = [
        "street", "st", "road", "rd", "avenue", "ave", "av", "court", "ct", "crescent", "cres", "cr",
        "place", "pl", "drive", "dr", "lane", "ln", "terrace", "tce", "highway", "hwy", "parade", "pde",
        "circuit", "cct", "boulevard", "blvd", "close", "cl", "way", "esplanade", "esp", "grove", "gr",
        "rise", "square", "sq", "mews", "alley", "walk", "row", "loop", "link", "bypass", "promenade",
        "quay", "wharf", "freeway", "fwy",
    ]

    /// "7 mile beach" is Seven Mile Beach: a split-off house number is also
    /// tried spelt out (the numbers that start Tasmanian names). Keyed by the
    /// token exactly as typed ("07" and "15a" have no word).
    public static let numberWords: [String: String] = [
        "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven",
        "8": "eight", "9": "nine", "10": "ten", "11": "eleven", "12": "twelve", "13": "thirteen",
        "14": "fourteen", "15": "fifteen", "16": "sixteen", "17": "seventeen", "18": "eighteen",
        "19": "nineteen", "20": "twenty", "30": "thirty", "40": "forty", "50": "fifty",
    ]

    // MARK: house numbers

    /// `^\d+[a-z]?$` on a normalised token ("12", "15a").
    static func isHouseNumber(_ t: String) -> Bool {
        let u = Array(t.utf8)
        var i = 0
        while i < u.count, isDigit(u[i]) { i += 1 }
        if i == 0 { return false }
        if i == u.count { return true }
        return i == u.count - 1 && u[i] >= 0x61 && u[i] <= 0x7A
    }

    /// `^\d+$`.
    static func isBareNumber(_ t: String) -> Bool { !t.isEmpty && t.utf8.allSatisfy(isDigit) }

    /// JS `parseInt(s, 10)` for a house-number string: the leading digits
    /// ("15A" → 15); nil when there are none (NaN).
    static func leadingInt(_ s: String) -> Int? {
        var n = 0
        var any = false
        for b in s.utf8 {
            guard isDigit(b) else { break }
            n = n &* 10 &+ Int(b - 0x30)
            any = true
        }
        return any ? n : nil
    }

    /// "1/12 Smith St" → "12 Smith St" (unit / number), "2-4 Smith St" → "2
    /// Smith St" (range): on the raw text, because normalise() turns both
    /// separators into a space, after which the two forms cannot be told
    /// apart. Mirrors the web regexes
    /// `^\s*\d+[a-z]?\s*\/\s*(\d+[a-z]?)\b` → "$1" and then
    /// `^\s*(\d+[a-z]?)\s*[-–—]\s*\d+[a-z]?\b` → "$1" (case-insensitive).
    public static func stripUnitAndRange(_ q: String) -> String {
        var s = Array(q.unicodeScalars)
        // unit / number
        do {
            var i = skipSpace(s, 0)
            let d = skipDigits(s, i)
            if d > i {
                i = skipSpace(s, skipLetter(s, d))
                if i < s.count, s[i] == "/" {
                    let c = skipSpace(s, i + 1)
                    if let e = numberWithBoundary(s, c) { s.replaceSubrange(0..<e, with: s[c..<e]) }
                }
            }
        }
        // range
        do {
            let i0 = skipSpace(s, 0)
            let d = skipDigits(s, i0)
            if d > i0 {
                let capEnd = skipLetter(s, d)
                let b = skipSpace(s, capEnd)
                if b < s.count, s[b] == "-" || s[b] == "\u{2013}" || s[b] == "\u{2014}" {
                    let c = skipSpace(s, b + 1)
                    if let e = numberWithBoundary(s, c) { s.replaceSubrange(0..<e, with: s[i0..<capEnd]) }
                }
            }
        }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        return String(v)
    }

    /// A leading (or trailing) "12" / "15a" is a house number; two leading
    /// bare numbers ("1 12 …", also what "1/12" becomes after normalising)
    /// are unit then number. Returns the number, the remaining name words
    /// (any stray bare numbers dropped) and whether the number stood at the end.
    static func splitHouseNumber(_ tokens: [String]) -> (number: String?, rest: [String], atEnd: Bool) {
        var num: String?
        var rest = tokens
        var atEnd = false
        if tokens.count > 2, isBareNumber(tokens[0]), isHouseNumber(tokens[1]) {
            num = tokens[1]
            rest = Array(tokens.dropFirst(2))
        } else if tokens.count > 1, isHouseNumber(tokens[0]) {
            num = tokens[0]
            rest = Array(tokens.dropFirst())
        } else if tokens.count > 1, isHouseNumber(tokens[tokens.count - 1]) {
            num = tokens[tokens.count - 1]
            rest = Array(tokens.dropLast())
            atEnd = true
        }
        if num != nil { rest = rest.filter { !isBareNumber($0) } }
        if let num, !rest.isEmpty { return (num, rest, atEnd) }
        return (nil, tokens, atEnd)
    }

    // MARK: distance

    /// Equirectangular distance in km — plenty at Tasmanian scales.
    public static func km(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let dx = (lon2 - lon1) * cos((((lat1 + lat2) / 2) * Double.pi) / 180) * 111.32
        let dy = (lat2 - lat1) * 110.57
        return (dx * dx + dy * dy).squareRoot()
    }

    /// "50 m" … "950 m", "1.2 km" … "9.9 km", "12 km".
    public static func formatDistance(km: Double) -> String {
        if km < 0.95 { return "\(max(50, Int((km * 20).rounded()) * 50)) m" }
        if km < 10 {
            let tenths = Int((km * 10).rounded())
            return "\(tenths / 10).\(tenths % 10) km"
        }
        return "\(Int(km.rounded())) km"
    }

    // MARK: scanning helpers (ASCII classes, like the JS regexes)

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private static func isDigit(_ u: Unicode.Scalar) -> Bool { u.value >= 0x30 && u.value <= 0x39 }
    private static func isLetter(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A)
    }
    private static func isWord(_ u: Unicode.Scalar) -> Bool { isDigit(u) || isLetter(u) || u == "_" }
    /// JS `\s`: Unicode white space plus the BOM.
    private static func isSpace(_ u: Unicode.Scalar) -> Bool { u.properties.isWhitespace || u == "\u{FEFF}" }
    private static func skipSpace(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        var i = i
        while i < s.count, isSpace(s[i]) { i += 1 }
        return i
    }
    private static func skipDigits(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        var i = i
        while i < s.count, isDigit(s[i]) { i += 1 }
        return i
    }
    private static func skipLetter(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        i < s.count && isLetter(s[i]) ? i + 1 : i
    }
    /// `\d+[a-z]?\b` at `i`: the end index, or nil. Backtracking never finds
    /// a shorter match (a dropped letter or digit is itself a word character).
    private static func numberWithBoundary(_ s: [Unicode.Scalar], _ i: Int) -> Int? {
        let d = skipDigits(s, i)
        guard d > i else { return nil }
        let e = skipLetter(s, d)
        return e == s.count || !isWord(s[e]) ? e : nil
    }
}
