import ImageIO
import IzzyKit
import SwiftUI

/// After Next: what to take offline for the framed box (UX_VISUAL_REVIEW
/// §3.15) — a name, the layers with their sizes (the base map she is
/// looking at checked), the detail as three real crops of the frame's
/// centre with each level's size under it, and the total as a range against
/// the free space. Download (its label carries the total) starts it — a
/// user-started `BGContinuedProcessingTask`; Back goes back to the frame.
/// A sheet on phones; the side card beside the frame on wide layouts.
struct AreaSetupSheet: View {
    let model: AppModel
    @State private var name = ""
    @State private var choices: Set<AreaChoice>
    @State private var detail = AreaDetail.fine
    /// Per season with a pack on the device: its z15 tiles with photos in the box.
    @State private var flown: [Int: Set<TileID>] = [:]
    /// Per season without a pack: whether its coverage grid (bundled) touches the box.
    @State private var touches: [Int: Bool] = [:]
    @State private var free = VolumeSpace.current().free
    @State private var noRoom: Int64?
    @FocusState private var nameFocused: Bool

    init(model: AppModel) {
        self.model = model
        _choices = State(initialValue: AreaChoice.defaults(base: model.layers.base))
    }

    private var box: AreaBox? { model.areaDraft }
    private var store: AreaStore { model.shared.areas }

    var body: some View {
        NavigationStack {
            if let box {
                content(box)
            } else {
                ContentUnavailableView("No area framed", systemImage: "square.dashed")
            }
        }
        .task(id: box) {
            guard let box else { return }
            touches = Self.coverageTouches(box: box, footprints: FootprintStore.shared)
            flown = await Self.flownParents(box: box, data: model.data)
        }
        .onAppear { if name.isEmpty { name = store.defaultName } }
        .accessibilityIdentifier("area-setup")
    }

    private func plan(_ box: AreaBox) -> AreaSetupPlan {
        AreaSetupPlan(box: box, choices: choices, detail: detail, flown: flown, free: free, device: DeviceNoun.current,
                      touches: touches, calibration: store.calibration)
    }

