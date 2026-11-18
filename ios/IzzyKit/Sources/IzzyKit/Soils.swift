import Foundation

/// LIST's Correlated Reconnaissance Soils (soil_units.json, pipeline/build_soils.py):
/// 163 soil units over 11 reconnaissance map sheets (≈ 17 % of Tasmania),
/// their Australian Soil Classification orders and the sheets' reports.
///
/// Unit codes are CASE-SENSITIVE: `BL` (brown soils on limestone) and `Bl`
/// (Blessington Association) are different units. Keys stay exactly as
/// published — never fold, upper- or small-cap them.
public struct SoilsFile: Decodable, Sendable, Hashable, Versioned {
    public static let supportedVersion = 1

    public var version: Int
    public var source: Source
    /// CODE → unit.
    public var units: [String: Unit]
    /// Sheet key ("hobart", "south-esk") → map sheet.
    public var sheets: [String: Sheet]
    /// Order name ("Ferrosol") → its plain-English gloss.
    public var orders: [String: Order]

    public struct Source: Decodable, Sendable, Hashable {
        public var title: String
        public var custodian: String
        public var licence: String
        /// The credit line as the publisher asks for it.
        public var attribution: String
        public var url: URL
        /// Upstream modification date, "YYYY-MM-DD".
        public var modified: String
        public var built: String
        /// Polygons in the source (Σ units' `polygons`).
        public var polygons: Int
    }

    public struct Unit: Decodable, Sendable, Hashable {
        /// "Blessington Association" — may hold an en dash: UI text only,
        /// never a map label (glyphs are Latin-1).
        public var name: String
        public var description: String
        /// Australian Soil Classification orders, main one first; empty
        /// where the source says "Insufficient Data".
        public var orders: [String]
        /// Soil profile class ("Archer SPC"), when the source names one.
        public var profile: String?
        /// Official fill, "#rrggbb" (also per feature in the tiles).
        public var color: String
        /// Mapped area, hectares.
        public var ha: Double
        public var polygons: Int
        /// Sheet keys the unit is mapped on.
        public var sheets: [String]

        /// The card's "Mapped extent" row.
        public func extentText(locale: Locale = .current) -> String {
            SoilsFile.formatExtent(hectares: ha, polygons: polygons, locale: locale)
        }
    }

    /// A reconnaissance map sheet and its published report.
    public struct Sheet: Decodable, Sendable, Hashable {
        public var name: String
        /// The sheet's report (PDF), fetched by the device from the publisher.
        public var url: URL
        public var bytes: Int
        public var ha: Double
        public var bounds: Bounds

        public struct Bounds: Sendable, Hashable {
            public var west, south, east, north: Double
            public init(west: Double, south: Double, east: Double, north: Double) {
                self.west = west
                self.south = south
                self.east = east
                self.north = north
            }
        }

        private enum CodingKeys: String, CodingKey { case name, url, bytes, ha, bbox }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(URL.self, forKey: .url)
            bytes = try c.decode(Int.self, forKey: .bytes)
            ha = try c.decode(Double.self, forKey: .ha)
            let b = try c.decode([Double].self, forKey: .bbox)
            guard b.count == 4, b[0] < b[2], b[1] < b[3] else {
                throw DecodingError.dataCorruptedError(forKey: .bbox, in: c, debugDescription: "bbox is [w, s, e, n]")
            }
            bounds = Bounds(west: b[0], south: b[1], east: b[2], north: b[3])
        }
    }

    public struct Order: Decodable, Sendable, Hashable {
        /// One sentence for a lay reader.
        public var gloss: String
    }

    /// Whether a point lies inside any sheet's frame (bbox). Outside every
    /// one, nothing was surveyed; inside, a miss is water, a polygon too
    /// small for the zoom or a tile not drawn yet — never "unmapped".
    public func anySheetContains(longitude: Double, latitude: Double) -> Bool {
        sheets.values.contains { s in
            (s.bounds.west ... s.bounds.east).contains(longitude) && (s.bounds.south ... s.bounds.north).contains(latitude)
        }
    }

    /// The box around every sheet (the "mapped areas").
    public var sheetsBounds: Sheet.Bounds? {
        guard let first = sheets.values.first?.bounds else { return nil }
        return sheets.values.reduce(first) { acc, s in
            Sheet.Bounds(west: min(acc.west, s.bounds.west), south: min(acc.south, s.bounds.south),
                         east: max(acc.east, s.bounds.east), north: max(acc.north, s.bounds.north))
        }
    }

    /// "~543 km² in 206 patches", "70 ha in 1 patch" under 100 ha (a small
    /// unit never reads "0 km²"). Halves round up, digits follow `locale`
    /// (the pre-1750 extent's rules).
    public static func formatExtent(hectares ha: Double, polygons: Int, locale: Locale = .current) -> String {
        let patches = polygons == 1 ? "1 patch" : "\(polygons.formatted(.number.locale(locale))) patches"
        let rounding = FloatingPointRoundingRule.toNearestOrAwayFromZero
        if ha < 100 {
            let h = max(1, ha.rounded(rounding))
            return "\(h.formatted(.number.precision(.fractionLength(0)).locale(locale))) ha in \(patches)"
        }
        let km2 = (ha / 100).formatted(.number.precision(.fractionLength(0)).rounded(rule: rounding).locale(locale))
        return "~\(km2) km² in \(patches)"
    }
}
