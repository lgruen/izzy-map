import Foundation

/// The overlay key (legend): one list per overlay, sectioned by group, each
/// section's rows bracketed into runs that share one fill — as a printed
/// map key draws one box beside every code that shares a symbol
/// (docs/DESIGN.md §4 "The key as a printed map key").
public enum Legend {
    /// One code in the key.
    public struct Row: Sendable, Hashable, Identifiable {
        /// VEGCODE, SYMB or MVS number (string).
        public var code: String
        /// Display name without any "(XXX) " prefix.
        public var name: String
        /// Official fill, "#rrggbb".
        public var color: String
        public var id: String { code }
    }

    /// Consecutive rows that share one fill: one key box spans them.
    public struct Run: Sendable, Hashable, Identifiable {
        public var color: String
        public var rows: [Row]
        public var id: String { rows.first?.code ?? color }
    }

    /// One group (a section with an index label).
    public struct Section: Sendable, Hashable, Identifiable {
        /// The group's full name, as the data has it.
        public var title: String
        /// Curated short name for the section index.
        public var shortTitle: String
        public var runs: [Run]
        public var id: String { title }
        public var count: Int { runs.reduce(0) { $0 + $1.rows.count } }
    }

    // MARK: Curated short group names

    /// Geology groups (strat top levels) → index label. The web chips
    /// (chips.ts GEO_CHIPS), shortened to ≤ 10 characters: a native section
    /// index is a narrow column beside the list.
    public static let geologyShortNames: [String: String] = [
        "Proterozoic basement and parautochthonous rocks": "Proterozoic",
        "Early Cambrian Allochthonous sequences": "E. Cambrian",
        "Middle-Late Cambrian Volcanic and volcano-sedimentary sequences": "Volcanics",
        "Late Cambrian - Lower Devonian sedimentary sequences": "Camb–Dev",
        "Early Ordovician to Early Devonian turbidite sequence": "Turbidites",
        "Devonian - Carboniferous granitoids and related rocks": "Granites",
        "Devonian cavern fillings": "Caverns",
        "Late Carboniferous to Triassic sedimentary sequences": "Perm–Trias",
        "Jurassic igneous rocks": "Dolerite",
        "Cretaceous igneous rocks": "Cretaceous",
        "Undifferentiated Cenozoic sequences": "Recent",
        "Other units": "Other",
    ]

    /// NVIS Major Vegetation Groups → short name (web chips.ts PRE_CHIPS).
    /// (web chips.ts PRE_CHIPS, shortened to ≤ 10 characters for the index)
    public static let pre1750ShortNames: [String: String] = [
        "Rainforests and Vine Thickets": "Rainforest",
        "Eucalypt Tall Open Forests": "Tall euc.",
        "Eucalypt Open Forests": "Euc. forest",
        "Eucalypt Woodlands": "Euc. wdld",
        "Eucalypt Open Woodlands": "Open wdld",
        "Other Open Woodlands": "Other wdld",
        "Acacia Forests and Woodlands": "Acacia",
        "Callitris Forests and Woodlands": "Callitris",
        "Casuarina Forests and Woodlands": "Casuarina",
        "Melaleuca Forests and Woodlands": "Melaleuca",
        "Other Forests and Woodlands": "Other for.",
        "Mallee Woodlands and Shrublands": "Mallee",
        "Low Closed Forests and Tall Closed Shrublands": "Thickets",
        "Acacia Shrublands": "Acacia shr.",
        "Other Shrublands": "Shrubland",
        "Heathlands": "Heath",
        "Tussock Grasslands": "Tussock",
        "Other Grasslands, Herblands, Sedgelands and Rushlands": "Sedges",
        "Chenopod Shrublands, Samphire Shrublands and Forblands": "Saltmarsh",
        "Unclassified native vegetation": "Unclass.",
        "Naturally bare - sand, rock, claypan, mudflat": "Bare",
    ]

    /// The geology group that always sorts last.
    public static let otherGeologyGroup = "Other units"

    /// Short name, else a truncation (a group the curated table lacks — a
    /// unit test keeps the tables in step with the data).
    static func short(_ group: String, _ table: [String: String]) -> String {
        if let s = table[group] { return s }
        return group.count > 14 ? String(group.prefix(13)).trimmingCharacters(in: .whitespaces) + "…" : group
    }

    // MARK: Building

