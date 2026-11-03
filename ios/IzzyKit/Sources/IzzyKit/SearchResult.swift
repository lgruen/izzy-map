import Foundation

/// A west/south/east/north box in degrees.
public struct SearchBBox: Sendable, Hashable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double
    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }
}

/// One answer of `SearchIndex.search`.
public struct SearchResult: Sendable, Hashable, Identifiable {
    /// The row's glyph: the seven nomenclature groups plus street addresses.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case transport = "Transport"
        case naturalFeature = "Natural Feature"
        case cultural = "Cultural"
        case reserve = "Reserve"
        case recreation = "Recreation"
        case infrastructure = "Infrastructure"
        case property = "Property"
        case address = "Address"

        /// From a nomenclature group name; an unknown group draws the
        /// address glyph (as the web app did).
        public init(group: String) { self = Kind(rawValue: group) ?? .address }

        /// A suggested SF Symbol for the row (the web glyphs: road, peak,
        /// building, tree, flag, tower, house, pin).
        public var systemImage: String {
            switch self {
            case .transport: "road.lanes"
            case .naturalFeature: "mountain.2"
            case .cultural: "building.columns"
            case .reserve: "tree"
            case .recreation: "flag"
            case .infrastructure: "antenna.radiowaves.left.and.right"
            case .property: "house"
            case .address: "mappin.and.ellipse"
            }
        }
    }

    /// Where the camera goes when the result is picked.
    public enum Camera: Sendable, Hashable {
        /// Fit the box with `padding` points around it, never closer than `maxZoom`.
        case fit(SearchBBox, maxZoom: Double, padding: Double)
        /// Centre on the point at a per-type zoom.
        case point(GeoPoint, zoom: Double)
    }

    /// Stable per row of the index ("e123" place name, "s45" address-file
    /// street, "a678" house number) — unique within one result list.
    public var id: String
    /// Display name ("Elizabeth Street", "12 Elizabeth Street").
    public var name: String
    /// LIST feature type ("Road", "Mountain", …) or "Address".
    public var type: String
    /// LIST feature group ("Transport", …) or "Address".
    public var group: String
    /// Second line: "Road · North Hobart, Hobart", "Address · Hobart · nearest: 14".
    public var meta: String
    /// The pin (for a street from the address file: its middle house number).
    public var coordinate: GeoPoint
    /// Extent, when the feature has one.
    public var bbox: SearchBBox?
    /// Ranking score (higher first) — exposed for tests and debugging.
    public var score: Double
    /// Distance from the `near` point, when one was given.
    public var distanceKm: Double?

    public init(id: String, name: String, type: String, group: String, meta: String, coordinate: GeoPoint,
                bbox: SearchBBox? = nil, score: Double = 0, distanceKm: Double? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.group = group
        self.meta = meta
        self.coordinate = coordinate
        self.bbox = bbox
        self.score = score
        self.distanceKm = distanceKm
    }

    public var kind: Kind { Kind(group: group) }

    /// "350 m", "4.2 km", "17 km" — nil without a `near` point.
    public var distanceText: String? { distanceKm.map { SearchText.formatDistance(km: $0) } }

    /// Fit the bbox (max z16 for transport, z14.5 otherwise, 56 pt padding),
    /// else fly to the point at the type's zoom (14 for unlisted types).
    public var camera: Camera {
        if let bbox {
            return .fit(bbox, maxZoom: group == "Transport" ? 16 : 14.5, padding: 56)
        }
        return .point(coordinate, zoom: Self.zoomByType[type] ?? 14)
    }

    /// Zoom for point results (bbox results fit instead).
    public static let zoomByType: [String: Double] = [
        "Town": 13, "Suburb/Locality": 14, "Unbounded Locality": 13, "Mountain": 13, "Mountains": 11,
        "Hill": 13.5, "Stream": 13, "Water Body": 13, "Bay": 13, "Beach": 14, "Island": 13,
        "Promontory": 14, "Waterfall": 15, "Cave": 15, "Track": 14, "Route": 11,
        "Recreational Park": 14, "Conservation Area": 12, "Property": 16, "Address": 17.5,
        "Road": 16, // an address-file street with a single number (register roads carry a bbox)
    ]
}
