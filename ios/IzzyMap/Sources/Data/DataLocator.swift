import Foundation

/// Where the offline archives live, as found at launch.
nonisolated struct DataLocation: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        /// DEBUG builds: `-dataDir <path>` on the command line (the simulator
        /// reads the developer's `data/` directory in place).
        case debugDirectory(URL)
        /// Nothing on this device yet.
        case none
    }

    let origin: Origin
    /// Only archives whose file exists.
    let archives: [Archive: URL]

    static let none = DataLocation(origin: .none, archives: [:])

    func url(for archive: Archive) -> URL? { archives[archive] }
    var isEmpty: Bool { archives.isEmpty }
}

/// Resolves the archive files.
///
/// Production data will arrive as Apple-hosted Background Assets packs
/// (docs/NATIVE_PLAN.md §2, milestone 5); this is the single place that
/// learns where they are.
nonisolated enum DataLocator {
    /// Launch argument `-dataDir <path>` lands in UserDefaults' argument domain.
    static let dataDirectoryKey = "dataDir"

    static func locate(defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> DataLocation {
        #if DEBUG
        locate(debugDirectory: defaults.string(forKey: dataDirectoryKey), fileManager: fileManager)
        #else
        locate(debugDirectory: nil, fileManager: fileManager)
        #endif
    }

    static func locate(debugDirectory path: String?, fileManager: FileManager = .default) -> DataLocation {
        if let path, !path.isEmpty {
            return scan(directory: URL(filePath: path, directoryHint: .isDirectory), fileManager: fileManager)
        }
        // TODO(M5): Background Assets packs (vector, topo, …) — ask the pack
        // manager for each archive's file URL here.
        return .none
    }

    /// The archives present in `directory` (missing files are simply absent).
    static func scan(directory: URL, fileManager: FileManager = .default) -> DataLocation {
        var found: [Archive: URL] = [:]
        for archive in Archive.allCases {
            let url = directory.appending(path: archive.fileName, directoryHint: .notDirectory)
            if fileManager.isReadableFile(atPath: url.path(percentEncoded: false)) { found[archive] = url }
        }
        return DataLocation(origin: .debugDirectory(directory), archives: found)
    }
}
