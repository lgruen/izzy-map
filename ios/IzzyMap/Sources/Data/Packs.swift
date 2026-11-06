import Foundation

/// One Apple-hosted Background Assets pack (docs/NATIVE_PLAN.md §2). Mirrors
/// `pipeline/asset_packs.json` by hand (hand-curated wiring is a repo
/// decision): the raw value is the asset-pack ID in App Store Connect, the
/// files are the archives' `fileName`s at the pack root.
nonisolated enum Pack: String, CaseIterable, Sendable, Identifiable {
    case vector, topo, relief, plantid, refphotos, aerial, tasmap
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
        case .topo, .relief, .plantid, .refphotos: .prefetch
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
        case .refphotos: []
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
        case .refphotos: RefPhotoFiles.packPaths
        default: []
        }
    }

    /// On-demand packs are the ones a person gets and removes; essential and
    /// prefetch packs are the core layers that arrive with the install.
    var isRemovable: Bool { policy == .onDemand }
}

/// The `plantid` pack's files (pipeline/build_packs.py stages them from
/// pipeline/cache/plantid/ship: the 8-bit encoder compiled to .mlmodelc,
/// the single model's tables (IzzyKit `PlantIDModel.files`), the
/// Tasmanian photo bank and the training-photo credits). They sit in a
/// `plantid/` folder: every pack shares ONE namespace on the device.
nonisolated enum PlantIDFiles {
    static let folder = "plantid"
    /// The image encoder, compiled (`xcrun coremlcompiler`): Core ML loads
    /// it in place — no on-device compile, no second 0.6 GB copy.
    static let encoder = "PlantEncoder-w8.mlmodelc"
    /// The model's heads: their presence marks a staged pack (DEBUG `-dataDir`).
    static let head = "v3-head.bin"
    /// The pack path that tells this version's pack from an older one (the
    /// v1 Tasmanian model and the single-head v2 had no v3 files): local
    /// without it = an update on its way, not a failure.
    static let currentMarker = "plantid/v3-head.bin"
    /// The Tasmanian photo bank (the model's Tasmania-box term).
    static let bank = "bank-int8.bin"
    static let pipeline = "pipeline.json"
    static let credits = "credits.json"
    static let photoCredits = "credits-photos.tsv.gz"

    /// Where build_packs.py stages the pack under a developer's `data/`
    /// (a DEBUG `-dataDir` run reads the model there).
    static func staged(in data: URL) -> URL {
        data.appending(path: "packs/stage-plantid/\(folder)", directoryHint: .isDirectory)
    }

    static let packPaths = [
        "plantid/PlantEncoder-w8.mlmodelc/",
        "plantid/bank-int8.bin",
        "plantid/pipeline.json",
        "plantid/credits.json",
        "plantid/credits-photos.tsv.gz",
        "plantid/v3-head.bin",
        "plantid/v3-prior.bin",
        "plantid/v2-labels.json",
    ]
}

/// The `refphotos` pack (prefetch): one reference photo per plant-ID class
/// in a `refphotos/` folder with its `index.json` (file, licence,
/// attribution; pipeline/plantid/build_refphotos_v2.py). Until it has
/// arrived Identify shows a placeholder.
nonisolated enum RefPhotoFiles {
    static let folder = "refphotos"
    static let index = "index.json"

    /// Where a developer's photos sit (DEBUG `-dataDir` runs): the staged
    /// pack, else the pipeline's output beside `data/`.
    static func staged(in data: URL) -> [URL] {
        [data.appending(path: "packs/stage-refphotos/\(folder)", directoryHint: .isDirectory),
         data.appending(path: "../pipeline/cache/plantid/refphotos/pack-v2/\(folder)", directoryHint: .isDirectory),
         data.appending(path: "../pipeline/cache/plantid/refphotos/pack/\(folder)", directoryHint: .isDirectory)]
    }

    /// The folder and its index: the index is a file `url(for:)` resolves,
    /// so the installed check finds the folder through it (a directory alone
    /// may not resolve). Mirrors asset_packs.json.
    static let packPaths = [
        "refphotos/",
        "refphotos/index.json",
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
    /// The App Store doesn't offer it (yet): absent from the server's
    /// manifest, or a fetch answered "no such asset pack". Nothing to tap —
    /// a core pack downloads by itself once it is published.
    case unpublished

    var isInstalled: Bool { self == .installed }
}
