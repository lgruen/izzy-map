import Foundation

/// The offline map archives this build reads. File names are the pipeline's
/// outputs (`pipeline/build_tasveg.sh`, `pipeline/packs.json`, the relief
/// re-render); the hand-curated list is a repo decision.
nonisolated enum Archive: String, CaseIterable, Sendable {
    /// TASVEG 5.0 communities, vector tiles.
    case tasveg
    /// MRT 1:500,000 geology units, vector tiles.
    case geology
    /// NVIS V7.0 pre-1750 Major Vegetation Subgroups, vector tiles.
    case pre1750
    /// LIST topographic basemap, PNG z0–15.
    case topo
    /// LIST Orthophoto statewide "best available" mosaic, JPEG z0–15.
    case aerial
    /// LIST TasmapRaster paper-map scans, MIXED z0–15.
    case tasmap
    /// Relief shading: LIST HillshadeGrey pre-rendered as translucent black
    /// (alpha = 0.4 × (1 − g/247)), z0–15.
    case relief
    /// The seven flying seasons, oldest first (`Season.all`).
    case season2020, season2021, season2022, season2023, season2024, season2025, season2026

    var fileName: String {
        switch self {
        case .tasveg: "tasveg.pmtiles"
        case .geology: "geology.pmtiles"
        case .pre1750: "pre1750.pmtiles"
        case .topo: "topo_tas.pmtiles"
        case .aerial: "aerial_tas.pmtiles"
        case .tasmap: "tasmap_tas.pmtiles"
        case .relief: "relief_tas.pmtiles"
        case .season2020: "aerial_2020.pmtiles"
        case .season2021: "aerial_2021.pmtiles"
        case .season2022: "aerial_2022.pmtiles"
        case .season2023: "aerial_2023.pmtiles"
        case .season2024: "aerial_2024.pmtiles"
        case .season2025: "aerial_2025.pmtiles"
        case .season2026: "aerial_2026.pmtiles"
        }
    }
}

/// One LIST flying season (`Basemaps/AerialPhotoYYYY`: the season ending in YYYY).
nonisolated struct Season: Sendable, Hashable, Identifiable {
    /// The year the season ends, e.g. 2024 for 2023–24.
    let year: Int
    let archive: Archive
    /// Every season is a patchwork, still flown and published while current.
    var isIncomplete: Bool { year == Season.all.last?.year }

    var id: Int { year }
    /// "2023–24"
    var label: String { "\(year - 1)–\(String(format: "%02d", year % 100))" }
    /// Style source/layer id of the pack, e.g. "season-2024".
    var sourceID: String { "season-\(year)" }
    /// The LIST service.
    var service: String { "AerialPhoto\(year)" }

    /// Oldest first (the stack's paint order; the slider's index).
    static let all: [Season] = [
        Season(year: 2020, archive: .season2020), Season(year: 2021, archive: .season2021),
        Season(year: 2022, archive: .season2022), Season(year: 2023, archive: .season2023),
        Season(year: 2024, archive: .season2024), Season(year: 2025, archive: .season2025),
        Season(year: 2026, archive: .season2026),
    ]
    static var labels: [String] { all.map(\.label) }
}
