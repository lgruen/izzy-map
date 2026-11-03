import Foundation
import IzzyKit

// The Storage screen's rules, kept free of views so they're unit-tested:
// what each pack is called and weighs, what its row says, the gauge's
// segments, and the space preflight before a fetch.

/// Sizes of the packs' archives as built (bytes; `ls -l data/`, 2026-11-03).
/// Packs hold the PMTiles byte for byte, so this is what a pack takes on the
/// device; the server manifest's `downloadSize` (the compressed `.aar`, 3–7 %
/// smaller) replaces it for the download line once it is known.
nonisolated enum PackSizes {
    static let nominal: [Pack: Int] = [
        .vector: 368_297_665 + 5_702_849 + 24_146_929,
        .topo: 2_044_499_329,
        .relief: 1_287_558_760,
        // plant ID's files as staged by build_packs.py (w8 encoder + tables, 2026-11-04)
        .plantid: 726_966_623,
        .aerial: 1_929_244_001,
        .tasmap: 3_242_875_247,
        .season2020: 282_812_458,
        .season2021: 212_271_323,
        .season2022: 343_383_074,
        .season2023: 522_303_699,
        .season2024: 994_943_287,
        .season2025: 706_261_270,
        .season2026: 425_931_912,
    ]

    /// Bytes on the device: the archives' file sizes where they are
    /// readable, else the nominal size.
    static func installed(_ pack: Pack, location: DataLocation, fileManager: FileManager = .default) -> Int {
        let files = pack.archives.compactMap { location.url(for: $0) }
        guard !files.isEmpty, files.count == pack.archives.count else { return nominal[pack] ?? 0 }
        return files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}

extension Pack {
    /// Where the Storage screen lists it.
    nonisolated enum StorageSection: Sendable { case maps, moreMaps, seasons }

    nonisolated var storageSection: StorageSection {
        switch self {
        case .vector, .topo, .relief, .plantid: .maps
        case .aerial, .tasmap: .moreMaps
        default: .seasons
        }
    }

    nonisolated var season: Season? { archives.first.flatMap { a in Season.all.first { $0.archive == a } } }

    /// The row's name.
    nonisolated var storageTitle: String {
        switch self {
        case .vector: "Vegetation, geology, pre-1750"
        case .topo: "Topographic map"
        case .relief: "Relief shading"
        case .plantid: "Plant identification"
        case .aerial: "Aerial photos"
        case .tasmap: "Paper map"
        default: season.map { "\($0.label) photos" } ?? rawValue
        }
    }

    /// A short second name (the source), shown in VoiceOver and under
    /// statewide packs.
    nonisolated var storageSource: String {
        switch self {
        case .vector: "TASVEG 5.0, MRT geology, NVIS pre-1750"
        case .topo: "theLIST topographic basemap"
        case .relief: "theLIST hillshade"
        case .plantid: "On-device plant model"
        case .aerial: "theLIST statewide mosaic"
        case .tasmap: "Tasmap scans, 1:25,000–1:500,000"
        default: "theLIST flying season"
        }
    }

    /// The note under the row (the season still being flown).
    nonisolated var storageNote: String? {
        season?.isIncomplete == true ? "Still being flown — more areas appear over time." : nil
    }

    /// The Storage screen shows plant ID only once it exists (milestone 6).
    nonisolated func isListed(_ state: PackState) -> Bool {
        self != .plantid || state != .notInstalled
    }
}

/// What a pack's row shows and offers.
nonisolated enum PackRowStatus: Equatable, Sendable {
    /// Why a download stands still, as far as the app can tell: no network
    /// at all, or the system holding it (Low Power Mode, a busy device, …).
    nonisolated enum PauseReason: Equatable, Sendable { case offline, system }

    /// The store hasn't looked yet (the first moments after launch).
    case checking
    case onDevice
    /// On the device, and a new version is arriving in the background (the
    /// installed one keeps serving; nothing to stop).
    case updating(Double)
    /// On-demand and not here: one tap gets it.
    case get
    /// The system is fetching it (nil until the first progress report).
    case downloading(Double?)
    /// The download stands still; Resume asks for it again.
    case paused(PauseReason)
    /// The last attempt failed; a tap tries again.
    case failed
    /// A core pack the system hasn't delivered yet (a tap asks again).
    case arriving
    /// Nothing can fetch it here (a developer's `-dataDir` folder without it).
    case unavailable

    static func of(_ state: PackState, pack: Pack, canFetch: Bool, resolved: Bool = true,
                   update: Double? = nil, online: Bool = true) -> PackRowStatus {
        switch state {
        case .installed: return update.map { .updating($0) } ?? .onDevice
        case let .downloading(f): return .downloading(f)
        case .paused: return .paused(online ? .system : .offline)
        case .failed: return canFetch ? .failed : .unavailable
        case .notInstalled:
            guard resolved else { return .checking }
            guard canFetch else { return .unavailable }
            return pack.policy == .onDemand ? .get : .arriving
        }
    }

    /// A tap on the row's control starts a fetch.
    var offersGet: Bool { self == .get || self == .failed || self == .arriving }
    /// A download of a pack that isn't on the device yet is under way
    /// (Stop removes what has arrived). An update is not: the pack is here.
    var isBusy: Bool {
        switch self {
        case .downloading, .paused: true
        default: false
        }
    }

    var isPaused: Bool { if case .paused = self { true } else { false } }

    /// The bar fill: 1 on the device, the fraction while downloading.
    var fill: Double {
        switch self {
        case .onDevice, .updating: 1
        case let .downloading(f): f ?? 0
        default: 0
        }
    }

    /// The row's status line. Figures never break inside ("438 of 706 MB"
    /// holds together; lines wrap only at " · "); the ring carries the
    /// percentage, so the line doesn't repeat it.
    func text(bytes: Int, device: String) -> String {
        let size = StorageText.size(bytes)
        switch self {
        case .checking: return "Checking…"
        case .onDevice: return "On this \(device) · \(size)"
        case let .updating(f):
            return "Updating\u{00A0}\(StorageText.percent(f)) · \(size)"
        case .get: return size
        case let .downloading(f?): return StorageText.fraction(Int(Double(bytes) * f), of: bytes)
        case .downloading(nil): return "Waiting to start · \(size)"
        case .paused(.offline): return "Waiting for a connection · \(size)"
        case .paused(.system): return "Paused by iOS · resumes on its own · \(size)"
        case .failed: return "Didn't finish · \(size)"
        case .arriving: return "Arrives with the app · \(size)"
        case .unavailable: return "Not in the developer data folder"
        }
    }
}

/// Sizes as Apple's storage screens write them (decimal units).
nonisolated enum StorageText {
    /// "398 MB", "1.93 GB", "41 GB" (whole GB from 10 up); no-break space before the unit.
    static func size(_ bytes: Int) -> String {
        let b = Double(max(0, bytes))
        if b < 1e9 { return ExtrasText.megabytes(Int(b)) }
        let gb = b / 1e9
        let digits = gb < 10 ? String(format: "%.2f", gb) : String(Int(gb.rounded()))
        return digits + "\u{00A0}GB"
    }

    /// "62 %" (rounded down: 100 % only when it's all there).
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))\u{00A0}%"
    }

    /// "6.6 of 30 MB", "1.20 of 1.93 GB": the part in the whole's unit, with
    /// no-break spaces, so a line never splits the figure.
    static func fraction(_ part: Int, of whole: Int) -> String {
        let w = size(whole)
        let gb = Double(max(0, whole)) >= 1e9
        let p = Double(max(0, part)) / (gb ? 1e9 : 1e6)
        let digits = gb ? (Double(whole) < 1e10 ? String(format: "%.2f", p) : String(Int(p.rounded())))
            : (p < 10 ? String(format: "%.1f", p) : String(Int(p.rounded())))
        return "\(digits)\u{00A0}of\u{00A0}\(w)"
    }

    /// "about 2.1 GB" for the preflight (rounded up a little).
    static func about(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1e9 { return ExtrasText.megabytes(Int((b / 1e6).rounded(.up) * 1e6)) }
        return String(format: "%.1f", (b / 1e8).rounded(.up) / 10) + "\u{00A0}GB"
    }
}

