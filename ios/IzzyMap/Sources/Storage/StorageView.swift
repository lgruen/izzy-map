import IzzyKit
import SwiftUI

/// Offline maps and storage (NATIVE_PLAN §4 "Storage", DESIGN.md "Storage",
/// UX_VISUAL_REVIEW §3.14): what IzzyMap keeps on the device, as pictures
/// first — one stacked bar of what it uses next to the device's free
/// space; every pack with its coverage and a size bar on one shared scale
/// (the paper map visibly the giant); the field-guide extras with an
/// "x of y" fill. Core packs arrive by themselves; every other pack and
/// each extra is one tap to get and one to remove. Pushed from Layers (the
/// sheet's / popover's NavigationStack); Escape closes the whole modal.
struct StorageView: View {
    let model: AppModel
    /// Done in a sheet of its own (iPad: back to the Layers popover); nil
    /// when pushed in the Layers sheet (Done closes the whole modal).
    var done: (() -> Void)?
    /// A section to scroll to on appearing ("areas" after an area's Download).
    var scrollTo: String?
    @State private var storage: StorageModel
    @State private var spaceRequest: PackSpaceRequest?
    @State private var removal: Removal?
    @State private var footprints = FootprintStore.shared

    init(model: AppModel, done: (() -> Void)? = nil, scrollTo: String? = nil) {
        self.model = model
        self.done = done
        self.scrollTo = scrollTo
        _storage = State(initialValue: StorageModel(packs: model.shared.packs, trees: model.tables.trees, areas: model.shared.areas))
    }

