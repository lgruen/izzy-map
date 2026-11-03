import Foundation

/// One TASVEG 5.0 community from the bundled table
/// (`Resources/Data/tasveg_communities.json`, written by the pipeline from
/// the official QML symbology).
// TODO(M2/M3): move table decoding into IzzyKit with the other data tables.
nonisolated struct Community: Decodable, Sendable, Equatable {
    /// "(DOB) Eucalyptus obliqua dry forest" — the code prefix is the source's.
    let name: String
    let group: String
    /// Official fill colour, "#rrggbb".
    let color: String
    let outline: String
    let label: String
}

nonisolated struct CommunityTable: Sendable {
    let byCode: [String: Community]

    static let empty = CommunityTable(byCode: [:])

    static func load(bundle: Bundle = .main) throws -> CommunityTable {
        guard let url = bundle.url(forResource: "tasveg_communities", withExtension: "json", subdirectory: "Data") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> CommunityTable {
        CommunityTable(byCode: try JSONDecoder().decode([String: Community].self, from: data))
    }

    subscript(code: String) -> Community? { byCode[code] }

    /// The community's name without the "(CODE) " prefix the table carries
    /// (the card shows the code separately).
    static func plainName(_ name: String, code: String) -> String {
        let prefix = "(\(code)) "
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }
}