/// The stacked bar at the top of the Storage screen: what IzzyMap keeps,
/// by category, then the device's free space — the room it can still grow
/// into. Everything else on the device stays out of the bar (on a 128 GB
/// phone it would shrink IzzyMap's categories to slivers); the capacity is
/// said in words.
nonisolated struct StorageGauge: Equatable, Sendable {
    nonisolated enum Category: String, CaseIterable, Sendable {
        case maps, moreMaps, extras, areas
        var title: String {
            switch self {
            case .maps: "Core maps"
            case .moreMaps: "Extra maps"
            case .extras: "Field guide"
            case .areas: "Detailed areas"
            }
        }
    }

    nonisolated struct Segment: Equatable, Sendable, Identifiable {
        nonisolated enum Kind: Equatable, Sendable, Hashable {
            case izzy(Category)
            case free
        }
        let kind: Kind
        let bytes: Int64
        var id: Kind { kind }
    }

    /// IzzyMap's categories with any bytes, in `Category` order, then free.
    let segments: [Segment]
    let izzyBytes: Int64
    let freeBytes: Int64?
    let capacityBytes: Int64?

    /// `capacity`: the volume's size (words only); `free`: available for
    /// important usage (it includes purgeable space).
    init(parts: [Category: Int64], capacity: Int64?, free: Int64?) {
        var segments: [Segment] = []
        var izzy: Int64 = 0
        for category in Category.allCases {
            let bytes = max(0, parts[category] ?? 0)
            izzy += bytes
            if bytes > 0 { segments.append(Segment(kind: .izzy(category), bytes: bytes)) }
        }
        let free = free.map { max(0, $0) }
        if let free, free > 0 { segments.append(Segment(kind: .free, bytes: free)) }
        self.segments = segments
        izzyBytes = izzy
        freeBytes = free
        capacityBytes = capacity
    }

    /// The bar's span: IzzyMap plus free space.
    var totalBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }

    /// IzzyMap's share of what it could have (IzzyMap + free), 0…1.
    var izzyShare: Double { totalBytes > 0 ? Double(izzyBytes) / Double(totalBytes) : 0 }

    /// Each segment's width in `width` points. A segment with any bytes is
    /// at least `minimum` wide (30 MB of F2F on a 128 GB phone must still
    /// show); the widest segment gives up what that costs.
    func widths(in width: Double, minimum: Double = 3) -> [Double] {
        let total = Double(totalBytes)
        guard total > 0, width > 0 else { return segments.map { _ in 0 } }
        var w = segments.map { Double($0.bytes) / total * width }
        let floor = min(minimum, width / Double(max(1, segments.count)))
        var debt = 0.0
        for i in w.indices where w[i] < floor {
            debt += floor - w[i]
            w[i] = floor
        }
        if debt > 0, let widest = w.indices.max(by: { w[$0] < w[$1] }) {
            w[widest] = max(floor, w[widest] - debt)
        }
        return w
    }

    /// "IzzyMap 6.1 GB · 41 GB free"
    func summary() -> String {
        var parts = ["IzzyMap \(StorageText.size(Int(izzyBytes)))"]
        if let freeBytes { parts.append("\(StorageText.size(Int(freeBytes))) free") }
        return parts.joined(separator: " · ")
    }
}

