import Foundation
import IzzyKit
import Observation

/// What the Storage screen shows, gathered once per change rather than per
/// frame: the device's free space, the extras' items and where each batch
/// stands (reading those touches the disk), and the pack bytes on the
/// device. Pack states themselves are read live from `PackStore`.
@MainActor @Observable
final class StorageModel {
    let packs: PackStore
    let extras: ExtrasDownloads
    private let trees: TreesData?
    /// Detailed areas (their bytes in the gauge).
    let areas: AreaStore?

    private(set) var volume = VolumeSpace()
    /// Each kind's files (empty until the bundled tables are loaded).
    private(set) var items: [ExtraKind: [ExtraItem]] = [:]
    /// Where each kind stands (a running job, else the files on disk).
    private(set) var extrasStatus: [ExtraKind: ExtrasBatch] = [:]
    /// Bytes of each installed pack (file sizes).
    private(set) var packBytes: [Pack: Int] = [:]
    @ObservationIgnored private var volumeRead = ContinuousClock.now

    init(packs: PackStore, extras: ExtrasDownloads = .shared, trees: TreesData?, areas: AreaStore? = nil) {
        self.packs = packs
        self.extras = extras
        self.trees = trees
        self.areas = areas
    }

    /// Loads the extras' item lists (plant photos need the plant catalog).
    func load() async {
        if items.isEmpty {
            let data = BundledData.inBundle()
            let catalog = await PlantLibrary.shared.load()
            for kind in ExtraKind.allCases {
                items[kind] = ExtrasDownloads.items(kind, data: data, catalog: catalog, trees: trees)
            }
        }
        refresh()
    }

    /// Re-reads free space, pack sizes and the extras' status.
    func refresh() {
        readVolume()
        refreshPacks()
        refreshExtras()
    }

    /// Free space while downloads run: the store calls this on progress
    /// steps (every 5 % of a pack, each extras file) and the screen every
    /// 5 s; re-read at most once a second (a statfs, but several packs can
    /// step at once).
    func refreshVolume() {
        guard volumeRead.duration(to: .now) >= .seconds(1) else { return }
        readVolume()
    }

    private func readVolume() {
        volumeRead = .now
        let now = VolumeSpace.current()
        if now != volume { volume = now }
    }

    /// Changes every 5 % of any pack's download or update (the free-space
    /// refresh's trigger).
    var progressStep: Int {
        var step = 0
        for pack in Pack.allCases {
            if case let .downloading(f?) = packs.state(pack) { step += Int(f * 20) + 1 }
            if let f = packs.updates[pack] { step += Int(f * 20) + 1 }
        }
        return step
    }

    /// Something is arriving (a pack, an update or an extras batch).
    var isBusy: Bool {
        Pack.allCases.contains { if case .downloading = packs.state($0) { true } else { false } }
            || packs.current != nil || !packs.queue.isEmpty
            || !packs.updates.isEmpty || extras.jobs.values.contains { $0.isRunning }
            || areas?.running != nil
    }

    func refreshPacks() {
        var bytes: [Pack: Int] = [:]
        for pack in Pack.allCases where packs.state(pack).isInstalled {
            bytes[pack] = PackSizes.installed(pack, location: packs.location)
        }
        // plant ID's files aren't archives: the folder they're read from
        if bytes[.plantid] != nil, case let .files(folder)? = PlantIDSession.source(packs: packs),
           let size = PackSizes.folder(folder) {
            bytes[.plantid] = size
        }
        packBytes = bytes
    }

    func refreshExtras() {
        for kind in ExtraKind.allCases {
            guard let list = items[kind], !list.isEmpty else { continue }
            extrasStatus[kind] = extras.status(kind, items: list)
        }
    }

    // MARK: Derived

    /// What a pack weighs: on the device, its files; otherwise what it will
    /// take (the archive as built — the download is a little smaller).
    func bytes(_ pack: Pack) -> Int {
        packBytes[pack] ?? PackSizes.nominal[pack] ?? packs.downloadSizes[pack] ?? 0
    }

    func status(_ pack: Pack) -> PackRowStatus {
        PackRowStatus.of(packs.state(pack), pack: pack, canFetch: packs.canFetch, resolved: packs.isResolved,
                         update: packs.updates[pack], online: Connectivity.shared.online,
                         queued: packs.queuePosition(pack), repairing: packs.repairing.contains(pack),
                         blocked: packs.repairBlocked[pack])
    }

    /// Every core pack (maps and plant ID) is on the device and nothing
    /// is arriving for them: the section can fold into one summary row.
    var coreAllHere: Bool { Pack.StorageSection.maps.packs.allSatisfy { status($0) == .onDevice } }

    /// What the core packs take on the device.
    var coreBytes: Int { Pack.StorageSection.maps.packs.reduce(0) { $0 + bytes($1) } }

    var gauge: StorageGauge {
        var parts: [StorageGauge.Category: Int64] = [:]
        for (pack, b) in packBytes {
            parts[pack.gaugeCategory, default: 0] += Int64(b)
        }
        // what a running batch has stored so far counts as it arrives
        parts[.extras] = Int64(extrasStatus.values.reduce(0) { $0 + $1.bytesPresent })
        parts[.areas] = areas?.bytes ?? 0
        return StorageGauge(parts: parts, capacity: volume.capacity, free: volume.free)
    }

    /// The packs of a section that aren't on the device, in the screen's
    /// order (seasons newest first: "Get all" queues them so).
    func missing(_ section: Pack.StorageSection) -> [Pack] {
        section.packs.filter { !packs.state($0).isInstalled }
    }
}
