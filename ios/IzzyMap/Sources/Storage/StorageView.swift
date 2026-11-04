import IzzyKit
import SwiftUI

/// Offline maps and storage (NATIVE_PLAN §4 "Storage", DESIGN.md "Storage"),
/// ordered by what she comes back for: the gauge (the ONE picture of space),
/// detailed areas (the thing to do once everything else is in), the core
/// maps and plant ID (folded into one row while all are here), extra maps,
/// seasons, the field guide. Every row says its STATE in words — "On this
/// iPhone · 2.04 GB", "Downloading 62 % · …" — and shows a progress bar only
/// while bytes are arriving; sizes are figures, never bars. Pushed from
/// Layers (the sheet's / popover's NavigationStack); Escape closes the
/// whole modal.
struct StorageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The core section unfolded by hand (it unfolds by itself while any
    /// core pack isn't simply on the device).
    @State private var coreExpanded = false
    /// The row `scrollTo` named, ringed for a moment.
    @State private var highlighted: String?
    @State private var showsDiagnostics = false

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
                    let row = StorageTarget.pack(target)
                    if let row, row.storageSection == .maps { coreExpanded = true }
                    try? await Task.sleep(for: .milliseconds(600))
                    // a row's identity is its ForEach's (the pack's id)
                    withAnimation(reduceMotion ? nil : .default) {
                        if let row { proxy.scrollTo(row.id, anchor: .center) } else { proxy.scrollTo(target, anchor: .top) }
                    }
                    guard row != nil else { return }
                    withAnimation(.easeIn(duration: 0.2)) { highlighted = target }
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.easeOut(duration: 0.8)) { highlighted = nil }
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
                    // hidden: what the system and the app think of each pack
                    .onLongPressGesture(minimumDuration: 1.2) { showsDiagnostics = true }
            }
            .panelRows()

            // what she comes back for once the rest is in
            DetailedAreasSection(model: model)
                .panelRows()

            coreSection
                .panelRows()

            Section {
                ForEach(Pack.StorageSection.moreMaps.packs) { packRow($0) }
            } header: {
                Text("Extra maps").panelHeader().id("more")
            } footer: {
                Text("While a map isn't on this \(DeviceNoun.current), it streams when there's reception.")
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .panelRows()

            Section {
                ForEach(Pack.StorageSection.seasons.packs) { packRow($0) }
                allSeasonsRow
            } header: {
                Text("Photos by season").panelHeader().id("seasons")
            } footer: {
                Text("Each season's photos cover only the areas flown that year — the ink on each map.")
                    .foregroundStyle(DesignColor.secondaryInk)
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
                    .foregroundStyle(DesignColor.secondaryInk)
            }
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
            // system truth first: a row's "Didn't finish" from an earlier
            // moment never outlives what the system says now
            await packs.resync()
            await storage.load()
            await footprints.update(packs.location)
        }
        // …and again while the screen is open (a download the system
        // finished or resumed by itself shows without a tap)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await packs.resync()
                storage.refreshPacks()
            }
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
        // "pack installed" plays from the map's status slot (MapStatusStack),
        // which is always there — here it would play twice
        .sheet(isPresented: $showsDiagnostics) {
            NavigationStack {
                PackDiagnosticsView(packs: packs)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { showsDiagnostics = false }
                        }
                    }
            }
        }
        .accessibilityIdentifier("storage")
    }

    // MARK: Packs

    /// The packs that arrive with the app. All here and settled: one row
    /// ("On this iPhone · 4.46 GB ✓") that unfolds to the four; anything
    /// arriving, updating or stuck: the four rows, each with its state.
    private var coreSection: some View {
        let folds = storage.coreAllHere
        return Section {
            if folds {
                CoreSummaryRow(bytes: storage.coreBytes, expanded: coreExpanded, thumbnail: { thumbnail(.vector) }) {
                    withAnimation(reduceMotion ? nil : .snappy) { coreExpanded.toggle() }
                }
            }
            if !folds || coreExpanded {
                ForEach(Pack.StorageSection.maps.packs) { packRow($0) }
            }
        } header: {
            Text("Core maps & plant ID").panelHeader().id(StorageTarget.core)
        } footer: {
            Text("These arrive with the app and stay up to date by themselves — plant identification too.")
                .foregroundStyle(DesignColor.secondaryInk)
        }
    }

    private func packRow(_ pack: Pack) -> some View {
        let id = StorageTarget.row(pack)
        return PackRow(pack: pack, status: storage.status(pack), bytes: storage.bytes(pack),
                       canRemove: packs.canFetch, thumbnail: { thumbnail(pack) },
                       get: { spaceRequest = packs.get([pack], title: pack.storageTitle) },
                       resume: { packs.resume(pack) },
                       remove: { removal = storage.status(pack).isBusy ? .stop(pack) : .pack(pack) })
            .background {
                Rectangle().fill(DesignColor.ink.opacity(highlighted == id ? 0.1 : 0))
                    .padding(.horizontal, -20).padding(.vertical, -8)
            }
    }

    @ViewBuilder private func thumbnail(_ pack: Pack) -> some View {
        if pack.storageSection != .seasons {
            // statewide: the Layers tile's picture (coverage would be all ink)
            LayerThumb(model: model, pack: pack)
        } else {
            // ink = on the device, grey = not (yet); the row's bar is the
            // one progress indicator
            CoverageThumbnail(outline: footprints.outline, footprint: footprints.footprint(pack),
                              installed: packs.state(pack).isInstalled)
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
                        .foregroundStyle(DesignColor.secondaryInk)
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

/// One bar: IzzyMap's four categories, each in its own fill, then free
/// space empty — then the key under it, its swatches the same fills.
struct StorageGaugeView: View {
    let gauge: StorageGauge
    /// A segment is at least this wide, so its fill can be told apart (on a
    /// 512 GB phone IzzyMap is a sliver; the figures say the exact sizes).
    static let minimumSegment: CGFloat = 16

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
                        .foregroundStyle(DesignColor.secondaryInk)
                }
            }
            GeometryReader { proxy in
                let gap: CGFloat = 2
                let n = gauge.segments.count
                let widths = gauge.widths(in: max(0, proxy.size.width - gap * CGFloat(max(0, n - 1))),
                                          minimum: Self.minimumSegment)
                HStack(spacing: gap) {
                    ForEach(Array(gauge.segments.enumerated()), id: \.element.id) { i, segment in
                        GaugeFill(kind: segment.kind)
                            .frame(width: widths[i])
                    }
                }
            }
            .frame(height: 18)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(gauge.segments) { segment in
                    HStack(spacing: 6) {
                        GaugeFill(kind: segment.kind)
                            .frame(width: 14, height: 14)
                            .overlay {
                                if segment.kind == .free { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                            }
                        Text(segment.title)
                            .foregroundStyle(DesignColor.ink)
                        Text(StorageText.size(Int(segment.bytes)))
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
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

/// A gauge segment's fill — the same view in the bar and in the key, so a
/// swatch IS its segment. Four fills, four meanings, told apart by FORM as
/// well as tone (solid, diagonal hatch, dots, horizontal rules — all in ink,
/// so they hold in light and dark); free space is the empty remainder. No
/// grey anywhere: on this screen nothing else may look like a category.
struct GaugeFill: View {
    let kind: StorageGauge.Segment.Kind

    var body: some View {
        switch kind {
        case .free:
            Rectangle().fill(Color.clear)
        case let .izzy(category):
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size)
                switch category {
                case .maps:
                    ctx.fill(Path(r), with: .foreground)
                case .moreMaps:
                    var p = Path()
                    let pitch: CGFloat = 4
                    var x = -size.height
                    while x < size.width {
                        p.move(to: CGPoint(x: x, y: size.height))
                        p.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += pitch
                    }
                    ctx.stroke(p, with: .foreground, lineWidth: 1.4)
                case .plantID:
                    var p = Path()
                    let pitch: CGFloat = 3.5
                    var row = 0
                    var y = pitch / 2
                    while y < size.height {
                        var x = (row.isMultiple(of: 2) ? pitch / 2 : pitch)
                        while x < size.width {
                            p.addEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                            x += pitch
                        }
                        y += pitch
                        row += 1
                    }
                    ctx.fill(p, with: .foreground)
                case .extras, .areas:
                    var p = Path()
                    var y: CGFloat = 2
                    while y < size.height {
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        y += 4
                    }
                    ctx.stroke(p, with: .foreground, lineWidth: 1.2)
                }
                // every filled block keeps an ink edge, so a sparse fill
                // still reads as one block beside the empty free space
                ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .foreground, lineWidth: 1)
            }
            .foregroundStyle(DesignColor.ink)
            .clipped()
        }
    }
}

// MARK: - Rows

/// A row's state in words, with the state's glyph in front when it has one
/// (on the device, didn't finish, needs reception) — a state, not a button.
struct StatusLine: View {
    let symbol: String?
    let text: String
    let identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .font(.subheadline)
        .foregroundStyle(DesignColor.secondaryInk)
    }
}