    private func content(_ box: AreaBox) -> some View {
        let plan = plan(box)
        return List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "square.dashed")
                        .font(.title2)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $name)
                            .font(.headline)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onChange(of: name) { _, new in
                                if new.count > AreaRecord.maxNameLength { name = String(new.prefix(AreaRecord.maxNameLength)) }
                            }
                            .accessibilityIdentifier("area-name")
                        Text(AreaFramingMetrics.size(box))
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                }
            }

            Section {
                ForEach(AreaChoice.allCases) { choice in
                    LayerChoiceRow(choice: choice, on: choices.contains(choice), line: plan.line(for: choice),
                                   enabled: plan.isAvailable(choice)) {
                        if choices.contains(choice) { choices.remove(choice) } else { choices.insert(choice) }
                    }
                }
            } header: {
                Text("Layers")
                    .foregroundStyle(DesignColor.secondaryInk)
            } footer: {
                // she will look for it: say why it isn't here, once
                Text("Relief shading is already complete statewide.")
                    .foregroundStyle(DesignColor.secondaryInk)
            }

            Section {
                DetailPicker(detail: $detail, box: box, preview: plan.previewLayer, sizes: plan.levelLines,
                             transport: store.transport, data: model.data)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("Detail")
                    .foregroundStyle(DesignColor.secondaryInk)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.totalLine)
                        .font(.headline).monospacedDigit()
                        .accessibilityIdentifier("area-total")
                    if let range = plan.totalRange, let free {
                        SpaceBar(range: range, free: free)
                    }
                    if let problem = plan.problem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .accessibilityIdentifier("area-problem")
                    } else if let freeLine = plan.freeLine {
                        Text(freeLine)
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Detailed area")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back", systemImage: "chevron.backward") { model.dismissModal() }
                    .accessibilityIdentifier("area-back")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(plan.downloadLabel) {
                    if let need = plan.shortfall { noRoom = need } else { download(box, plan) }
                }
                .buttonStyle(.glassProminent)
                .disabled(!plan.canDownload)
                .accessibilityIdentifier("area-download")
            }
        }
        .alert("Not Enough Free Space", isPresented: Binding(get: { noRoom != nil }, set: { if !$0 { noRoom = nil } }),
               presenting: noRoom) { _ in
            Button("Try Anyway") { download(box, plan) }
            Button("Cancel", role: .cancel) {}
        } message: { need in
            Text(plan.exact
                ? "This needs about \(StorageText.about(Int(need))) free while it arrives. Remove something in Storage first, or try anyway."
                : "This may need up to \(StorageText.about(Int(need))) free while it arrives — seasons are fetched only where flown, so likely less. Try anyway?")
        }
    }

    private func download(_ box: AreaBox, _ plan: AreaSetupPlan) {
        store.add(name: name, box: box, detail: detail, layers: plan.layers)
        model.areaStarted()
    }

    /// The flown z15 tiles inside `box` of every season pack on the device
    /// (PMTiles directory lookups, off the main thread; never the network).
    @concurrent static func flownParents(box: AreaBox, data: DataLocation) async -> [Int: Set<TileID>] {
        var out: [Int: Set<TileID>] = [:]
        let z15 = AreaPlan.tiles(box, zoom: AreaPlan.packMaxZoom)
        for season in Season.all {
            guard let url = data.url(for: season.archive), let reader = try? PMTilesReader(url: url) else { continue }
            out[season.year] = Set(z15.filter { (try? reader.tileExists(z: $0.z, x: $0.x, y: $0.y)) == true })
        }
        return out
    }

    /// Per season: does its coverage grid (one cell per z11 tile, ~19 km;
    /// bundled, or read from an installed pack) have photos under the box?
    static func coverageTouches(box: AreaBox, footprints: FootprintStore) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for season in Season.all {
            guard let pack = Pack(rawValue: season.sourceID), let f = footprints.footprint(pack) else { continue }
            out[season.year] = f.touches(box)
        }
        return out
    }
}

extension Footprint {
    /// Whether any cell under `box` has tiles.
    nonisolated func touches(_ box: AreaBox) -> Bool {
        let r = AreaPlan.tileRange(box, zoom: grid.zoom)
        for y in r.y { for x in r.x where contains(col: x - grid.x0, row: y - grid.y0) { return true } }
        return false
    }
}

