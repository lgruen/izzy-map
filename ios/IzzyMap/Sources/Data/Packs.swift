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

    /// On-demand packs are the ones a person gets and removes; essential and
    /// prefetch packs are the core layers that arrive with the install.
    var isRemovable: Bool { policy == .onDemand }
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