/// A download's progress: shown only while bytes arrive, gone when done.
struct RowProgress: View {
    let fraction: Double
    let identifier: String

    var body: some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(DesignColor.ink)
            .accessibilityIdentifier(identifier)
    }
}

/// The core packs folded into one line while all are here: tap to see the four.
private struct CoreSummaryRow<Thumb: View>: View {
    let bytes: Int
    let expanded: Bool
    @ViewBuilder let thumbnail: () -> Thumb
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                thumbnail()
                    .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vegetation, topo, relief, plant ID")
                        .foregroundStyle(DesignColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusLine(symbol: StateSymbol.onDevice, text: "On this \(DeviceNoun.current) · \(StorageText.size(bytes))",
                               identifier: "core-summary-status")
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DesignColor.secondaryInk)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 28, height: 44)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Core maps and plant identification, on this \(DeviceNoun.current), \(StorageText.size(bytes))")
        .accessibilityHint(expanded ? "Hides the four packs" : "Shows the four packs")
        .accessibilityIdentifier("core-summary")
    }
}

/// One pack: its picture, name, one status line, its one control (if it
/// has one), and a progress bar while it arrives.
private struct PackRow<Thumb: View>: View {
    let pack: Pack
    let status: PackRowStatus
    let bytes: Int
    let canRemove: Bool
    @ViewBuilder let thumbnail: () -> Thumb
    let get: () -> Void
    let resume: () -> Void
    let remove: () -> Void

