import Foundation

/// Typesets names of living things the taxonomist's way (docs/DESIGN.md
/// §2 Typography): genus and epithets italic; rank words (subsp., var., f.,
/// sp., spp., aff.), the hybrid sign × and everything else upright.
///
/// Output marks italic runs with `inlinePresentationIntent = .emphasized`,
/// which SwiftUI's `Text` draws as italic in whatever font it has (New York
/// for names). Map text never goes through this — it stays Latin-1 plain.
public enum BotanicalNames {
    /// Genera that occur in the TASVEG 5.0 and NVIS pre-1750 class names.
    /// A unit test keeps it in step with the bundled tables (every
    /// capitalised word of those names that is a genus in plants.json must
    /// be here; every entry must occur in a name).
    public static let mapGenera: Set<String> = [
        "Acacia", "Allocasuarina", "Atherosperma", "Athrotaxis", "Banksia", "Bursaria",
        "Callitris", "Casuarina", "Diplarrena", "Eucalyptus", "Kunzea", "Lagarostrobos",
        "Leptospermum", "Melaleuca", "Nothofagus", "Phyllocladus", "Poa", "Pteridium",
        "Spartina", "Sphagnum", "Themeda",
    ]

    /// Upright rank words (compared on the word without trailing commas,
    /// lowercased). "var" without its full stop occurs in the register.
    static let rankWords: Set<String> = [
        "subsp.", "ssp.", "var.", "var", "f.", "sp.", "spp.", "aff.", "cf.", "nothosubsp.", "agg.", "×", "x",
    ]
    /// Upright joiners between two names ("Cedrus libani and Cupressus …").
    static let joiners: Set<String> = ["and", "&", "or", "with"]

    /// Words that follow a genus in the community names but are not
    /// epithets ("Eucalyptus *amygdalina* coastal forest", "*Leptospermum*
    /// forest", "Other *Acacia* forests").
    static let notEpithets: Set<String> = [
        "and", "coastal", "damp", "dry", "fernland", "forest", "forests", "grassland", "grassy",
        "heathland", "heathy", "inland", "low", "marshland", "on", "open", "or", "over", "peatland",
        "rainforest", "regrowth", "rushland", "scrub", "short", "shrublands", "subalpine", "swamp",
        "tall", "wet", "with", "woodland", "woodlands",
    ]

    /// A word split into leading punctuation, its letters and trailing
    /// punctuation: "(Banksia)," → "(", "Banksia", "),". Only the core of a
    /// name is ever italic; brackets and commas stay upright.
    struct Token {
        var lead: Substring, core: Substring, trail: Substring

        init(_ word: Substring) {
            let isPunct: (Character) -> Bool = { "([{\"'‘’“”,;:)]}".contains($0) }
            let start = word.firstIndex { !isPunct($0) } ?? word.endIndex
            var end = word.endIndex
            while end > start, isPunct(word[word.index(before: end)]) { end = word.index(before: end) }
            lead = word[word.startIndex ..< start]
            core = word[start ..< end]
            trail = word[end ..< word.endIndex]
        }
    }

    /// `name` with genus/epithet runs italic. " - " between two taxa becomes
    /// a closed-up en dash ("*Nothofagus*–*Atherosperma* rainforest");
    /// any other " - " a spaced en dash. Punctuation around a genus
    /// ("Acacia,", "(Banksia)") doesn't hide it and stays upright.
    public static func attributed(_ name: String, genera: Set<String> = mapGenera) -> AttributedString {
        let words = name.split(separator: " ", omittingEmptySubsequences: false)
        let tokens = words.map(Token.init)
        // italic flags per word
        var italic = [Bool](repeating: false, count: words.count)
        var i = 0
        while i < words.count {
            if genera.contains(String(tokens[i].core)) {
                italic[i] = true
                // the epithet must follow directly (no comma or bracket between)
                if tokens[i].trail.isEmpty, i + 1 < words.count, tokens[i + 1].lead.isEmpty,
                   isEpithet(String(tokens[i + 1].core)) {
                    italic[i + 1] = true
                    i += 1
                }
            }
            i += 1
        }
        var out = AttributedString()
        var k = 0
        while k < words.count {
            let w = words[k]
            if w == "-", k > 0, k + 1 < words.count {
                // a dash between two taxa closes up; otherwise spaced en dash
                let closed = italic[k - 1] && italic[k + 1] && tokens[k - 1].trail.isEmpty && tokens[k + 1].lead.isEmpty
                out.append(AttributedString(closed ? "–" : " – "))
                k += 1
                continue
            }
            if k > 0, words[k - 1] != "-" { out.append(AttributedString(" ")) }
            append(tokens[k], italic: italic[k], to: &out)
            k += 1
        }
        return out
    }

