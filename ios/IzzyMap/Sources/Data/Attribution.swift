import Foundation

/// Credits for the map's data, the single source of truth: the app hides
/// MapLibre's attribution button (a PMTiles source's credit comes from the
/// archive's own metadata, not the style) and shows these instead, behind
/// its own (i) control, for the sources visible right now. Wording as the
/// web app's ATTRIBUTION_* (git 04ea5d9:app/src/config.ts); regimes in
/// docs/LICENSING.md.
nonisolated struct Credit: Hashable, Identifiable, Sendable {
    nonisolated struct Licence: Hashable, Sendable {
        let name: String
        let url: URL

        static let ccBy3AU = Licence(name: "CC BY 3.0 AU", url: URL(string: "https://creativecommons.org/licenses/by/3.0/au/")!)
        static let ccByNcNd3AU = Licence(name: "CC BY-NC-ND 3.0 AU", url: URL(string: "https://creativecommons.org/licenses/by-nc-nd/3.0/au/")!)
        static let ccBy4 = Licence(name: "CC BY 4.0", url: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
    }

    let id: String
    /// "Topographic Basemap from theLIST"
    let title: String
    /// "© State of Tasmania"
    let holder: String
    let licence: Licence
    /// Where the data comes from.
    let source: URL?
    /// Terms the licence attaches to our use (NC-ND rasters).
    var terms: String?

    /// One line, as the web app wrote it:
    /// "Topographic Basemap from theLIST © State of Tasmania (CC BY 3.0 AU)".
    var line: String {
        holder.isEmpty ? "\(title) (\(licence.name))" : "\(title) \(holder) (\(licence.name))"
    }
}

nonisolated enum Attribution {
    private static let theLIST = URL(string: "https://www.thelist.tas.gov.au")!
    private static let state = "© State of Tasmania"
    /// CC BY-NC-ND rasters are shown byte-for-byte as LIST serves them.
    static let unalteredTerms = "Reproduced unaltered for personal, non-commercial use."

    static let topo = Credit(id: "topo", title: "Topographic Basemap from theLIST", holder: state,
                             licence: .ccBy3AU, source: theLIST)
    static let tasveg = Credit(id: "tasveg", title: "TASVEG 5.0 from theLIST", holder: state,
                               licence: .ccBy3AU, source: theLIST)
    static let aerial = Credit(id: "aerial", title: "Aerial photos from theLIST", holder: state,
                               licence: .ccByNcNd3AU, source: theLIST, terms: unalteredTerms)
    static let tasmap = Credit(id: "tasmap", title: "Tasmap from theLIST", holder: state,
                               licence: .ccByNcNd3AU, source: theLIST, terms: unalteredTerms)
    static let hillshade = Credit(id: "hillshade", title: "Hillshade from theLIST", holder: state,
                                  licence: .ccBy3AU, source: theLIST)
    static let geology = Credit(id: "geology", title: "Geology from Mineral Resources Tasmania", holder: state,
                                licence: .ccBy3AU, source: URL(string: "https://www.mrt.tas.gov.au"))
    static let pre1750 = Credit(id: "pre1750", title: "Pre-1750 vegetation: NVIS V7.0",
                                holder: "© Commonwealth of Australia, DCCEEW", licence: .ccBy4,
                                source: URL(string: "https://www.dcceew.gov.au/environment/environment-information-australia/national-vegetation-information-system"))
    static let trees = Credit(id: "trees", title: "Significant trees: City of Hobart", holder: "",
                              licence: .ccBy4,
                              source: URL(string: "https://www.hobartcity.com.au/Environment-and-Sustainability/Trees/Significant-trees"))

    /// Style source id → credit. Every source in the style must be here or
    /// in `uncreditedSources` (a unit test enforces it). Pack and live
    /// sources of one dataset share its credit.
    static let bySource: [String: Credit] = [
        StyleBuilder.SourceID.topo: topo,
        StyleBuilder.SourceID.topoLive: topo,
        StyleBuilder.SourceID.tasveg: tasveg,
    ]

    /// Sources that carry no third-party data (the app's own drawing).
    static let uncreditedSources: Set<String> = [StyleBuilder.SourceID.selection]

    /// The credits for these sources, deduplicated, in a stable order.
    static func credits(forSources sources: Set<String>) -> [Credit] {
        Set(sources.compactMap { bySource[$0] }).sorted { $0.title < $1.title }
    }
}