/// Room for a download? A pack is unpacked beside its download, so while it
/// arrives both are on the device (how long the download stays afterwards is
/// not documented, and unverified on a device — NATIVE_PLAN §2 "On-disk
/// form"; this errs on the safe side): the need is the download plus the
/// unpacked pack plus a margin the system keeps for itself.
nonisolated enum SpacePreflight {
    static let margin: Int64 = 500_000_000

    /// Download + unpacked size of `packs` (the download's size from the
    /// server manifest when known, else the unpacked size — the download is
    /// 3–7 % smaller, so that errs safe).
    static func need(_ packs: [Pack], downloadSizes: [Pack: Int]) -> Int64 {
        packs.reduce(0) { sum, pack in
            let unpacked = Int64(PackSizes.nominal[pack] ?? downloadSizes[pack] ?? 0)
            return sum + Int64(downloadSizes[pack] ?? Int(unpacked)) + unpacked
        }
    }

    /// nil when there is room (or free space is unknown: the system decides),
    /// else the bytes the download needs.
    static func shortfall(need: Int64, free: Int64?) -> Int64? {
        guard let free, need > 0 else { return nil }
        return free < need + margin ? need : nil
    }
}

/// The device's volume, as the system reports it to apps.
nonisolated struct VolumeSpace: Equatable, Sendable {
    var capacity: Int64?
    var free: Int64?

    /// `volumeAvailableCapacityForImportantUsage`: what a user-requested
    /// download may count on (the system purges caches to make it).
    static func current(at url: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)) -> VolumeSpace {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return VolumeSpace(capacity: values?.volumeTotalCapacity.map(Int64.init),
                           free: values?.volumeAvailableCapacityForImportantUsage)
    }
}