    /// TASVEG: each VEG_GROUP's codes share their first letter (D = dry
    /// eucalypt, W = wet, R = rainforest, A = saltmarsh and wetland …), so
    /// the letter is the index label and groups run A–Z by it, as the codes
    /// do on the official key. Inside a group, codes sharing a fill are
    /// brought together (ordered by their first code), then A–Z.
    public static func vegetation(_ table: CommunityTable) -> [Section] {
        let rows = table.map { code, c in Row(code: code, name: c.displayName, color: c.color.lowercased()) }
        let groups = Dictionary(grouping: rows) { table[$0.code]?.group ?? "" }
        return groups.map { g, members in
            let sorted = members.sorted { $0.code < $1.code }
            return Section(title: g, shortTitle: vegetationLetter(sorted.map(\.code)), runs: runsSharingFill(sorted))
        }
        .sorted { ($0.shortTitle, $0.title) < ($1.shortTitle, $1.title) }
    }

    /// The letter most of a group's codes start with.
    static func vegetationLetter(_ codes: [String]) -> String {
        let counts = Dictionary(grouping: codes.compactMap(\.first).map(String.init)) { $0 }.mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "?"
    }

    /// Geology: groups oldest → youngest by their oldest unit, "Other units"
    /// last; units by age (oldest first), then symbol.
    public static func geology(_ table: GeologyTable) -> [Section] {
        let groups = Dictionary(grouping: table.keys) { table[$0]!.group }
        func oldest(_ codes: [String]) -> Double { codes.compactMap { table[$0]?.maxMa }.max() ?? 0 }
        let order = groups.keys.sorted { a, b in
            if a == otherGeologyGroup { return false }
            if b == otherGeologyGroup { return true }
            let (oa, ob) = (oldest(groups[a]!), oldest(groups[b]!))
            return oa != ob ? oa > ob : a < b
        }
        return order.map { g in
            let codes = groups[g]!.sorted { a, b in
                let (ma, mb) = (table[a]!.maxMa ?? -1, table[b]!.maxMa ?? -1)
                return ma != mb ? ma > mb : a < b
            }
            let rows = codes.map { Row(code: $0, name: table[$0]!.description, color: table[$0]!.color.lowercased()) }
            return Section(title: g, shortTitle: short(g, geologyShortNames), runs: rows.map { Run(color: $0.color, rows: [$0]) })
        }
    }

    /// Pre-1750: NVIS group order (tallest → sparsest), classes by NVIS order.
    public static func pre1750(_ table: Pre1750Table) -> [Section] {
        let groups = Dictionary(grouping: table.keys) { table[$0]!.group }
        let order = groups.keys.sorted { a, b in
            let (ga, gb) = (table[groups[a]![0]]!.groupOrder, table[groups[b]![0]]!.groupOrder)
            return ga != gb ? ga < gb : a < b
        }
        return order.map { g in
            let codes = groups[g]!.sorted { table[$0]!.order < table[$1]!.order }
            let rows = codes.map { Row(code: $0, name: table[$0]!.name, color: table[$0]!.color.lowercased()) }
            return Section(title: g, shortTitle: short(g, pre1750ShortNames), runs: rows.map { Run(color: $0.color, rows: [$0]) })
        }
    }

    /// Reorders `rows` so codes sharing a fill sit together (each colour
    /// placed where its first row was), and brackets them into runs.
    static func runsSharingFill(_ rows: [Row]) -> [Run] {
        var order: [String] = []
        var byColor: [String: [Row]] = [:]
        for row in rows {
            if byColor[row.color] == nil { order.append(row.color) }
            byColor[row.color, default: []].append(row)
        }
        return order.map { Run(color: $0, rows: byColor[$0]!) }
    }
}

/// Map colours as the eye sees them.
public enum MapColour {
    /// `hex` ("#rrggbb") composited at `alpha` over white: what a fill at
    /// that opacity looks like on paper — the key box's colour, so the key
    /// matches the map (DESIGN.md "Key box colour = the map"). nil for a
    /// malformed hex.
    public static func overWhite(_ hex: String, alpha: Double) -> (red: Double, green: Double, blue: Double)? {
        guard let (r, g, b) = components(hex) else { return nil }
        let a = min(max(alpha, 0), 1)
        func mix(_ c: Double) -> Double { c * a + (1 - a) }
        return (mix(r), mix(g), mix(b))
    }

    /// "#rrggbb" → 0…1 components.
    public static func components(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" with 0…1 components (rounded).
    public static func hex(_ c: (red: Double, green: Double, blue: Double)) -> String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.red), byte(c.green), byte(c.blue))
    }
}