/// The sheet's arithmetic, kept out of the view (unit-tested).
nonisolated struct AreaSetupPlan {
    let box: AreaBox
    let choices: Set<AreaChoice>
    let detail: AreaDetail
    /// Seasons whose pack is on the device → their flown z15 tiles here.
    let flown: [Int: Set<TileID>]
    let free: Int64?
    var device = "device"
    /// Seasons without a pack → whether their coverage grid touches the box.
    var touches: [Int: Bool] = [:]
    /// Measured tile sizes (AreaStore): the ranges.
    var calibration: [String: AreaCalibration] = [:]
    /// The season still being flown and published (2025–26): offered even
    /// where its pack has no photo yet — its tiles are checked one by one.
    var incompleteSeason: Int? = Season.all.last?.year

    func isIncomplete(_ layer: AreaLayer) -> Bool {
        if case let .season(year) = layer { year == incompleteSeason } else { false }
    }

    func estimate(_ layer: AreaLayer, detail: AreaDetail? = nil) -> AreaPlan.Estimate {
        let parents: Set<TileID>? = if case let .season(year) = layer { flown[year] } else { nil }
        let e = AreaPlan.estimate(box, layer: layer, detail: detail ?? self.detail, flownParents: parents)
        // the incomplete season may have more photos than its pack knows
        return isIncomplete(layer) && e.exact ? AreaPlan.Estimate(layer: layer, tiles: e.tiles, bytes: e.bytes, exact: false) : e
    }

    /// A season is worth fetching unless its pack (or, without one, its
    /// coverage grid) says it wasn't flown here — the incomplete season
    /// always is.
    func isFlown(_ layer: AreaLayer) -> Bool {
        guard case let .season(year) = layer, !isIncomplete(layer) else { return true }
        if let parents = flown[year] { return !parents.isEmpty }
        return touches[year] ?? true
    }

    func layers(of choice: AreaChoice) -> [AreaLayer] { choice.layers.filter(isFlown) }

    func isAvailable(_ choice: AreaChoice) -> Bool { !layers(of: choice).isEmpty }

    /// What Download fetches, in paint order.
    var layers: [AreaLayer] {
        choices.flatMap { layers(of: $0) }.sorted()
    }

    var estimates: [AreaPlan.Estimate] { layers.map { estimate($0) } }

    /// Over the cap where it can't be kept to less: a season over the cap
    /// keeps the deepest level that fits as it downloads, so only the
    /// others stop Download.
    var overCap: [AreaPlan.Estimate] { estimates.filter { $0.overCap && !$0.layer.isSeason } }

    var exact: Bool { estimates.allSatisfy(\.exact) }

    /// The likely range of one layer's bytes (a season's upper bound: its top).
    func range(_ e: AreaPlan.Estimate) -> ClosedRange<Int64> {
        (calibration[e.layer.calibrationKey] ?? AreaCalibration()).range(nominal: e.bytes, nominalMean: e.layer.meanTileBytes)
    }

    func range(_ es: [AreaPlan.Estimate]) -> ClosedRange<Int64> {
        let rs = es.map(range)
        return rs.reduce(Int64(0)) { $0 + $1.lowerBound } ... rs.reduce(Int64(0)) { $0 + $1.upperBound }
    }

    var totalRange: ClosedRange<Int64>? { layers.isEmpty ? nil : range(estimates) }

    var shortfall: Int64? {
        guard let free, let high = totalRange?.upperBound else { return nil }
        // the range's top, and the largest layer's archive once more while it's written
        let need = high + (estimates.map { range($0).upperBound }.max() ?? 0) + AreaPlan.spaceMargin
        return free < need ? need : nil
    }

    var canDownload: Bool { !layers.isEmpty && overCap.isEmpty }

    /// One row's line: its size, or why it can't be had.
    func line(for choice: AreaChoice) -> String {
        let list = layers(of: choice)
        guard !list.isEmpty else { return "Not flown inside the frame" }
        let es = list.map { estimate($0) }
        if es.contains(where: { $0.overCap && !$0.layer.isSeason }) { return "Too large at \(detail.title) — pick less detail" }
        let r = range(es)
        let size = AreaFramingMetrics.range(r)
        switch choice {
        case .seasons:
            var parts = [es.allSatisfy(\.exact) ? size : "up to \(AreaFramingMetrics.roughly(r).dropFirst())",
                         "\(list.count) of \(choice.layers.count) seasons flown here"]
            if let newest = list.first(where: isIncomplete)?.season {
                parts.append("\(newest.label) may add newly flown places")
            }
            if es.contains(where: \.overCap) { parts.append("less detail where too large") }
            return parts.joined(separator: " · ")
        case .tasmap:
            return detail > .good ? "\(size) · stops at Good — the paper map's finest sheets" : size
        default:
            return size
        }
    }

    /// Under each detail plate: the checked layers' size at that level.
    var levelLines: [AreaDetail: String] {
        guard !layers.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: AreaDetail.allCases.map { level in
            let es = layers.map { estimate($0, detail: level) }
            if es.contains(where: { $0.overCap && !$0.layer.isSeason }) { return (level, "too big") }
            let r = range(es)
            return (level, exact ? AreaFramingMetrics.range(r) : "≤\u{00A0}" + AreaFramingMetrics.roughly(r).dropFirst())
        })
    }

    /// The layer the detail plates show: the photos if they're checked,
    /// else the first checked map.
    var previewLayer: AreaLayer {
        if choices.contains(.aerial) || choices.contains(.seasons) || choices.isEmpty { return .aerial }
        return choices.contains(.topo) ? .topo : .tasmap
    }

    var totalLine: String {
        guard let r = totalRange else { return "Pick at least one layer" }
        return exact ? AreaFramingMetrics.range(r) : "Up to \(AreaFramingMetrics.roughly(r).dropFirst())"
    }

    /// "Download · ~1 MB"
    var downloadLabel: String {
        guard let r = totalRange else { return "Download" }
        return "Download · \(AreaFramingMetrics.roughly(r))"
    }

    var freeLine: String? {
        free.map { "\(StorageText.size(Int($0))) free on this \(device)" }
    }

    var problem: String? {
        if let e = overCap.first {
            return "\(e.layer.title) at \(detail.title) is \(e.tiles.formatted()) tiles — one download takes \(AreaPlan.maxTilesPerLayer.formatted()) per layer. Pick less detail or frame a smaller area."
        }
        if let need = shortfall {
            return "\(exact ? "Needs about" : "May need up to") \(StorageText.about(Int(need))) free while it arrives\(free.map { ", and there's \(StorageText.size(Int($0)))" } ?? "")."
        }
        return nil
    }
}

