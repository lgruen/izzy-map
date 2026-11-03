import Foundation

/// Why a bundled data file could not be used.
public enum DataError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The file is a format version this build does not understand.
    case unsupportedVersion(file: String, found: Int?, supported: Int)
    /// The file's structure is not what IzzyKit expects.
    case malformed(file: String, reason: String)

    public var description: String {
        switch self {
        case let .unsupportedVersion(file, found, supported):
            let v = found.map(String.init) ?? "none"
            return "\(file): format version \(v), this build reads only version \(supported) — the app and its data are out of step"
        case let .malformed(file, reason):
            return "\(file): \(reason)"
        }
    }
}

/// The bundled fact tables (formerly app/src/generated/), read from one directory.
/// Loading is synchronous file I/O + decoding: call it off the main actor.
public struct BundledData: Sendable {
    /// Directory holding the files (e.g. the app bundle's `Data` folder).
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The data folder inside `bundle` (subdirectory `Data`, else the bundle's top level).
    public static func inBundle(_ bundle: Bundle = .main, subdirectory: String? = "Data") -> BundledData? {
        let probe = File.communities
        let url = bundle.url(forResource: probe, withExtension: nil, subdirectory: subdirectory)
            ?? bundle.url(forResource: probe, withExtension: nil)
        return url.map { BundledData(root: $0.deletingLastPathComponent()) }
    }

    /// File names, as the pipeline writes them.
    public enum File {
        public static let communities = "tasveg_communities.json"
        public static let geology = "geology_units.json"
        public static let pre1750 = "pre1750_units.json"
        public static let trees = "trees.json"
        public static let plants = "plants.json"
        public static let records = "records.json"
        public static let f2f = "f2f_index.json"
        public static let nearby = "nearby.bin"
        public static let acknowledgements = "acknowledgements.json"
    }

    public func communities() throws -> CommunityTable { try decode(File.communities) }
    public func geologyUnits() throws -> GeologyTable { try decode(File.geology) }
    public func pre1750Units() throws -> Pre1750Table { try decode(File.pre1750) }
    public func f2fIndex() throws -> F2FIndex { try decode(File.f2f) }
    public func trees() throws -> TreesData { try decode(File.trees) }
    public func plants() throws -> PlantsFile { try decodeVersioned(File.plants, supported: PlantsFile.supportedVersion) }
    public func records() throws -> RecordsFile { try decodeVersioned(File.records, supported: RecordsFile.supportedVersion) }
    public func nearbyGrid() throws -> NearbyGrid { try NearbyGrid(data: data(File.nearby)) }

    /// plants.json + records.json + nearby.bin, indexed for the three plant lists.
    public func plantCatalog() throws -> PlantCatalog {
        try PlantCatalog(plants: plants(), records: records(), grid: nearbyGrid())
    }

    func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appending(path: name), options: .mappedIfSafe)
    }

    func decode<T: Decodable>(_ name: String) throws -> T {
        let bytes = try data(name)
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch let e as DecodingError { throw DataError.malformed(file: name, reason: String(describing: e)) }
    }

    /// Decodes a `version`-tagged file: a version mismatch is reported as
    /// such even when the new shape no longer decodes (probed only on failure,
    /// so the happy path parses once).
    func decodeVersioned<T: Decodable & Versioned>(_ name: String, supported: Int) throws -> T {
        let bytes = try data(name)
        do {
            let value = try JSONDecoder().decode(T.self, from: bytes)
            guard value.version == supported else {
                throw DataError.unsupportedVersion(file: name, found: value.version, supported: supported)
            }
            return value
        } catch let e as DecodingError {
            let found = (try? JSONDecoder().decode(VersionProbe.self, from: bytes))?.version
            if found != supported { throw DataError.unsupportedVersion(file: name, found: found, supported: supported) }
            throw DataError.malformed(file: name, reason: String(describing: e))
        }
    }
}

protocol Versioned { var version: Int { get } }
private struct VersionProbe: Decodable { var version: Int? }