    /// A plant's full botanical name ("Quercus robur", "Ulmus × hollandica
    /// 'Vegeta'", "Eucalyptus globulus subsp. globulus") the taxonomist's
    /// way: names italic; upright are rank words, the hybrid sign, joiners
    /// ("A and B"), cultivar names (in quotes, or after "cv."), anything
    /// parenthesised, and informal phrase names after a rank word ("Acacia
    /// sp. Sugarloaf", "Euphrasia gibbsiae subsp. Mt Anne"). A single
    /// capitalised Latin-looking epithet after a rank is an upstream
    /// capital, not a phrase name ("subsp. Oxycarpa"): italic.
    public static func species(_ name: String) -> AttributedString {
        var out = AttributedString()
        let words = name.split(separator: " ")
        var inQuote = false, inParens = false, phrase = false, cultivar = false
        var afterRank = false
        for (i, word) in words.enumerated() {
            if i > 0 { out.append(AttributedString(" ")) }
            let t = Token(word)
            let opensQuote = t.lead.contains { "'‘\"“".contains($0) }
            if opensQuote { inQuote = true }
            if t.lead.contains("(") { inParens = true }
            let lowered = t.core.lowercased()
            let isRank = rankWords.contains(lowered) || rankWords.contains(lowered + ".")
            let isJoiner = joiners.contains(lowered)
            if isJoiner { phrase = false; cultivar = false }
            if afterRank, !isRank, !inQuote, !inParens {
                // the first word after a rank decides: an informal phrase name
                // starts with a capital or digit and runs to the end
                let rest = words[(i + 1)...].map { Token($0) }
                let restIsPlain = rest.allSatisfy { $0.lead.isEmpty && $0.core.first?.isLetter == true }
                if let first = t.core.first, first.isUppercase || first.isNumber,
                   !(isLatinEpithet(t.core) && (rest.isEmpty || !restIsPlain)) {
                    phrase = true
                }
            }
            afterRank = isRank
            if lowered == "cv." { cultivar = true }
            let upright = inQuote || inParens || phrase || cultivar || isRank || isJoiner || lowered == "cv."
                || t.core.first?.isLetter != true
            append(t, italic: !upright, to: &out)
            if t.trail.contains(where: { "'’\"”".contains($0) }), !(opensQuote && t.core.isEmpty) { inQuote = false }
            if t.trail.contains(")") { inParens = false }
        }
        return out
    }

    /// The italic runs of an attributed name, for tests and accessibility checks.
    public static func italicRuns(_ s: AttributedString) -> [String] {
        s.runs.compactMap { run in
            run.inlinePresentationIntent == .emphasized ? String(s[run.range].characters) : nil
        }
    }

    /// The italic words of a community/class `name`.
    public static func italicWords(_ name: String, genera: Set<String> = mapGenera) -> [String] {
        italicRuns(attributed(name, genera: genera))
    }

    private static func append(_ t: Token, italic: Bool, to out: inout AttributedString) {
        if !t.lead.isEmpty { out.append(AttributedString(String(t.lead))) }
        var run = AttributedString(String(t.core))
        if italic, !t.core.isEmpty { run.inlinePresentationIntent = .emphasized }
        out.append(run)
        if !t.trail.isEmpty { out.append(AttributedString(String(t.trail))) }
    }

    /// A word with a Latin epithet's ending ("Intermedium", "Oxycarpa",
    /// "Glauca"), as opposed to a place or descriptive phrase-name word
    /// ("Sugarloaf", "Quartzite", "Mt").
    static func isLatinEpithet(_ word: Substring) -> Bool {
        let w = word.lowercased()
        guard w.count >= 4, w.allSatisfy({ $0.isLetter || $0 == "-" }) else { return false }
        return ["um", "us", "a", "is", "ae", "ii", "i", "ensis", "oides", "es", "ex", "ens", "ans", "or"]
            .contains { w.hasSuffix($0) }
    }

    static func isEpithet(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
              word.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) || $0 == "-" })
        else { return false }
        return !rankWords.contains(word) && !notEpithets.contains(word)
    }
}
