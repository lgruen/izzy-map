import Foundation

/// A longitude/latitude pair in degrees (GeoJSON order on disk).
public struct GeoPoint: Codable, Sendable, Hashable {
    public var longitude: Double
    public var latitude: Double
    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        longitude = try c.decode(Double.self)
        latitude = try c.decode(Double.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(longitude)
        try c.encode(latitude)
    }
}

/// City of Hobart significant trees (CC BY 4.0): points, areas and per-register-ref facts.
public struct TreesData: Decodable, Sendable {
    public struct Meta: Codable, Sendable, Hashable {
        public var item: String
        public var source: String
        public var licence: String
        public var attribution: String
        public var built: String
        public var itemModified: String
        public var points: Int
        public var areas: Int
    }
    /// The three properties every tree feature carries.
    public struct Tag: Codable, Sendable, Hashable {
        /// Register reference, e.g. "D5".
        public var ref: String
        /// ArcGIS Online item id of the data-sheet PDF.
        public var sheet: String
        /// Position-accuracy code (see `accuracy`).
        public var acc: String
    }
    /// A tree location (one or more trees at a point).
    public struct Point: Sendable, Hashable {
        public var tag: Tag
        public var position: GeoPoint
    }
    /// A group, hedge or avenue: polygons → rings → positions (a Polygon is one polygon).
    public struct Area: Sendable, Hashable {
        public var tag: Tag
        public var polygons: [[[GeoPoint]]]
    }
    /// Register facts for one reference.
    public struct Ref: Codable, Sendable, Hashable {
        /// Botanical name verbatim from the register (may hold curly quotes) — UI text only.
        public var name: String
        /// Latin-1-safe short label for map text.
        public var label: String
        /// Common name, "" when the register has none.
        public var common: String
        public var address: String
        public var trees: Int?
        /// Object_Metadata verbatim (may be "").
        public var note: String
        public var sheets: [String]
    }
    /// One data-sheet PDF.
    public struct Sheet: Codable, Sendable, Hashable {
        public var bytes: Int
        public var title: String
    }

    public var meta: Meta
    public var points: [Point]
    public var areas: [Area]
    public var refs: [String: Ref]
    /// Accuracy code → label ("sk" → "Sketch").
    public var accuracy: [String: String]
    public var sheets: [String: Sheet]

    /// The card's "Position accuracy" row for a feature's code (nil hides the row).
    public func accuracyLabel(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return accuracy[code]
    }
    /// The sheet a feature opens: its own if listed, else its ref's first.
    public func sheetID(for tag: Tag) -> String? {
        sheets[tag.sheet] != nil ? tag.sheet : refs[tag.ref]?.sheets.first
    }
    /// Σ sheet sizes (the bulk download row's total).
    public var sheetsTotalBytes: Int { sheets.values.reduce(0) { $0 + $1.bytes } }

    enum CodingKeys: String, CodingKey { case meta, points, areas, refs, accuracy, sheets }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(Meta.self, forKey: .meta)
        refs = try c.decode([String: Ref].self, forKey: .refs)
        accuracy = try c.decode([String: String].self, forKey: .accuracy)
        sheets = try c.decode([String: Sheet].self, forKey: .sheets)
        points = try c.decode(FeatureCollection.self, forKey: .points).features.map { f in
            guard case let .point(p) = f.geometry else {
                throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "non-Point tree feature")
            }
            return Point(tag: f.properties, position: p)
        }
        areas = try c.decode(FeatureCollection.self, forKey: .areas).features.map { f in
            switch f.geometry {
            case let .polygon(rings): return Area(tag: f.properties, polygons: [rings])
            case let .multiPolygon(polys): return Area(tag: f.properties, polygons: polys)
            case .point: throw DecodingError.dataCorruptedError(forKey: .areas, in: c, debugDescription: "Point in tree areas")
            }
        }
    }

    private struct FeatureCollection: Decodable { var features: [Feature] }
    private struct Feature: Decodable { var geometry: Geometry; var properties: Tag }
    private enum Geometry: Decodable {
        case point(GeoPoint), polygon([[GeoPoint]]), multiPolygon([[[GeoPoint]]])
        enum K: String, CodingKey { case type, coordinates }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .type) {
            case "Point": self = .point(try c.decode(GeoPoint.self, forKey: .coordinates))
            case "Polygon": self = .polygon(try c.decode([[GeoPoint]].self, forKey: .coordinates))
            case "MultiPolygon": self = .multiPolygon(try c.decode([[[GeoPoint]]].self, forKey: .coordinates))
            case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unsupported geometry \(t)")
            }
        }
    }
}
