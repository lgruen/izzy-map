import Foundation

/// A plant's growth form: the Understorey Network's `forms` vocabulary
/// (plants.json, 2026-10 pull: Herb 544, Shrub 492, Orchid 209, Grass 140,
/// Sedge 119, Fern 102, Tree 55, Rush 48, Groundcover 35, Climber 22).
/// The app draws one pictogram per case — the photo fallback in lists.
public enum GrowthForm: String, CaseIterable, Sendable, Hashable {
    case tree, shrub, herb, grass, sedge, rush, fern, orchid, groundcover, climber

    /// UN's form word ("Tree", "Groundcover"); nil for anything new.
    public init?(un word: String) {
        self.init(rawValue: word.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Sentence-case name (VoiceOver label, captions).
    public var title: String {
        switch self {
        case .groundcover: "Groundcover"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// A height range in metres. UN's `height` field is "0.3 – 1" in the
/// 2026-10 pull (986 of 1,884 plants; the rest have none); the parser also
/// takes what a hand-edited or future pull may hold — a hyphen or "to"
/// between the figures, "to 2 m" / "up to 2 m", units (m, cm, mm) after
/// either figure, a decimal comma — and rejects anything else (prose,
/// zero, three figures) rather than guess.
public struct HeightRange: Sendable, Hashable {
    public var min: Double
    public var max: Double
    /// Only a maximum is known ("to 2 m"): no minimum to draw.
    public var upTo: Bool

    public init(min: Double, max: Double, upTo: Bool = false) {
        self.min = Swift.min(min, max)
        self.max = Swift.max(min, max)
        self.upTo = upTo
    }

    public init?(_ text: String?) {
        guard let text, let parsed = Self.parse(text) else { return nil }
        self = parsed
    }

    /// A height stated in descriptive prose — only "to 15 cm high" / "to
    /// 5–6 m tall" forms: a figure in UN's prose is as often a leaf's
    /// length or a cushion's diameter ("to 1 m in diameter"), so without
    /// "tall"/"high" it is not a height.
    public init?(prose: String?) {
        guard let prose else { return nil }
        let pattern = /(?i)\b(?:to|up to|reaching|grows to)\s+(\d+(?:[.,]\d+)?)(?:\s*(?:-|–|to)\s*(\d+(?:[.,]\d+)?))?\s*(m|cm|mm)\s+(?:tall|high)\b/
        guard let m = prose.firstMatch(of: pattern) else { return nil }
        let unit = Self.unit(String(m.3))
        guard let a = Self.number(String(m.1)) else { return nil }
        if let b = m.2.flatMap({ Self.number(String($0)) }) {
            guard a > 0, b > 0 else { return nil }
            self.init(min: a * unit, max: b * unit)
        } else {
            guard a > 0 else { return nil }
            self.init(min: a * unit, max: a * unit, upTo: true)
        }
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    private static func unit(_ s: String) -> Double {
        switch s.lowercased() {
        case "cm": 0.01
        case "mm": 0.001
        default: 1
        }
    }

    static func parse(_ raw: String) -> HeightRange? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        var upTo = false
        for prefix in ["up to ", "to ", "<"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            upTo = true
            break
        }
        // "a – b", "a-b", "a to b"; a unit after either figure
        let pattern = /^(\d+(?:[.,]\d+)?)\s*(m|cm|mm)?(?:\s*(?:–|—|-|to)\s*(\d+(?:[.,]\d+)?)\s*(m|cm|mm)?)?\s*(?:tall|high)?$/
        guard let m = s.wholeMatch(of: pattern), let a = number(String(m.1)) else { return nil }
        let b = m.3.flatMap { number(String($0)) }
        if upTo, b != nil { return nil }
        // a bare first figure takes the second's unit ("30–60 cm")
        let unitB = unit(String(m.4 ?? m.2 ?? "m"))
        let unitA = m.2.map { unit(String($0)) } ?? unitB
        let lo = a * unitA, hi = (b ?? a) * unitB
        guard lo > 0, hi > 0, lo.isFinite, hi.isFinite, hi < 200 else { return nil }
        return HeightRange(min: lo, max: hi, upTo: upTo)
    }

    /// "2–3 m", "0.3–1 m", "5 m", "1–3 cm", "to 2 m" (closed-up en dash,
    /// no-break space). Below a metre in centimetres.
    public var text: String {
        let cm = max < 1
        func f(_ v: Double) -> String {
            let x = cm ? (v * 100 * 10).rounded() / 10 : v
            return x == x.rounded() ? String(Int(x)) : String(format: "%g", x)
        }
        let unit = cm ? "\u{00A0}cm" : "\u{00A0}m"
        if upTo { return "to " + f(max) + unit }
        return (min == max ? f(max) : "\(f(min))–\(f(max))") + unit
    }

    /// One figure with its unit, for a dimension label ("15 m", "30 cm").
    public static func label(_ metres: Double) -> String {
        HeightRange(min: metres, max: metres).text
    }
}

/// How a plant is drawn: its growth form, refined where the data says
/// more — the elevation's silhouette and the list pictogram share it.
/// Trees: a eucalypt's clear bole and open, lumpy crown (Eucalyptus), the
/// conical crown of the Tasmanian conifers, else a dense broadleaf crown
/// (rainforest, wattles). Tree ferns (Dicksonia, Cyathea) and pandani
/// (Richea pandanifolia, a "tree" of strap leaves on a trunk) share the
/// trunk-and-rosette shape. Cushion plants and prostrate mats are told
/// from the form prose.
public enum PlantSilhouette: String, CaseIterable, Sendable, Hashable {
    case eucalypt, broadleafTree, conifer, treeFern
    case shrub, herb, cushion, mat, grass, sedge, rush, fern, orchid, climber
    /// No form recorded.
    case plant

    static let conifers: Set<String> = ["Athrotaxis", "Lagarostrobos", "Phyllocladus", "Callitris", "Podocarpus",
                                        "Diselma", "Microcachrys", "Microstrobos", "Pherosphaera"]
    static let treeFerns: Set<String> = ["Dicksonia", "Cyathea"]

    public init(form: GrowthForm?, name: String, description: String? = nil) {
        let genus = name.split(separator: " ").first.map(String.init) ?? ""
        let prose = (description ?? "").lowercased()
        let cushiony = prose.contains("cushion")
        let matty = prose.contains("prostrate") || prose.contains("mat-forming") || prose.contains("mat forming")
            || prose.contains("forming mats") || prose.contains("forms mats")
        switch form {
        case .tree:
            if genus == "Eucalyptus" || genus == "Corymbia" { self = .eucalypt }
            else if Self.conifers.contains(genus) { self = .conifer }
            else if genus == "Richea" { self = .treeFern }
            else { self = .broadleafTree }
        case .fern: self = Self.treeFerns.contains(genus) ? .treeFern : .fern
        case .shrub:
            // a conifer shrub is still a shrub; a cushion-forming one is a cushion
            self = cushiony ? .cushion : .shrub
        case .herb: self = cushiony ? .cushion : (matty ? .mat : .herb)
        case .groundcover: self = cushiony ? .cushion : .mat
        case .grass: self = .grass
        case .sedge: self = cushiony ? .cushion : .sedge
        case .rush: self = .rush
        case .orchid: self = .orchid
        case .climber: self = .climber
        case nil: self = .plant
        }
    }
}

/// The scale of a plant's elevation drawing: a standard architectural
/// ratio from a ladder, the largest at which the plant's maximum height
/// still fits the plot (≤ 80 % of its height).
///
/// A ratio on a screen needs a stated sheet: here 1 pt ≙ 2 mm (so 1:100
/// draws a metre as 5 pt). Ratios between drawings are exact; the scale
/// bar under each drawing is the measure. A fixed sheet with the ratios a
/// landscape architect knows (1:5 … 1:500) can't span a 1 cm herb and a
/// 90 m mountain ash in one 140 pt plot, so the ladder runs on to 1:2,
/// 1:1 and 2:1 — the enlargements of a botanical detail.
public struct ElevationScale: Sendable, Hashable {
    /// N of "1:N" (0.5 = 2:1).
    public var denominator: Double

    /// The sheet: points per metre at 1:1.
    public static let pointsPerMetreFullSize = 500.0
    public static let ladder: [Double] = [0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500]
    /// Share of the plot the tallest plant may fill.
    public static let fill = 0.8
    /// The scale figure's height, metres.
    public static let person = 1.7
    /// A boot's height, metres: the scale figure at the enlarged scales.
    public static let boot = 0.3

    public init(denominator: Double) { self.denominator = denominator }

    /// The largest ladder scale at which `maxHeight` fits `plotHeight`
    /// points (the smallest scale, 1:500, for anything taller).
    public static func choose(maxHeight: Double, plotHeight: Double) -> ElevationScale {
        let room = plotHeight * fill
        for n in ladder where maxHeight * pointsPerMetreFullSize / n <= room {
            return ElevationScale(denominator: n)
        }
        return ElevationScale(denominator: ladder.last!)
    }

    public var pointsPerMetre: Double { Self.pointsPerMetreFullSize / denominator }

    /// "1:200", "2:1".
    public var label: String {
        denominator < 1 ? "\(Int((1 / denominator).rounded())):1" : "1:\(Int(denominator))"
    }

    /// The whole 1.7 m figure fits under the plot's top (else a boot).
    public func showsFigure(plotHeight: Double) -> Bool {
        Self.person * pointsPerMetre <= plotHeight * 0.95
    }

    /// Faint level lines every this many metres (tall trees, where the
    /// figure is a speck), nil for none.
    public var levelInterval: Double? {
        denominator >= 500 ? 10 : denominator >= 200 ? 5 : nil
    }

    /// A scale bar at most `maxPoints` long: total length (metres) on the
    /// 1–2–5 ladder, its segment count and the figures to print under it.
    public func scaleBar(maxPoints: Double) -> (metres: Double, segments: Int, labels: [Double]) {
        var best = 0.001
        var exponent = -3
        outer: while exponent <= 3 {
            for d in [1.0, 2, 5] {
                let v = d * pow(10, Double(exponent))
                if v * pointsPerMetre > maxPoints { break outer }
                best = v
            }
            exponent += 1
        }
        let lead = (best / pow(10, floor(log10(best)) )).rounded()
        if lead == 5 { return (best, 5, [0, best]) }
        return (best, 2, [0, best / 2, best])
    }
}

/// UN's conservation status words (the Tasmanian Threatened Species
/// Protection Act schedules): rare, vulnerable, endangered.
public enum PlantStatus: String, Sendable, Hashable {
    case rare = "Rare", vulnerable = "Vulnerable", endangered = "Endangered"
}

/// The flowering chart's month order.
public enum Flowering {
    /// First month of the bloom chart: January — decided by the user
    /// (2026-11-03, DESIGN.md §7 q2) over the proposed spring-first
    /// September start. The ONE place to change it; a season-aligned start
    /// (3, 6, 9, 12) brings back the season words under the chart.
    public static let startMonth = 1

    /// The twelve months in chart order (1-based month numbers).
    public static func order(start: Int = startMonth) -> [Int] {
        (0 ..< 12).map { (start - 1 + $0) % 12 + 1 }
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]

    /// One-letter month labels, "J F M …".
    public static func initial(_ month: Int) -> String { String(monthNames[(month - 1) % 12].prefix(1)) }
    public static func name(_ month: Int) -> String { monthNames[(month - 1) % 12] }

    /// Contiguous runs of flowering months in chart order, e.g. [[9, 10, 11], [2]].
    public static func runs(_ months: [Int], start: Int = startMonth) -> [[Int]] {
        let on = Set(months)
        guard on.count < 12 else { return [order(start: start)] }
        // start each run after an off month, wrapping through the year
        var runs: [[Int]] = []
        var current: [Int] = []
        for m in order(start: start) {
            if on.contains(m) { current.append(m) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty {
            // a run reaching the chart's end continues into its start (Aug → Sep)
            if let first = runs.first, first.first == order(start: start).first, on.contains(order(start: start).last!) {
                runs[0] = current + first
            } else {
                runs.append(current)
            }
        }
        return runs
    }

    /// "Flowers September to November and in February", "Flowers all year",
    /// plus ", in flower now" when `now` is a flowering month.
    public static func spoken(_ months: [Int], now: Int? = nil, start: Int = startMonth) -> String {
        guard !months.isEmpty else { return "No flowering months recorded" }
        let parts = runs(months, start: start).map { run in
            run.count == 1 ? name(run[0]) : "\(name(run.first!)) to \(name(run.last!))"
        }
        var s = Set(months).count == 12 ? "Flowers all year"
            : "Flowers " + (parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!)
        if let now, months.contains(now) { s += ", in flower now" }
        return s
    }
}

/// Common names are lowercase in the Understorey Network data, the
/// Tasmanian convention ("christmas bells"), and list rows keep them so; a
/// common name standing as a HEADLINE (a sheet's title, the plant-ID
/// answer, a navigation title) gets its first letter up: "Christmas bells".
public enum CommonName {
    /// nil for an empty name.
    public static func headline(_ name: String) -> String? {
        guard let first = name.first else { return nil }
        return first.uppercased() + name.dropFirst()
    }
}

extension PlantCatalog.Group {
    /// The group's common name as a headline (`CommonName.headline`).
    public var headlineCommon: String? { common.flatMap(CommonName.headline) }
}

extension Plant {
    /// Growth forms in UN order (unknown words dropped).
    public var growthForms: [GrowthForm] { forms.compactMap(GrowthForm.init(un:)) }
    /// The form that picks the pictogram.
    public var primaryForm: GrowthForm? { growthForms.first }
    /// The `height` field, else a "to 15 cm high" in the form prose.
    public var heightRange: HeightRange? { HeightRange(height) ?? HeightRange(prose: form) }
    /// The shape the elevation and the pictogram draw.
    public var silhouette: PlantSilhouette { PlantSilhouette(form: primaryForm, name: name, description: form) }
    public var conservationStatus: PlantStatus? { status.flatMap(PlantStatus.init(rawValue:)) }

    /// The common name as a headline ("Christmas bells"); list rows keep
    /// UN's lowercase (`CommonName.headline`).
    public var headlineCommon: String? { common.flatMap(CommonName.headline) }

    /// "common · Tree, Shrub" for a list row's second line.
    public var subline: String {
        [common ?? "", forms.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The profile page on the Understorey Network site.
    public var profileURL: URL? {
        URL(string: "\(PlantPhoto.siteBase)/plant/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")
    }
}

extension PlantPhoto {
    /// The Understorey Network site.
    public static let siteBase = "https://database.understorey-network.org.au"
    /// Host photos are served from (and the only host a fetch may end on).
    public static let host = "database.understorey-network.org.au"

    /// The 150 px square thumbnail, if WordPress made one.
    public var thumbURL: URL? { thumb.flatMap { url(suffix: $0) } }
    /// The large version (≤ 768 px wide, or the original).
    public var largeURL: URL? { url(suffix: large) }

    private func url(suffix: String) -> URL? {
        URL(string: "\(Self.siteBase)/wp-content/uploads/\(path)\(suffix).\(ext)")
    }

    /// The stored file's name: the path without the size suffix, "/" → "-"
    /// ("2024-03-Acacia_dealbata-flower.jpg"), so a re-sized large version
    /// is still the same photo and one directory listing answers "what's
    /// on the device".
    public var storedName: String { path.replacingOccurrences(of: "/", with: "-") + "." + ext }

    /// The caption under every photo (credits are mandatory).
    public var caption: String {
        "Photo: " + (credit.map { "\($0) · " } ?? "") + "Understorey Network"
    }
}

/// Credit lines shown with the plant lists and sheets (inventory §4).
public enum PlantCredits {
    public static let plants = "Plant profiles & photos: Understorey Network Tasmania (photos © their photographers)"
    public static let records = "Occurrence records: Atlas of Living Australia (incl. TNVA, iNaturalist Australia, AVH)"
    public static let named = "“Named” lists from From Forest to Fjaeldmark."
}
