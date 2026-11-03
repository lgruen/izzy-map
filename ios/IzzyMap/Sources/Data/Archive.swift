import Foundation

/// The offline map archives this build reads. File names are the pipeline's
/// outputs (`pipeline/build_tasveg.sh`, `pipeline/packs.json`).
nonisolated enum Archive: String, CaseIterable, Sendable {
    /// TASVEG 5.0 communities, vector tiles.
    case tasveg
    /// LIST topographic basemap, PNG z0–15.
    case topo

    var fileName: String {
        switch self {
        case .tasveg: "tasveg.pmtiles"
        case .topo: "topo_tas.pmtiles"
        }
    }
}