/// The total against the free space: the likely size solid, a lighter band
/// out to the range's top.
private struct SpaceBar: View {
    let range: ClosedRange<Int64>
    let free: Int64

    var body: some View {
        Canvas { ctx, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            ctx.fill(track, with: .color(DesignColor.ink.opacity(0.10)))
            let k = size.width / CGFloat(max(free, 1))
            let low = max(size.height, CGFloat(range.lowerBound) * k)
            let high = max(low, min(size.width, CGFloat(range.upperBound) * k))
            var clipped = ctx
            clipped.clip(to: track)
            clipped.fill(Path(CGRect(x: 0, y: 0, width: high, height: size.height)), with: .color(DesignColor.ink.opacity(0.35)))
            clipped.fill(Path(CGRect(x: 0, y: 0, width: min(low, size.width), height: size.height)), with: .color(DesignColor.ink))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct LayerChoiceRow: View {
    let choice: AreaChoice
    let on: Bool
    let line: String
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: choice.symbol)
                    .frame(width: 28)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).foregroundStyle(DesignColor.ink)
                    Text(line)
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: on && enabled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on && enabled ? DesignColor.ink : DesignColor.secondaryInk)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(on && enabled ? .isSelected : [])
        .accessibilityIdentifier("area-layer-\(choice.rawValue)")
    }
}

