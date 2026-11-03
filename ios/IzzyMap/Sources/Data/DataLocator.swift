import Foundation

/// Where the offline archives live, as found at launch.
nonisolated struct DataLocation: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        /// DEBUG builds: `-dataDir <path>` on the command line (the simulator
        /// reads the developer's `data/` directory in place).
        case debugDirectory(URL)
        /// The Apple-hosted Background Assets packs on the device (`PackStore`).
        case assetPacks
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

/// The DEBUG `-dataDir` override: archives read in place from a directory.
/// Production data is the Background Assets packs (`PackStore`).
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
