import Foundation
import IzzyKit

/// What the app calls and credits each area layer, and how it maps onto the
/// statewide packs and the style (docs/NATIVE_PLAN.md §3 "Detailed areas").
extension AreaLayer {
    nonisolated var season: Season? {
        if case let .season(year) = self { return Season.all.first { $0.year == year } }
        return nil
    }

    /// The statewide pack it sits above.
    nonisolated var archive: Archive? {
        switch self {
        case .aerial: .aerial
        case .tasmap: .tasmap
        case .topo: .topo
        case .season: season?.archive
        }
    }

    nonisolated var title: String {
        switch self {
        case .aerial: "Aerial photos"
        case .tasmap: "Paper map"
        case .topo: "Topographic map"
        case .season: season.map { "\($0.label) photos" } ?? rawValue
        }
    }

    /// The same credit as the statewide layer: the data and its licence are
    /// LIST's either way (the area's tiles are fetched by the device, kept
    /// byte for byte, for personal use only — never uploaded or hosted).
    nonisolated var credit: Credit {
        switch self {
        case .aerial: Attribution.aerial
        case .season: Attribution.seasons
        case .tasmap: Attribution.tasmap
        case .topo: Attribution.topo
        }
    }

    /// The archive's `attribution` metadata: the credit line and its terms.
    nonisolated var attributionText: String {
        [credit.line, credit.terms].compactMap { $0 }.joined(separator: " ")
    }

    nonisolated static var allSeasons: [AreaLayer] { Season.all.map { .season($0.year) } }
}

/// The setup sheet's choices (one row each); "All seasons" stands for the
/// seven seasons, of which only those flown inside the frame are fetched.
nonisolated enum AreaChoice: String, CaseIterable, Sendable, Identifiable {
    case aerial, seasons, tasmap, topo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .aerial: "Aerial photos"
        case .seasons: "All seasons where flown"
        case .tasmap: "Paper map"
        case .topo: "Topographic map"
        }
    }


    var symbol: String {
        switch self {
        case .aerial: "photo"
        case .seasons: "photo.stack"
        case .tasmap: "map.fill"
        case .topo: "map"
        }
    }

    var layers: [AreaLayer] {
        switch self {
        case .aerial: [.aerial]
        case .seasons: AreaLayer.allSeasons
        case .tasmap: [.tasmap]
        case .topo: [.topo]
        }
    }

    /// What Download starts with: the base map she is looking at.
    static func defaults(base: BaseMap) -> Set<AreaChoice> {
        switch base {
        case .topo: [.topo]
        case .aerial: [.aerial]
        case .tasmap: [.tasmap]
        case .seasons: [.seasons]
        }
    }
}

/// One finished area layer as the style draws it: a local PMTiles raster
/// source right above its statewide pack (and that pack's live source).
nonisolated struct AreaStyleSource: Sendable, Equatable {
    let areaID: String
    let layer: AreaLayer
    let url: URL
    let box: AreaBox
    /// The archive's deepest tile level (the detail, or where it was capped).
    var maxZoom: Int = AreaDetail.finest.zoom

    /// Source and layer id: "area-<id>-<layer>".
    var id: String { Self.prefix + areaID + "-" + layer.rawValue }

    static let prefix = "area-"

    /// The layer of an area source id (nil for any other source).
    static func layer(ofSource id: String) -> AreaLayer? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return AreaLayer(rawValue: String(rest[rest.index(after: dash)...]))
    }
}
