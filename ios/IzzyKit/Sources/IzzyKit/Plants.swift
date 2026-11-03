import Foundation

/// One Understorey Network photo (© its photographer — fetched by the device, never bundled).
public struct PlantPhoto: Codable, Sendable, Hashable {
    /// Under /wp-content/uploads/, no size suffix, no extension ("2019/05/abc").
    public var path: String
    public var ext: String
    /// Suffix of the 150 px square thumbnail, or nil.
    public var thumb: String?
    /// Suffix of the ~768 px version ("-768x576"), or of a WordPress-renamed
    /// original ("-rotated", "-scaled"), or "" = the original. Never parsed.
    public var large: String
    /// Size of the large version, if known.
    public var bytes: Int?
    public var credit: String?
}

/// An Understorey Network Tasmania plant profile.
public struct Plant: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var slug: String
    /// Verbatim UN title — may hold characters outside Latin-1: UI text only, never map text.
    public var name: String
    /// Species-rank key shared with records.json (nil for a few profiles).
    public var species: String?
    public var common: String?
    public var family: String?
    public var forms: [String]
    public var height: String?
    public var form: String?
    public var flowers: String?
    public var fruit: String?
    public var habitat: String?
    public var notes: String?
    public var status: String?
    /// Flowering months, 1–12.
    public var flowering: [Int]
    public var habitats: [String]
    public var photos: [PlantPhoto]
}

/// plants.json: profiles, the F2F "named in the description" lists and split groups.
public struct PlantsFile: Codable, Sendable, Versioned {
    public static let supportedVersion = 1
    /// A broad-sense F2F name UN only has segregates for ("pinkberry" → 6 species).
    public struct Group: Codable, Sendable, Hashable {
        public var common: String?
        public var species: [String]
    }
    public var version: Int
    public var built: String?
    public var plants: [Plant]
    /// VEGCODE → species keys (or `groups` keys) in order of mention.
    public var communities: [String: [String]]
    public var groups: [String: Group]?
}

/// records.json: ALA occurrence aggregates per TASVEG community (C1) and the grid geometry (C2).
public struct RecordsFile: Decodable, Sendable, Versioned {
    public static let supportedVersion = 1
    /// One C1 row: a species' recorded ~100 m sites in a community and its
    /// indicator score (nil = a community with few records, ranked by sites).
    public struct Row: Decodable, Sendable, Hashable {
        public var species: Int
        public var sites: Int
        public var score: Double?
        public init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            species = try c.decode(Int.self)
            sites = try c.decode(Int.self)
            score = try c.decodeIfPresent(Double.self)
        }
    }
    /// [species index, sites] for a group member, uncapped.
    public struct MemberRow: Decodable, Sendable, Hashable {
        public var species: Int
        public var sites: Int
        public init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            species = try c.decode(Int.self)
            sites = try c.decode(Int.self)
        }
    }
    /// The nearby grid: cell centres on multiples of `step` from (lat0, lon0).
    public struct Grid: Codable, Sendable, Hashable {
        public var step: Double
        public var lat0: Double
        public var lon0: Double
        public var nlon: Int
    }
    /// Attribution facts (About screen).
    public struct Sources: Decodable, Sendable, Hashable {
        /// (data resource uid, name, records); the pipeline's "other providers" row has no uid.
        public struct Resource: Decodable, Sendable, Hashable {
            public var uid: String?, name: String, records: Int
            public init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                uid = try c.decodeIfPresent(String.self)
                name = try c.decode(String.self)
                records = try c.decode(Int.self)
            }
        }
        /// (licence, records)
        public struct Licence: Decodable, Sendable, Hashable {
            public var licence: String, records: Int
            public init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                licence = try c.decode(String.self)
                records = try c.decode(Int.self)
            }
        }
        public var ala: String
        public var records: Int
        public var filters: String
        public var resources: [Resource]
        public var licences: [Licence]?
    }

    public var version: Int
    public var built: String?
    /// Species keys; rows refer to them by index.
    public var species: [String]
    /// VEGCODE → C1 rows, best first (≤ 40).
    public var communities: [String: [Row]]
    /// VEGCODE → total recorded ~100 m sites.
    public var sites: [String: Int]?
    /// VEGCODE → every recorded group-member species (uncapped).
    public var members: [String: [MemberRow]]?
    public var grid: Grid
    public var sources: Sources?
}
