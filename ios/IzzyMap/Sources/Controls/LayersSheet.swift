import IzzyKit
import SwiftUI
import UIKit

/// The Layers sheet (iPhone) / popover (iPad): base map, overlay and
/// strength, "Also show", and the key. Every row says whether its data is on
/// this device. Changes apply live: the map behind stays visible.
struct LayersSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                baseSection.panelRows()
                overlaySection.panelRows()
                alsoShowSection.panelRows()
                Section {
                    NavigationLink {
                        LegendView(model: model)
                    } label: {
                        Label("Key", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("legend-link")
                }
                .panelRows()
            }
            .panelListSurface()
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: model.layers)
    }

    // MARK: Base

    private var baseSection: some View {
        Section {
            TileGrid {
                ForEach(BaseMap.allCases) { base in
                    LayerTile(model: model, subject: .base(base), title: base.shortTitle, status: status(base),
                              symbol: base.symbol, isOn: model.layers.base == base) {
                        model.layers.base = base
                    }
                    .accessibilityHint(base.hint)
                    .accessibilityIdentifier("base-\(base.rawValue)")
                }
            }
            if model.layers.base == .seasons {
                SeasonControl(model: model)
            }
        } header: {
            Text("Base map")
        } footer: {
            Text(model.layers.base.hint).foregroundStyle(DesignColor.inkSecondary)
        }
    }

    /// Status shows only what's NOT on the device: a pack on the device is
    /// the normal case and needs no words (no "On iPhone" × 8).
    private func status(_ base: BaseMap) -> String? {
        if let archive = base.archive {
            return model.data.url(for: archive) != nil ? nil : "Streams online"
        }
        let local = Season.all.filter { model.data.url(for: $0.archive) != nil }.count
        switch local {
        case Season.all.count: return nil
        case 0: return "Streams online"
        default: return "\(local) of \(Season.all.count) on \(DeviceNoun.current)"
        }
    }

    // MARK: Overlay

    private var overlaySection: some View {
        Section {
            TileGrid {
                ForEach(Overlay.allCases) { overlay in
                    LayerTile(model: model, subject: .overlay(overlay), title: overlay.shortTitle, status: status(overlay),
                              symbol: overlay.symbol, isOn: model.layers.overlay == overlay) {
                        model.layers.overlay = overlay
                    }
                    .accessibilityHint(overlay.hint)
                    .accessibilityIdentifier("overlay-\(overlay.rawValue)")
                }
            }
            if model.layers.overlay != .none {
                StrengthPicker(model: model)
            }
        } header: {
            Text("Overlay")
        } footer: {
            Text(model.layers.overlay.hint).foregroundStyle(DesignColor.inkSecondary)
        }
    }

    private func status(_ overlay: Overlay) -> String? {
        guard let archive = overlay.archive else { return nil }
        return model.data.url(for: archive) != nil ? nil : "Not downloaded"
    }

    // MARK: Also show

    private var alsoShowSection: some View {
        Section("Also show") {
            TileGrid {
                LayerTile(model: model, subject: .relief, title: "Relief",
                          status: model.data.url(for: .relief) != nil ? nil : "Not downloaded",
                          symbol: "mountain.2", isOn: model.layers.relief) {
                    model.layers.relief.toggle()
                }
                .accessibilityHint("Shades ridges and valleys over any map")
                .accessibilityIdentifier("relief-row")
                LayerTile(model: model, subject: .trees, title: "Hobart trees", status: nil,
                          symbol: "tree", isOn: model.layers.trees) {
                    model.layers.trees.toggle()
                }
                .accessibilityHint("City of Hobart significant tree register")
                .accessibilityIdentifier("trees-row")
            }
        }
    }
}

/// Tiles four to a row on a phone, more when there's room; wider tiles at
/// accessibility text sizes.
private struct TileGrid<Content: View>: View {
    @ViewBuilder var content: Content
    @ScaledMetric(relativeTo: .subheadline) private var minimum: CGFloat = 62

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: 132), spacing: 10, alignment: .top)],
                  alignment: .leading, spacing: 14) {
            content
        }
        .padding(.vertical, 6)
    }
}

/// One choice as a picture (Google-Maps-style layer picker, DESIGN.md
/// "Layer thumbnails"): a square-cornered thumbnail rendered on the device,
/// a short label and its on-device status. Selected = a 2.5 pt ink frame
/// and a checkmark — no accent colour.
struct LayerTile: View {
    let model: AppModel
    let subject: ThumbnailSubject
    let title: String
    let status: String?
    let symbol: String
    let isOn: Bool
    let action: () -> Void
    @Environment(LayerThumbnails.self) private var thumbnails
    @Environment(\.displayScale) private var scale

