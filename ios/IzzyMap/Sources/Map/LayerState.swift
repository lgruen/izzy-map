import Foundation

/// The base map: what the overlay is drawn over.
nonisolated enum BaseMap: String, Codable, CaseIterable, Sendable, Identifiable {
    case topo, aerial, tasmap, seasons
    var id: String { rawValue }

    var title: String {
        switch self {
        case .topo: "Topographic"
        case .aerial: "Aerial photos"
        case .tasmap: "Paper map"
        case .seasons: "Photos by season"
        }
    }

    /// The tile label.
    var shortTitle: String {
        switch self {
        case .topo: "Topo"
        case .aerial: "Aerial"
        case .tasmap: "Paper map"
        case .seasons: "By season"
        }
    }

    var hint: String {
        switch self {
        case .topo: "theLIST topographic map"
        case .aerial: "Best available imagery, statewide"
        case .tasmap: "Scanned Tasmap sheets, 1:25,000 when zoomed in"
        case .seasons: "The newest photo flown up to a chosen season"
        }
    }

    var symbol: String {
        switch self {
        case .topo: "map"
        case .aerial: "photo"
        case .tasmap: "map.fill"
        case .seasons: "photo.stack"
        }
    }

    /// The pack holding this base (seasons: several).
    var archive: Archive? {
        switch self {
        case .topo: .topo
        case .aerial: .aerial
        case .tasmap: .tasmap
        case .seasons: nil
        }
    }

    /// Photos, not cartography: boundaries switch to paper-white.
    var isPhoto: Bool { self == .aerial || self == .seasons }
}

/// The overlay drawn over the base (exactly one, or none).
nonisolated enum Overlay: String, Codable, CaseIterable, Sendable, Identifiable {
    case vegetation, pre1750, geology, none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vegetation: "Vegetation"
        case .pre1750: "Pre-1750 vegetation"
        case .geology: "Geology"
        case .none: "None"
        }
    }

    /// The tile label.
    var shortTitle: String {
        switch self {
        case .vegetation: "Vegetation"
        case .pre1750: "Pre-1750"
        case .geology: "Geology"
        case .none: "None"
        }
    }

    /// The placeholder glyph while the thumbnail renders.
    var symbol: String {
        switch self {
        case .vegetation: "leaf"
        case .pre1750: "hourglass"
        case .geology: "square.3.layers.3d.down.right"
        case .none: "circle.slash"
        }
    }

    var hint: String {
        switch self {
        case .vegetation: "TASVEG 5.0 plant communities today"
        case .pre1750: "Modelled, before European clearing"
        case .geology: "1:500,000 rock units"
        case .none: "Base map only"
        }
    }

    var archive: Archive? {
        switch self {
        case .vegetation: .tasveg
        case .pre1750: .pre1750
        case .geology: .geology
        case .none: nil
        }
    }

    /// Pre-1750's 1 ha cell edges are grid artefacts: it has no boundaries,
    /// so "Outlines" would show nothing and falls back to Light.
    var hasBoundaries: Bool { self == .vegetation || self == .geology }
}

/// How strongly the overlay tints the base.
nonisolated enum Strength: String, Codable, CaseIterable, Sendable, Identifiable {
    case full, light, outlines
    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full"
        case .light: "Light"
        case .outlines: "Outlines"
        }
    }
}

/// Everything the Layers sheet controls — the map comes back exactly as
/// left. One value per window; the most recent one also seeds new windows
/// and relaunches (`LayerStore`).
nonisolated struct LayerState: Codable, Equatable, Sendable {
    var base: BaseMap = .topo
    /// The newest season shown, by the year it ends (2024 = 2023–24); nil =
    /// always the newest season this build knows. Stored as a year, not an
    /// index: a build that adds a season keeps "up to 2023–24" meaning that.
    var seasonYear: Int?
    var overlay: Overlay = .vegetation
    var strength: Strength = .full
    /// Relief shading over base and overlay.
    var relief = false
    /// City of Hobart significant trees on top of everything.
    var trees = false

    static let `default` = LayerState()

    init() {}

    /// Index into `Season.all` of the newest season shown (the slider's
    /// value). Setting the newest season means "latest".
    var season: Int {
        get { seasonYear.flatMap { y in Season.all.firstIndex { $0.year == y } } ?? Season.all.count - 1 }
        set {
            let i = min(max(newValue, 0), Season.all.count - 1)
            seasonYear = i == Season.all.count - 1 ? nil : Season.all[i].year
        }
    }

    private enum CodingKeys: String, CodingKey { case base, season, overlay, strength, relief, trees }
    static let latestToken = "latest"

    /// Unknown or missing values fall back to the defaults one field at a
    /// time (a stored state from an older or newer build never fails whole).
    /// `season` is a year or "latest"; a small integer is a pre-M2 slider
    /// index (0…6) and maps to its season.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayerState.default
        base = (try? c.decodeIfPresent(BaseMap.self, forKey: .base)) ?? d.base
        overlay = (try? c.decodeIfPresent(Overlay.self, forKey: .overlay)) ?? d.overlay
        strength = (try? c.decodeIfPresent(Strength.self, forKey: .strength)) ?? d.strength
        relief = (try? c.decodeIfPresent(Bool.self, forKey: .relief)) ?? d.relief
        trees = (try? c.decodeIfPresent(Bool.self, forKey: .trees)) ?? d.trees
        if let n = try? c.decodeIfPresent(Int.self, forKey: .season) {
            if Season.all.contains(where: { $0.year == n }) {
                seasonYear = n == Season.all.last?.year ? nil : n
            } else if Season.all.indices.contains(n) {
                season = n  // legacy index
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(base, forKey: .base)
        if let seasonYear { try c.encode(seasonYear, forKey: .season) } else { try c.encode(Self.latestToken, forKey: .season) }
        try c.encode(overlay, forKey: .overlay)
        try c.encode(strength, forKey: .strength)
        try c.encode(relief, forKey: .relief)
        try c.encode(trees, forKey: .trees)
    }

    /// The strength actually drawn (pre-1750 has no Outlines).
    var effectiveStrength: Strength {
        overlay.hasBoundaries || strength != .outlines ? strength : .light
    }

    /// Fill opacity of the overlay over this base (docs/DESIGN.md §4): photos
    /// take less tint than cartography. Outlines = no fill.
    var fillOpacity: Double {
        Self.fillOpacity(base: base, strength: effectiveStrength)
    }

    static func fillOpacity(base: BaseMap, strength: Strength) -> Double {
        switch (base, strength) {
        case (_, .outlines): 0
        case (.topo, .full): 0.55
        case (.topo, .light): 0.30
        case (.tasmap, .full): 0.50
        case (.tasmap, .light): 0.25
        case (.aerial, .full), (.seasons, .full): 0.40
        case (.aerial, .light), (.seasons, .light): 0.20
        }
    }

    var seasonClamped: Int { min(max(season, 0), Season.all.count - 1) }
}

/// The last layer state, kept in UserDefaults (a few bytes of user state):
/// survives a force-quit, which discards scene restoration data.
struct LayerStore {
    var defaults: UserDefaults = .standard
    static let key = "layerState"

    func load() -> LayerState {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(LayerState.self, from: $0) } ?? .default
    }

    func save(_ state: LayerState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }
}
