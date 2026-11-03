import Foundation

/// Display-side wording for upstream data: the tables keep the publisher's
/// text verbatim (credits, VoiceOver's "official form", future pipeline
/// diffs); the card and the key show it corrected and in plain language.
enum DisplayText {
    // MARK: Known upstream typos

    /// Editorial corrections for typos in the published datasets, applied
    /// to whole words wherever a name is shown. Keep each entry documented
    /// with its source; the raw table keeps the official form.
    ///
    /// - "rushs": NVIS V7.0 MVS 21 is published as "Sedgelands, rushs or
    ///   reeds" (DCCEEW's own spelling, also in its MapServer legend).
    static let corrections: [String: String] = [
        "rushs": "rushes",
    ]

    /// `text` with every known upstream typo corrected (whole words only).
    static func corrected(_ text: String) -> String {
        var result = text
        for (wrong, right) in corrections where result.localizedCaseInsensitiveContains(wrong) {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
                with: right, options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: Geology unit titles

    /// Abbreviations whose full stop belongs to the word, not the sentence.
    private static let abbreviations: Set<String> = ["etc.", "sp.", "spp.", "var.", "subsp.", "approx.", "incl."]

    /// MRT's unit descriptions are sentences ("…conglomerate in places.");
    /// as a title, a name, they lose the closing full stop.
    static func unitTitle(_ description: String) -> String {
        let trimmed = corrected(description.trimmingCharacters(in: .whitespacesAndNewlines))
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return trimmed }
        if let last = trimmed.split(separator: " ").last, abbreviations.contains(last.lowercased()) {
            return trimmed
        }
        return String(trimmed.dropLast())
    }

    // MARK: Tree position accuracy

    /// The City of Hobart's position-accuracy domain (`Session_Key`, trees.json
    /// `accuracy`) as she'd say it: how the tree's dot was placed. nil hides
    /// the row ("unknown" says nothing).
    static func treePosition(code: String?) -> String? {
        switch code {
        case "sk": "Approximate (sketched)"
        case "ft": "Surveyed on site"
        case "co": "Surveyed"
        case "ug": "Hand-held GPS"
        case "dp", "os": "From a 1:528 plan"
        case "tm": "From a 1:2,000 map"
        case "fm": "From a 1:5,000 map"
        case "pm": "From a 1:10,000 map"
        case "tf": "From a 1:25,000 map"
        case "hc": "Compiled by the council"
        case "hv": "Checked by the council"
        default: nil
        }
    }
}