    var body: some View {
        let image = thumbnails.image(subject, state: model.layers, data: model.data, scale: scale)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(DesignColor.inkSecondary)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipped()
                .overlay {
                    Rectangle().strokeBorder(isOn ? DesignColor.ink : DesignColor.keyline, lineWidth: isOn ? 2.5 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(width: 20, height: 20)
                            .background(DesignColor.ink, in: .circle)
                            .padding(4)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: image != nil)
                Text(title)
                    .font(.footnote.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(DesignColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(status.map { "\(title), \($0)" } ?? title))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .task(id: TileKey(state: model.layers, subject: subject)) {
            await thumbnails.load(subject, current: model.layers, data: model.data, tables: model.tables, scale: scale)
        }
    }

    private struct TileKey: Equatable {
        var state: LayerState
        var subject: ThumbnailSubject
    }
}

/// "iPhone" / "iPad" for on-device status text (wording only — layout never
/// keys on the device).
enum DeviceNoun {
    static var current: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
}

/// Full / Light / Outlines as three drawn key boxes, each the sample
/// colour composited at that strength over white (Outlines: the edge band)
/// — she picks by eye what the map will look like, not by a word.
/// Pre-1750 has no Outlines (it would show nothing).
struct StrengthPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        let choices = Strength.allCases.filter { model.layers.overlay.hasBoundaries || $0 != .outlines }
        let current = model.layers.effectiveStrength
        let hex = sampleHex
        HStack(alignment: .center, spacing: 6) {
            Text("Strength")
                .font(.subheadline)
                .foregroundStyle(DesignColor.inkSecondary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            ForEach(choices) { strength in
                let isOn = strength == current
                Button {
                    model.layers.strength = strength
                } label: {
                    VStack(spacing: 4) {
                        KeyBox(hex: hex, opacity: LayerState.fillOpacity(base: model.layers.base, strength: strength),
                               width: 36, height: 24)
                            .padding(3)
                            .overlay {
                                if isOn { Rectangle().strokeBorder(DesignColor.ink, lineWidth: 2) }
                            }
                        Text(strength.title)
                            .font(.caption.weight(isOn ? .semibold : .regular))
                            .foregroundStyle(DesignColor.ink)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(minWidth: 60, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(strength.title)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("strength-\(strength.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Strength")
        .accessibilityIdentifier("strength-picker")
    }

    /// The selected feature's colour when it belongs to the overlay shown,
    /// else a typical unit (dry E. obliqua forest, dolerite, open forest).
    private var sampleHex: String? {
        let tables = model.tables
        switch (model.layers.overlay, model.selection?.feature) {
        case let (.vegetation, .community(c)?): return c.colorHex
        case let (.geology, .geology(symb)?): return tables.geology[symb]?.color
        case let (.pre1750, .pre1750(mvs)?): return tables.pre1750[mvs]?.color
        case (.vegetation, _): return tables.communities["DOB"]?.color
        case (.geology, _): return tables.geology["Jd"]?.color
        case (.pre1750, _): return tables.pre1750["4"]?.color
        case (.none, _): return nil
        }
    }
}

/// "Photos up to 2023–24": a seven-stop track, one detent per season, and
/// the caption saying which season's photo is under the map centre (its
/// stop gets an ink ring).
private struct SeasonControl: View {
    @Bindable var model: AppModel
    @State private var shownHere: Int?

    var body: some View {
        let seasons = Season.all
        let cutoff = model.layers.seasonClamped
        VStack(alignment: .leading, spacing: 6) {
            Text("Photos up to \(Text(seasons[cutoff].label).fontWeight(.semibold).monospacedDigit())")
                .foregroundStyle(DesignColor.ink)
                .accessibilityHidden(true)
            SeasonTrack(index: Binding(get: { cutoff }, set: { model.layers.season = $0 }),
                        labels: seasons.map(\.label), shownHere: shownHere)
            SeasonCaption(model: model, map: model.map, shownHere: $shownHere)
            if seasons[cutoff].isIncomplete {
                Text("This season is still being flown — more areas appear over time.")
                    .font(.footnote).foregroundStyle(DesignColor.inkSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The season track, drawn so every tick sits exactly on its stop: ticks,
/// fill and thumb share one x scale (stop i at inset + i × step), the end
/// stops at the track's ends. VoiceOver gets a system slider
/// (`accessibilityRepresentation`), so adjusting works as everywhere else.
private struct SeasonTrack: View {
    @Binding var index: Int
    let labels: [String]
    /// The season whose photo shows at the map centre, if known.
    var shownHere: Int?

    private static let thumb: CGFloat = 24
    private static let trackHeight: CGFloat = 44

    var body: some View {
        let count = labels.count
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let inset = Self.thumb / 2
                let step = (proxy.size.width - 2 * inset) / CGFloat(max(1, count - 1))
                let x = { (i: Int) in inset + CGFloat(i) * step }
                let mid = proxy.size.height / 2
                ZStack(alignment: .topLeading) {
                    // rail, and the part "up to" the cutoff in ink
                    Capsule().fill(DesignColor.keyline.opacity(0.6))
                        .frame(width: x(count - 1) - x(0), height: 2)
                        .position(x: (x(0) + x(count - 1)) / 2, y: mid)
                    Capsule().fill(DesignColor.ink)
                        .frame(width: max(0, x(index) - x(0)), height: 3)
                        .position(x: (x(0) + x(index)) / 2, y: mid)
                    ForEach(0 ..< count, id: \.self) { i in
                        Rectangle()
                            .fill(i <= index ? DesignColor.ink : DesignColor.inkSecondary)
                            .frame(width: 1.5, height: 10)
                            .position(x: x(i), y: mid)
                    }
                    if let shownHere, shownHere != index, (0 ..< count).contains(shownHere) {
                        Circle().strokeBorder(DesignColor.ink, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                            .position(x: x(shownHere), y: mid)
                    }
                    Circle()
                        .fill(Color.white)
                        .overlay { Circle().strokeBorder(DesignColor.ink, lineWidth: 2) }
                        .frame(width: Self.thumb, height: Self.thumb)
                        .position(x: x(index), y: mid)
                        .animation(.snappy(duration: 0.2), value: index)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let i = Int(((value.location.x - inset) / step).rounded())
                            let clamped = min(max(i, 0), count - 1)
                            if clamped != index { index = clamped }
                        }
                )
            }
            .frame(height: Self.trackHeight)
            HStack {
                Text(labels.first ?? "")
                Spacer()
                Text(labels.last ?? "")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(DesignColor.inkSecondary)
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                   in: 0 ... Double(max(1, count - 1)), step: 1) {
                Text("Photos up to")
            }
            .accessibilityValue(labels.indices.contains(index) ? labels[index] : "")
        }
        .accessibilityIdentifier("season-slider")
    }
}

/// The coverage caption: probes the LOCAL season packs at the map centre,
/// 250 ms after the camera settles, off the main thread. Its own view, so
/// panning re-renders only this line (and the ring it reports).
private struct SeasonCaption: View {
    let model: AppModel
    let map: MapLiveState
    @Binding var shownHere: Int?
    @State private var text: String?

    private struct Key: Equatable {
        var cutoff: Int, lat: Double, lon: Double, zoom: Double, idle: Bool
    }

    var body: some View {
        let centre = map.centre
        let key = Key(cutoff: model.layers.seasonClamped,
                      lat: centre?.latitude ?? 0, lon: centre?.longitude ?? 0,
                      zoom: map.zoom, idle: map.isIdle)
        Text(text ?? " ")
            .font(.footnote)
            .foregroundStyle(DesignColor.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("season-caption")
            .task(id: key) {
                guard let centre, key.idle || text == nil else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let caption = await model.shared.seasonProbes.caption(
                    cutoff: key.cutoff, longitude: centre.longitude, latitude: centre.latitude, mapZoom: key.zoom)
                guard !Task.isCancelled else { return }
                text = SeasonCoverage.text(caption, labels: Season.labels, device: DeviceNoun.current)
                if case let .showing(season, _) = caption { shownHere = season } else { shownHere = nil }
            }
    }
}

// MARK: - Surfaces

extension View {
    /// A list on the panel's near-opaque plate with opaque grouped rows:
    /// no glass-on-glass blobs, and the same look at every detent.
    func panelListSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { PanelPlate(grouped: true).ignoresSafeArea() }
    }

    /// Opaque grouped row ground (apply to a Section: its rows inherit it).
    func panelRows() -> some View {
        listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
