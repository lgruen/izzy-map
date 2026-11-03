import Foundation

/// One Apple-hosted Background Assets pack (docs/NATIVE_PLAN.md §2). Mirrors
/// `pipeline/asset_packs.json` by hand (hand-curated wiring is a repo
/// decision): the raw value is the asset-pack ID in App Store Connect, the
/// files are the archives' `fileName`s at the pack root.
nonisolated enum Pack: String, CaseIterable, Sendable, Identifiable {
    case vector, topo, relief, plantid, aerial, tasmap
    case season2020 = "season-2020", season2021 = "season-2021", season2022 = "season-2022"
    case season2023 = "season-2023", season2024 = "season-2024", season2025 = "season-2025"
    case season2026 = "season-2026"

    /// How the system downloads it (the manifest's `downloadPolicy`).
    nonisolated enum Policy: Sendable {
        /// With the install; the app doesn't open until it is there.
        case essential
        /// Starts with the install, may finish after the first launch.
        case prefetch
        /// Only when the app asks: one tap.
        case onDemand
    }

    var id: String { rawValue }

    var policy: Policy {
        switch self {
        case .vector: .essential
        case .topo, .relief, .plantid: .prefetch
        default: .onDemand
        }
    }

    /// The map archives it holds (plant ID's model files are not archives).
    var archives: [Archive] {
        switch self {
        case .vector: [.tasveg, .geology, .pre1750]
        case .topo: [.topo]
        case .relief: [.relief]
        case .plantid: []
        case .aerial: [.aerial]
        case .tasmap: [.tasmap]
        case .season2020: [.season2020]
        case .season2021: [.season2021]
        case .season2022: [.season2022]
        case .season2023: [.season2023]
        case .season2024: [.season2024]
        case .season2025: [.season2025]
        case .season2026: [.season2026]
        }
    }

    /// Its files that aren't map archives, as paths in the pack (plant ID's
    /// model and tables; a trailing "/" is a directory). Mirrors the pack's
    /// `files` in asset_packs.json (build_packs.py checks).
    var otherFiles: [String] {
        switch self {
        case .plantid: PlantIDFiles.packPaths
        default: []
        }
    }

    /// On-demand packs are the ones a person gets and removes; essential and
    /// prefetch packs are the core layers that arrive with the install.
    var isRemovable: Bool { policy == .onDemand }
}

/// The `plantid` pack's files (pipeline/build_packs.py stages them from
/// pipeline/cache/plantid/ship: the 8-bit encoder compiled to .mlmodelc,
/// the scorer's tables and the training-photo credits). They sit in a
/// `plantid/` folder: every pack shares ONE namespace on the device.
nonisolated enum PlantIDFiles {
    static let folder = "plantid"
    /// The image encoder, compiled (`xcrun coremlcompiler`): Core ML loads
    /// it in place — no on-device compile, no second 0.6 GB copy.
    static let encoder = "PlantEncoder-w8.mlmodelc"
    static let head = "head.bin"
    static let bank = "bank-int8.bin"
    static let prior = "prior.bin"
    static let labels = "labels.json"
    static let pipeline = "pipeline.json"
    static let credits = "credits.json"
    static let photoCredits = "credits-photos.tsv.gz"

    static let packPaths = [
        "plantid/PlantEncoder-w8.mlmodelc/",
        "plantid/head.bin",
        "plantid/bank-int8.bin",
        "plantid/prior.bin",
        "plantid/labels.json",
        "plantid/pipeline.json",
        "plantid/credits.json",
        "plantid/credits-photos.tsv.gz",
    ]
}

extension Archive {
    /// The pack that carries this archive.
    nonisolated var pack: Pack {
        Pack.allCases.first { $0.archives.contains(self) }!
    }
}

/// What the app knows about a pack on this device.
nonisolated enum PackState: Equatable, Sendable {
    /// Not on the device (an on-demand pack nobody asked for yet, or a core
    /// pack still waiting for the system).
    case notInstalled
    /// Downloading; nil fraction until the first progress report.
    case downloading(Double?)
    /// The system paused it (no network, low power, …); it resumes by itself.
    case paused
    /// On the device; its files are readable.
    case installed
    /// The last attempt failed (message for the row); a tap retries.
    case failed(String)

    var isInstalled: Bool { self == .installed }
}