/// Good / Fine / Finest as three real crops of the frame's centre — the
/// same ~25 m of ground at each level's pixels, drawn nearest-neighbour so
/// the pixel size is honest — fetched by the device from theLIST while
/// online. Offline: the statewide pack's z15 crop in all three, saying the
/// detail shows after download. Each level's size sits under its crop.
struct DetailPicker: View {
    @Binding var detail: AreaDetail
    let box: AreaBox
    let preview: AreaLayer
    let sizes: [AreaDetail: String]
    let transport: any AreaTransport
    let data: DataLocation
    @State private var crops: DetailCrops?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ForEach(AreaDetail.allCases, id: \.self) { level in
                    plate(level)
                }
            }
            if crops?.live == false {
                Text("Offline: the detail shows after download.")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("area-detail-offline")
            }
        }
        .task(id: DetailCrops.Key(box: box, layer: preview)) {
            crops = nil
            crops = await DetailCrops.load(box: box, layer: preview, transport: transport, pack: preview.archive.flatMap { data.url(for: $0) })
        }
    }

    private func plate(_ level: AreaDetail) -> some View {
        let mpp = level.metresPerPixel(latitude: box.centre.latitude)
        let size = sizes[level]
        return Button { detail = level } label: {
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    if let image = crops?.images[level] {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFill()
                    } else if crops == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 72, height: 72)
                .clipped()
                .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                Text(level.title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                Text(String(format: "%.1f\u{00A0}m", mpp))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
                if let size {
                    Text(size)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(level == detail ? DesignColor.ink.opacity(0.08) : .clear, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(level == detail ? DesignColor.ink : DesignColor.keyline,
                                  lineWidth: level == detail ? 1.5 : 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(level.title), \(String(format: "%.1f", mpp)) metres per pixel\(size.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(level == detail ? .isSelected : [])
        .accessibilityIdentifier("area-detail-\(level.zoom)")
    }
}

/// The detail plates' pictures: one window of ground at the frame's centre,
/// 64 px wide at z18 (~25 m here), cut from the z16, z17 and z18 tiles
/// holding it (16, 32 and 64 px of it).
nonisolated struct DetailCrops: @unchecked Sendable {
    /// Per level (CGImage is immutable).
    var images: [AreaDetail: CGImage]
    /// Fetched from theLIST (false: the statewide pack's crop, or nothing).
    var live: Bool

    struct Key: Hashable {
        let box: AreaBox
        let layer: AreaLayer
    }

    /// The window at z18, in global pixels: centred on the point, kept
    /// inside its z18 tile (so it lies inside every ancestor's tile too).
    static func window(longitude: Double, latitude: Double) -> (x: Int, y: Int, tile: TileID) {
        let t = TileID(longitude: longitude, latitude: latitude, zoom: 18)
        let n = Double(1 << 18) * 256
        let lat = latitude * .pi / 180
        let px = (longitude + 180) / 360 * n
        let py = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        let x = min(max(Int(px) - 32, t.x * 256), t.x * 256 + 192)
        let y = min(max(Int(py) - 32, t.y * 256), t.y * 256 + 192)
        return (x, y, t)
    }

    /// The window's rectangle inside the zoom-`z` tile (z ≤ 18).
    static func rect(_ w: (x: Int, y: Int, tile: TileID), zoom z: Int) -> (tile: TileID, rect: CGRect) {
        let d = 18 - z
        let tile = TileID(z: z, x: w.tile.x >> d, y: w.tile.y >> d)
        let size = 64 >> d
        return (tile, CGRect(x: (w.x >> d) - tile.x * 256, y: (w.y >> d) - tile.y * 256, width: size, height: size))
    }

    static func crop(_ data: Data, _ rect: CGRect) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.cropping(to: rect)
    }

    /// One try per tile (never the download's retries: a sheet shouldn't wait).
    @concurrent static func load(box: AreaBox, layer: AreaLayer, transport: any AreaTransport, pack: URL?) async -> DetailCrops {
        let c = box.centre
        let w = window(longitude: c.longitude, latitude: c.latitude)
        var images: [AreaDetail: CGImage] = [:]
        var fetched: [Int: CGImage] = [:]
        for level in AreaDetail.allCases {
            // the paper map stops at z16: deeper plates show its z16 pixels
            let z = min(level.zoom, layer.maxZoom)
            if let done = fetched[z] { images[level] = done; continue }
            let (tile, rect) = Self.rect(w, zoom: z)
            guard case let .body(data) = await transport.fetch(layer.tileURL(tile)), TileImage.isImage(data),
                  let image = crop(data, rect) else { break }
            fetched[z] = image
            images[level] = image
        }
        if images.count == AreaDetail.allCases.count { return DetailCrops(images: images, live: true) }
        // offline: the pack's z15 pixels for all three
        guard let pack, let reader = try? PMTilesReader(url: pack) else { return DetailCrops(images: [:], live: false) }
        let (tile, rect) = Self.rect(w, zoom: AreaPlan.packMaxZoom)
        guard let data = try? reader.tileData(z: tile.z, x: tile.x, y: tile.y), let image = crop(data, rect)
        else { return DetailCrops(images: [:], live: false) }
        return DetailCrops(images: Dictionary(uniqueKeysWithValues: AreaDetail.allCases.map { ($0, image) }), live: false)
    }
}