    /// A download under way that Stop can end (swipe, VoiceOver action).
    private var canStop: Bool { status.isBusy && pack.isRemovable && canRemove }

    private var note: String? {
        if status == .unpublished {
            return pack.isRemovable ? "You can get it once it's published." : "It downloads by itself once it's published."
        }
        return pack.storageNote
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail()
                .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pack.storageTitle)
                            .foregroundStyle(DesignColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        StatusLine(symbol: status.symbol, text: status.text(bytes: bytes, device: DeviceNoun.current),
                                   identifier: "pack-\(pack.rawValue)-status")
                    }
                    Spacer(minLength: 0)
                    PackControl(pack: pack, status: status, canRemove: canRemove, get: get, resume: resume, remove: remove)
                }
                if let fraction = status.progress {
                    RowProgress(fraction: fraction, identifier: "pack-\(pack.rawValue)-progress")
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: StorageMetrics.thumbHeight + 8)
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

/// The row's single control — only real controls live here (Get, Retry,
/// Stop, Resume, remove); states are words and glyphs in the status line.
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
        case .downloading where pack.isRemovable && canRemove:
            GetButton(title: "Stop", action: remove)
                .accessibilityLabel("Stop downloading \(pack.storageTitle)")
                .accessibilityIdentifier("pack-\(pack.rawValue)-stop")
        case .queued where pack.isRemovable && canRemove:
            GetButton(title: "Stop", action: remove)
                .accessibilityLabel("Stop getting \(pack.storageTitle)")
                .accessibilityIdentifier("pack-\(pack.rawValue)-stop")
        case .paused:
            // Stop stays the row's swipe / VoiceOver action
            GetButton(title: "Resume", action: resume)
                .accessibilityLabel("Resume \(pack.storageTitle)")
                .accessibilityIdentifier("pack-\(pack.rawValue)-resume")
        case .onDevice where pack.isRemovable && canRemove:
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Remove \(pack.storageTitle)")
            .accessibilityIdentifier("pack-\(pack.rawValue)-remove")
        case .checking, .downloading, .queued, .updating, .onDevice, .unavailable, .unpublished:
            EmptyView()
        }
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
                .foregroundStyle(DesignColor.secondaryInk)
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

/// One extra: what it is, its state in words (a progress bar only while a
/// batch runs), and one tap to get, stop, resume or delete.
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
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.storageTitle).foregroundStyle(DesignColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        StatusLine(symbol: allHere ? StateSymbol.onDevice : nil, text: statusText,
                                   identifier: "extra-\(kind.rawValue)-status")
                    }
                    Spacer(minLength: 0)
                    control
                }
                if isRunning, let batch, batch.totalBytes > 0 {
                    RowProgress(fraction: Double(batch.bytesPresent) / Double(batch.totalBytes),
                                identifier: "extra-\(kind.rawValue)-progress")
                }
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var allHere: Bool {
        guard let batch, !items.isEmpty, !isRunning else { return false }
        return batch.done > 0 && batch.todo.isEmpty
    }

    private var statusText: String {
        guard let batch, !items.isEmpty else { return "Loading…" }
        let total = StorageText.size(batch.totalBytes)
        if isRunning {
            let f = Double(batch.bytesPresent) / Double(max(1, batch.totalBytes))
            return "Downloading\u{00A0}\(StorageText.percent(f)) · \(StorageText.fraction(batch.bytesPresent, of: batch.totalBytes))"
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
                GetButton(title: "Stop") { storage.extras.cancel(kind) }
                .accessibilityLabel("Stop getting \(kind.storageTitle.lowercased())")
                .accessibilityIdentifier("extra-\(kind.rawValue)-stop")
            } else {
                HStack(spacing: 0) {
                    if batch.done > 0 {
                        Button(action: delete) {
                            Image(systemName: "trash")
                                .foregroundStyle(DesignColor.secondaryInk)
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