    private var packs: PackStore { storage.packs }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .task {
                    // DEBUG screenshots: `-storageScroll more|seasons|extras|areas`
                    #if DEBUG
                    let target = scrollTo ?? UserDefaults.standard.string(forKey: "storageScroll")
                    #else
                    let target = scrollTo
                    #endif
                    guard let target else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
        }
    }

    /// The list starts BELOW the navigation bar, behind a hairline: rows
    /// scrolled past end there instead of passing under the bar, where even
    /// the hard scroll-edge effect left blurred ghosts of section headers
    /// behind the back button (checked 2026-11-03, iOS 27.2 simulator).
    private var list: some View {
        VStack(spacing: 0) {
            Divider()
            rows
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    if let done { done() } else { model.dismissModal() }
                }
            }
        }
    }

    private var rows: some View {
        List {
            Section {
                StorageGaugeView(gauge: storage.gauge)
            }
            .panelRows()

            Section {
                ForEach(Pack.allCases.filter { $0.storageSection == .maps && $0.isListed(packs.state($0)) }) { pack in
                    packRow(pack)
                }
            } header: {
                Text("Core maps").panelHeader()
            } footer: {
                Text("These arrive with the app and stay up to date by themselves.")
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            .panelRows()

            Section {
                ForEach([Pack.aerial, .tasmap]) { packRow($0) }
            } header: {
                Text("Extra maps").panelHeader().id("more")
            } footer: {
                Text("While a map isn't on this \(DeviceNoun.current), it streams when there's reception.")
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            .panelRows()

            Section {
                ForEach(Season.all.reversed(), id: \.year) { packRow($0.archive.pack) }
                allSeasonsRow
            } header: {
                Text("Photos by season").panelHeader().id("seasons")
            } footer: {
                Text("Each season's photos cover only the areas flown that year — the ink on each map.")
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            .panelRows()

            Section {
                ForEach(ExtraKind.displayOrder, id: \.self) { kind in
                    ExtraRow(kind: kind, storage: storage) { removal = .extra(kind) }
                }
            } header: {
                Text("Field guide").panelHeader().id("extras")
            } footer: {
                Text("Fetched by this \(DeviceNoun.current) from their publishers, for your own use. Downloads carry on while IzzyMap is closed.")
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            .panelRows()

            DetailedAreasSection(model: model)
                .panelRows()
        }
        .panelListSurface()
        .listSectionSpacing(.compact)
        .contentMargins(.top, 8, for: .scrollContent)
        .packSpaceAlert($spaceRequest, store: packs)
        .confirmationDialog(removal?.title ?? "", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            titleVisibility: .visible, presenting: removal) { r in
            Button(r.button, role: .destructive) { perform(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text(r.message(storage))
        }
        .task {
            await storage.load()
            await footprints.update(packs.location)
        }
        .onChange(of: packs.location) {
            storage.refresh()
            Task { await footprints.update(packs.location) }
        }
        .onChange(of: storage.extras.jobs) {
            storage.refreshExtras()
            storage.refreshVolume()
        }
        // free space follows the downloads: every 5 % step, and every 5 s
        .onChange(of: storage.progressStep) { storage.refreshVolume() }
        .task(id: storage.isBusy) {
            while storage.isBusy, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                storage.refreshVolume()
            }
        }
        .sensoryFeedback(.success, trigger: packs.states.values.filter(\.isInstalled).count) { old, new in new > old }
        .accessibilityIdentifier("storage")
    }

    // MARK: Packs

    private func packRow(_ pack: Pack) -> some View {
        PackRow(pack: pack, status: storage.status(pack), bytes: storage.bytes(pack), scale: storage.largestPack,
                canRemove: packs.canFetch, thumbnail: { thumbnail(pack) },
                get: { spaceRequest = packs.get([pack], title: pack.storageTitle) },
                resume: { packs.resume(pack) },
                remove: { removal = storage.status(pack).isBusy ? .stop(pack) : .pack(pack) })
    }

    @ViewBuilder private func thumbnail(_ pack: Pack) -> some View {
        let status = storage.status(pack)
        if pack.storageSection != .seasons {
            // statewide: the Layers tile's picture (coverage would be all ink)
            LayerThumb(model: model, pack: pack)
        } else {
            let progress: Double? = if case let .downloading(f) = status { f ?? 0 } else { nil }
            CoverageThumbnail(outline: footprints.outline, footprint: footprints.footprint(pack),
                              installed: status == .onDevice, progress: progress)
        }
    }

    /// "All seasons": one tap gets every season not on the device.
    @ViewBuilder private var allSeasonsRow: some View {
        let missing = storage.missing(.seasons)
        let idle = missing.filter { !storage.status($0).isBusy }
        if !missing.isEmpty {
            let bytes = idle.reduce(0) { $0 + storage.bytes($1) }
            let here = Season.all.count - missing.count
            HStack(spacing: 12) {
                SeasonStack(footprints: footprints, installed: Set(Season.all.map(\.archive.pack).filter { !missing.contains($0) }))
                    .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All seasons").foregroundStyle(DesignColor.ink)
                    Text(idle.isEmpty ? "\(here) of \(Season.all.count) on this \(DeviceNoun.current) · the rest are coming"
                                      : "\(here) of \(Season.all.count) on this \(DeviceNoun.current) · \(StorageText.size(bytes)) to get")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(DesignColor.inkSecondary)
                }
                Spacer(minLength: 8)
                if !idle.isEmpty {
                    GetButton(title: "Get all") {
                        spaceRequest = packs.get(idle, title: "\(idle.count == 1 ? "1 season" : "\(idle.count) seasons") of photos")
                    }
                    .accessibilityLabel("Get all seasons, \(StorageText.size(bytes))")
                    .accessibilityIdentifier("seasons-get-all")
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Removal

    private enum Removal: Identifiable {
        case pack(Pack)
        /// A download under way: stopping it removes what has arrived.
        case stop(Pack)
        case extra(ExtraKind)
        var id: String {
            switch self {
            case let .pack(p): "pack-\(p.rawValue)"
            case let .stop(p): "stop-\(p.rawValue)"
            case let .extra(k): "extra-\(k.rawValue)"
            }
        }
        var title: String {
            switch self {
            case let .pack(p): "Remove \(p.storageTitle)?"
            case let .stop(p): "Stop getting \(p.storageTitle)?"
            case let .extra(k): "Delete all \(k.storageTitle.lowercased())?"
            }
        }
        var button: String {
            switch self {
            case .pack: "Remove from \(DeviceNoun.current)"
            case .stop: "Stop Download"
            case .extra: "Delete"
            }
        }
        @MainActor func message(_ storage: StorageModel) -> String {
            switch self {
            case let .pack(p):
                "Frees \(StorageText.size(storage.bytes(p))). The map streams it while there's reception, and you can get it again any time."
            case .stop:
                "What has arrived is removed. You can get it again any time."
            case let .extra(k):
                "Frees \(StorageText.size(storage.extrasStatus[k]?.bytesPresent ?? 0)). Single \(k.noun)s still open when there's reception."
            }
        }
    }

    private func perform(_ r: Removal) {
        switch r {
        case let .pack(p), let .stop(p):
            Task { await packs.remove(p) }
        case let .extra(k):
            Task {
                await storage.extras.delete(k)
                storage.refresh()
            }
        }
    }
}

// MARK: - Metrics

enum StorageMetrics {
    /// Tasmania's proportions (with King Island and the Furneaux Group).
    static let thumbWidth: CGFloat = 46
    static let thumbHeight: CGFloat = 52
}

// MARK: - Gauge

/// One bar: IzzyMap's categories in ink tones, then free space empty —
/// then the key under it.
struct StorageGaugeView: View {
    let gauge: StorageGauge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("IzzyMap uses \(Text(StorageText.size(Int(gauge.izzyBytes))).monospacedDigit())")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                if let free = gauge.freeBytes {
                    // the bar is IzzyMap + free (everything else on the
                    // device stays out), so no "of <capacity>" here
                    Text("\(StorageText.size(Int(free))) free on this \(DeviceNoun.current)")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(DesignColor.inkSecondary)
                }
            }
            GeometryReader { proxy in
                let gap: CGFloat = 1.5
                let n = gauge.segments.count
                let widths = gauge.widths(in: max(0, proxy.size.width - gap * CGFloat(max(0, n - 1))))
                HStack(spacing: gap) {
                    ForEach(Array(gauge.segments.enumerated()), id: \.element.id) { i, segment in
                        GaugeSwatch(kind: segment.kind)
                            .frame(width: widths[i])
                    }
                }
            }
            .frame(height: 16)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(gauge.segments) { segment in
                    HStack(spacing: 6) {
                        GaugeSwatch(kind: segment.kind)
                            .frame(width: 12, height: 12)
                            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                        Text(segment.kind.title)
                            .foregroundStyle(DesignColor.ink)
                        Text(StorageText.size(Int(segment.bytes)))
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.inkSecondary)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage-gauge")
    }
}

extension StorageGauge.Segment.Kind {
    var title: String {
        switch self {
        case let .izzy(c): c.title
        case .free: "Free"
        }
    }
}

/// A segment's fill: ink tones for IzzyMap (darkest = the core maps),
/// nothing for free space.
private struct GaugeSwatch: View {
    let kind: StorageGauge.Segment.Kind

    var body: some View {
        switch kind {
        case let .izzy(category):
            Rectangle().fill(DesignColor.ink.opacity(Self.ink[category] ?? 1))
        case .free:
            Rectangle().fill(Color.clear)
        }
    }

    static let ink: [StorageGauge.Category: Double] = [.maps: 1, .moreMaps: 0.6, .extras: 0.36, .areas: 0.2]
}

// MARK: - Rows

/// One pack: its picture, name, status, a size bar on the shared scale,
/// and one control (Get / progress / remove).
private struct PackRow<Thumb: View>: View {
    let pack: Pack
    let status: PackRowStatus
    let bytes: Int
    let scale: Int
    let canRemove: Bool
    @ViewBuilder let thumbnail: () -> Thumb
    let get: () -> Void
    let resume: () -> Void
    let remove: () -> Void

    /// A download under way that Stop can end (swipe, VoiceOver action).
    private var canStop: Bool { status.isBusy && pack.isRemovable && canRemove }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail()
                .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pack.storageTitle)
                            .foregroundStyle(DesignColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(status.text(bytes: bytes, device: DeviceNoun.current))
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(DesignColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pack-\(pack.rawValue)-status")
                    }
                    Spacer(minLength: 0)
                    PackControl(pack: pack, status: status, canRemove: canRemove, get: get, resume: resume, remove: remove)
                }
                // under the text AND the control: every row's track is the
                // same width, so the scale is one scale down the screen
                SizeBar(extent: Double(bytes) / Double(max(1, scale)), fill: status.fill)
                if let note = pack.storageNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .swipeActions(edge: .trailing) {
            if canStop {
                Button("Stop", systemImage: "stop.fill", action: remove).tint(.red)
            }
        }
        .accessibilityActions {
            if canStop { Button("Stop download", action: remove) }
        }
    }
}

/// The row's single control.
private struct PackControl: View {
    let pack: Pack
    let status: PackRowStatus
    /// False for a developer's `-dataDir` folder (read as it is).
    let canRemove: Bool
    let get: () -> Void
    let resume: () -> Void
    let remove: () -> Void

    var body: some View {
        switch status {
        case .get, .arriving:
            GetButton(title: "Get", action: get)
                .accessibilityLabel("Get \(pack.storageTitle)")
                .accessibilityIdentifier("pack-\(pack.rawValue)-get")
        case .failed:
            GetButton(title: "Retry", action: get)
                .accessibilityLabel("Try \(pack.storageTitle) again")
                .accessibilityIdentifier("pack-\(pack.rawValue)-get")
        case let .downloading(f):
            ringButton(fraction: f, symbol: pack.isRemovable ? "stop.fill" : nil, action: remove)
                .disabled(!pack.isRemovable)
                .accessibilityLabel(pack.isRemovable ? "Stop downloading \(pack.storageTitle)" : "Downloading")
                .accessibilityValue(f.map { "\(Int($0 * 100)) percent" } ?? "")
                .accessibilityIdentifier("pack-\(pack.rawValue)-progress")
        case .paused:
            // a still ring, and the action it offers: carry on (Stop is
            // the row's swipe / VoiceOver action)
            ringButton(fraction: 0, symbol: "arrow.down", action: resume)
                .accessibilityLabel("Resume \(pack.storageTitle)")
                .accessibilityIdentifier("pack-\(pack.rawValue)-resume")
        case let .updating(f):
            // the installed version keeps serving: nothing to stop
            ProgressRing(fraction: f, lineWidth: 2.5)
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .accessibilityElement()
                .accessibilityLabel("Updating")
                .accessibilityValue("\(Int(f * 100)) percent")
                .accessibilityIdentifier("pack-\(pack.rawValue)-updating")
        case .onDevice where pack.isRemovable && canRemove:
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Remove \(pack.storageTitle)")
            .accessibilityIdentifier("pack-\(pack.rawValue)-remove")
        case .onDevice:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(DesignColor.inkSecondary)
                .frame(width: 44, height: 44)
                .accessibilityLabel("On this \(DeviceNoun.current)")
        case .checking:
            ProgressView().frame(width: 44, height: 44)
        case .unavailable:
            EmptyView()
        }
    }

    /// Progress ring with the tap's glyph in it.
    private func ringButton(fraction: Double?, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                ProgressRing(fraction: fraction, lineWidth: 2.5)
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(DesignColor.ink)
            .frame(width: 28, height: 28)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// The App-Store-style capsule: ink outline, ink text.
struct GetButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(DesignColor.ink.opacity(0.08), in: .capsule)
                .overlay { Capsule().strokeBorder(DesignColor.ink.opacity(0.35), lineWidth: 0.5) }
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// A size on ONE shared scale, visible on every row: a faint full-width
/// track is the largest pack (the paper map, 3.24 GB); the item's own
/// length on it is grey, and the part on the device is ink. Tiny items
/// stay tiny — that's the truth of 30 MB beside 3 GB.
struct SizeBar: View {
    /// The item's length as a share of the track (the largest item = 1).
    let extent: Double
    /// How much of the item is on the device.
    let fill: Double

    var body: some View {
        GeometryReader { proxy in
            let length = max(2, proxy.size.width * min(1, max(0, extent)))
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignColor.ink.opacity(0.08))
                Rectangle().fill(DesignColor.ink.opacity(0.28))
                    .frame(width: length)
                Rectangle().fill(DesignColor.ink)
                    .frame(width: length * min(1, max(0, fill)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The Layers tile's picture for a statewide pack (one identity per pack,
/// the same as in Layers), or its symbol until it has rendered.
private struct LayerThumb: View {
    let model: AppModel
    let pack: Pack
    @Environment(LayerThumbnails.self) private var thumbnails
    @Environment(\.displayScale) private var scale

    private var subject: ThumbnailSubject? {
        switch pack {
        case .vector: .overlay(.vegetation)
        case .topo: .base(.topo)
        case .relief: .relief
        case .aerial: .base(.aerial)
        case .tasmap: .base(.tasmap)
        default: nil
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            Image(systemName: pack == .plantid ? "leaf" : "map")
                .foregroundStyle(DesignColor.inkSecondary)
        }
        .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
        .overlay {
            if let subject, let image = thumbnails.image(subject, state: model.layers, data: model.data, scale: scale) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            }
        }
        .clipped()
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .accessibilityHidden(true)
        .task(id: model.data) {
            guard let subject else { return }
            await thumbnails.load(subject, current: model.layers, data: model.data, tables: model.tables, scale: scale)
        }
    }
}

/// The seven seasons' footprints in one plate: ink where a season on the
/// device has photos, grey where the missing ones would add them.
private struct SeasonStack: View {
    let footprints: FootprintStore
    let installed: Set<Pack>

    var body: some View {
        let packs = Season.all.map(\.archive.pack)
        let have = Footprint.union(packs.filter { installed.contains($0) }.compactMap { footprints.footprint($0) })
        let rest = Footprint.union(packs.filter { !installed.contains($0) }.compactMap { footprints.footprint($0) })
        CoverageThumbnail(outline: footprints.outline, footprint: have, installed: true, under: rest)
    }
}

// MARK: - Extras

extension ExtraKind {
    static let displayOrder: [ExtraKind] = [.f2f, .photos, .sheets]

    var storageTitle: String {
        switch self {
        case .f2f: "Community descriptions"
        case .photos: "Plant photos"
        case .sheets: "Tree data sheets"
        }
    }

    var storageSource: String {
        switch self {
        case .f2f: "From Forest to Fjaeldmark, NRE Tasmania"
        case .photos: "Understorey Network photographers"
        case .sheets: "City of Hobart"
        }
    }

    var symbol: String {
        switch self {
        case .f2f: "book.pages"
        case .photos: "photo.on.rectangle"
        case .sheets: "doc.text"
        }
    }

    var noun: String {
        switch self {
        case .f2f: "chapter"
        case .photos: "photo"
        case .sheets: "sheet"
        }
    }

    func count(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? noun : noun + "s")" }

    /// "3 no longer published"
    func goneNote(_ n: Int) -> String {
        switch self {
        case .photos: "\(count(n)) no longer on the Understorey Network site"
        default: "\(count(n)) no longer published"
        }
    }
}

/// One extra: what it is, how much of it is here (a fill bar of its own
/// total), and one tap to get, stop, resume or delete.
private struct ExtraRow: View {
    let kind: ExtraKind
    let storage: StorageModel
    let delete: () -> Void

    private var batch: ExtrasBatch? { storage.extrasStatus[kind] }
    private var isRunning: Bool { storage.extras.jobs[kind]?.isRunning == true }
    private var items: [ExtraItem] { storage.items[kind] ?? [] }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
            .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.storageTitle).foregroundStyle(DesignColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(statusText)
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(DesignColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("extra-\(kind.rawValue)-status")
                    }
                    Spacer(minLength: 0)
                    control
                }
                if let batch, batch.totalBytes > 0 {
                    // the packs' scale: 30 MB beside 3.24 GB is a sliver
                    SizeBar(extent: Double(batch.totalBytes) / Double(max(1, storage.largestPack)),
                            fill: Double(batch.bytesPresent) / Double(batch.totalBytes))
                }
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        guard let batch, !items.isEmpty else { return "Loading…" }
        let total = StorageText.size(batch.totalBytes)
        if isRunning {
            return "\(kind.noun.capitalized) \(min(batch.done + 1, items.count).formatted()) of \(items.count.formatted()) · \(StorageText.fraction(batch.bytesPresent, of: batch.totalBytes))"
        }
        if case let .stopped(stop) = batch.phase, stop != .cancelled { return batch.statusText }
        if batch.done == 0 { return "\(kind.count(items.count)) · \(total)" }
        if batch.todo.isEmpty { return "On this \(DeviceNoun.current) · \(StorageText.size(batch.bytesPresent))" }
        return "\(batch.done.formatted()) of \(items.count.formatted()) · \(StorageText.fraction(batch.bytesPresent, of: batch.totalBytes))"
    }

    private var notes: [String] {
        guard let batch else { return [] }
        var out: [String] = []
        if batch.goneCount > 0 { out.append(kind.goneNote(batch.goneCount)) }
        if batch.skippedCount > 0, !isRunning { out.append("\(kind.count(batch.skippedCount)) failed — tried again next time IzzyMap opens") }
        return out
    }

    @ViewBuilder private var control: some View {
        if let batch, !items.isEmpty {
            if isRunning {
                Button { storage.extras.cancel(kind) } label: {
                    ZStack {
                        ProgressRing(fraction: Double(batch.done) / Double(max(1, items.count)), lineWidth: 2.5)
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(DesignColor.ink)
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop getting \(kind.storageTitle.lowercased())")
                .accessibilityIdentifier("extra-\(kind.rawValue)-stop")
            } else {
                HStack(spacing: 0) {
                    if batch.done > 0 {
                        Button(action: delete) {
                            Image(systemName: "trash")
                                .foregroundStyle(DesignColor.inkSecondary)
                                .frame(width: 40, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityLabel("Delete \(kind.storageTitle.lowercased())")
                        .accessibilityIdentifier("extra-\(kind.rawValue)-delete")
                    }
                    if !batch.todo.isEmpty {
                        GetButton(title: batch.done > 0 ? "Resume" : "Get") {
                            storage.extras.start(kind, items: items)
                            storage.refreshExtras()
                        }
                        .accessibilityLabel("\(batch.done > 0 ? "Resume" : "Get") \(kind.storageTitle.lowercased())")
                        .accessibilityIdentifier("extra-\(kind.rawValue)-get")
                    }
                }
            }
        }
    }
}
