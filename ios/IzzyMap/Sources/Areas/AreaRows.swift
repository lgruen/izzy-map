import IzzyKit
import SwiftUI
import UIKit

/// Storage → "Detailed areas": a map of all of them (tap one to see it on
/// the map), one row per area (where it is, layers, detail, size, state)
/// and "Download an area…".
struct DetailedAreasSection: View {
    let model: AppModel
    @State private var deleting: AreaRecord?
    @State private var noRoom: (area: AreaRecord, need: Int64)?
    @State private var removingAll = false
    @State private var footprints = FootprintStore.shared

    private var store: AreaStore { model.shared.areas }

    var body: some View {
        Section {
            if let error = store.loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).foregroundStyle(DesignColor.secondaryInk)
                    Button("Remove All Detailed Areas", role: .destructive) { removingAll = true }
                        .accessibilityIdentifier("areas-remove-all")
                }
            }
            if store.areas.count > 1, let outline = footprints.outline {
                AreasOverview(outline: outline, areas: store.areas) { model.showArea($0.box) }
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            if store.areas.isEmpty, store.loadError == nil {
                NoAreasYet(outline: footprints.outline)
            }
            ForEach(store.areas) { area in
                AreaRow(area: area, status: store.status(area.id), running: store.running?.areaID == area.id ? store.running?.progress : nil,
                        outline: footprints.outline,
                        show: { model.showArea(area.box) },
                        resume: { resume(area) },
                        pause: { Task { await store.pause(area.id) } },
                        delete: { deleting = area })
            }
            Button { model.startFraming() } label: {
                Label("Download an area…", systemImage: "square.dashed")
                    .foregroundStyle(DesignColor.ink)
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("storage-download-area")
        } header: {
            Text("Detailed areas").panelHeader().id("areas")
        } footer: {
            Text("A place in full detail, to 0.4 m: fetched by this \(DeviceNoun.current) from theLIST for your own use. It draws over the statewide maps. A download carries on while IzzyMap is closed; if the signal goes, Resume picks up where it stopped.")
                .foregroundStyle(DesignColor.secondaryInk)
        }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { area in
            Button("Delete", role: .destructive) { Task { await store.delete(area.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { area in
            Text("Frees \(StorageText.size(Int(area.bytes))). The map falls back to the statewide detail there.")
        }
        .confirmationDialog("Remove all detailed areas?", isPresented: $removingAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { Task { await store.removeEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(StorageText.size(Int(store.orphanBytes))). Their list couldn't be read, so they can't be shown one by one.")
        }
        .alert("Not Enough Free Space", isPresented: Binding(get: { noRoom != nil }, set: { if !$0 { noRoom = nil } }),
               presenting: noRoom) { r in
            Button("Try Anyway") { store.start(r.area.id) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("\(r.area.name) needs about \(StorageText.about(Int(r.need))) free while the rest arrives. Remove something first, or try anyway.")
        }
    }

    private func resume(_ area: AreaRecord) {
        if let need = store.shortfall(for: area) {
            noRoom = (area, need)
        } else {
            store.start(area.id)
        }
    }
}

private struct AreaRow: View {
    let area: AreaRecord
    let status: AreaStore.Status
    let running: AreaLayerProgress?
    let outline: TasmaniaOutline?
    let show: () -> Void
    let resume: () -> Void
    let pause: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AreaLocator(box: area.box, outline: outline)
                .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            VStack(alignment: .leading, spacing: 3) {
                Text(area.name)
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AreaText.contents(area))
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AreaText.status(area, status, running: running, device: DeviceNoun.current))
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("area-\(area.id)-status")
                ForEach(AreaText.notes(area, status), id: \.self) { note in
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("area-\(area.id)-note")
                }
                Button(action: show) {
                    Label("Show on map", systemImage: "chevron.forward")
                        .labelStyle(TrailingIconLabel())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                        .frame(minHeight: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("area-\(area.id)-show")
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("area-row-\(area.id)")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    @ViewBuilder private var control: some View {
        switch status {
        case let .downloading(f):
            ring(f, symbol: "stop.fill", action: pause)
                .accessibilityLabel("Stop downloading \(area.name)")
                .accessibilityValue("\(Int(f * 100)) percent")
                .accessibilityIdentifier("area-\(area.id)-stop")
        case .waiting:
            ring(0, symbol: "stop.fill", action: pause)
                .accessibilityLabel("Don't download \(area.name)")
                .accessibilityIdentifier("area-\(area.id)-stop")
        case .incomplete:
            HStack(spacing: 0) {
                trash
                GetButton(title: "Resume", action: resume)
                    .accessibilityLabel("Resume \(area.name)")
                    .accessibilityIdentifier("area-\(area.id)-resume")
            }
        case .complete:
            trash
        }
    }

    private var trash: some View {
        Button(action: delete) {
            Image(systemName: "trash")
                .foregroundStyle(DesignColor.secondaryInk)
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Delete \(area.name)")
        .accessibilityIdentifier("area-\(area.id)-delete")
    }

    private func ring(_ fraction: Double, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                ProgressRing(fraction: fraction, lineWidth: 2.5)
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
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

/// "Show on map ›": the words, then the chevron.
private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

/// The rows' words (unit-tested).
nonisolated enum AreaText {
    /// "Aerial photos, 3 seasons · Fine (0.9 m)"
    static func contents(_ area: AreaRecord) -> String {
        var parts: [String] = []
        let layers = area.layers.map(\.layer)
        for layer in layers where !layer.isSeason { parts.append(layer.title) }
        let seasons = layers.filter(\.isSeason)
        if seasons.count == 1, let s = seasons.first { parts.append(s.title) }
        if seasons.count > 1 { parts.append("\(seasons.count) seasons") }
        let mpp = area.detail.metresPerPixel(latitude: area.box.centre.latitude)
        return parts.joined(separator: ", ") + " · \(area.detail.title) (\(String(format: "%.1f", mpp))\u{00A0}m)"
    }

    /// The notes under a row: why it stopped short, and any layer kept to
    /// less detail than asked for (too large at that detail).
    static func notes(_ area: AreaRecord, _ status: AreaStore.Status) -> [String] {
        var out: [String] = []
        if case let .incomplete(note?) = status { out.append(note) }
        for r in area.layers {
            guard let z = r.cappedAt, r.stored > 0 || !r.complete else { continue }
            let level = AreaDetail(rawValue: z)?.title.lowercased() ?? "statewide"
            out.append("\(r.layer.title) kept to \(level) detail here — too large at \(area.detail.title)")
        }
        if case .downloading = status { out.append("Carries on while IzzyMap is closed; resumes if the signal drops.") }
        return out
    }

    static func status(_ area: AreaRecord, _ status: AreaStore.Status, running: AreaLayerProgress?, device: String) -> String {
        let size = StorageText.size(Int(area.bytes))
        switch status {
        case .complete:
            return "On this \(device) · \(size)"
        case .downloading:
            let done = area.done, planned = max(area.planned, done)
            // which layer, when there's more than one (or it's being saved)
            let layer = running.map { p in
                p.saving != nil ? " · saving \(p.layer.title.lowercased())" : area.layers.count > 1 ? " · \(p.layer.title)" : ""
            } ?? ""
            return "\(done.formatted()) of \(planned.formatted()) tiles · \(size)\(layer)"
        case .waiting:
            return "Waiting for the download before it · \(size)"
        case .incomplete:
            let planned = max(area.planned, 1)
            return area.done == 0 ? "Not started" : "Incomplete · \(StorageText.percent(Double(area.done) / Double(planned))) · \(size)"
        }
    }
}

/// Where an area is: its frame in ink on a small printed locator of the
/// coast around it (~20 km across — a crop of roofs at 54 pt reads as grey
/// mush; this reads as "the one by Hobart"). Light in both appearances, as
/// the mini-maps (printed matter).
struct AreaLocator: View {
    let box: AreaBox
    let outline: TasmaniaOutline?

    var body: some View {
        Canvas { ctx, size in
            let xs = cos(box.centre.latitude * .pi / 180)
            // the view: the box with room around it, at least ~20 km across
            let c = box.centre
            let wantW = max((box.east - box.west) * xs * 4, 0.18)
            let wantH = max((box.north - box.south) * 4, 0.18 * size.height / max(size.width, 1))
            let k = min(size.width / wantW, size.height / wantH)
            func pt(_ lon: Double, _ lat: Double) -> CGPoint {
                CGPoint(x: size.width / 2 + (lon - c.longitude) * xs * k, y: size.height / 2 - (lat - c.latitude) * k)
            }
            if let outline {
                var land = Path()
                for ring in outline.rings {
                    guard let first = ring.first else { continue }
                    land.move(to: pt(first[0], first[1]))
                    for p in ring.dropFirst() { land.addLine(to: pt(p[0], p[1])) }
                    land.closeSubpath()
                }
                ctx.fill(land, with: .color(TasmaniaMiniMap.paper))
                ctx.stroke(land, with: .color(TasmaniaMiniMap.coast), lineWidth: 0.5)
            }
            let a = pt(box.west, box.north), z = pt(box.east, box.south)
            var r = CGRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y)
            r = r.insetBy(dx: min(0, (r.width - 5) / 2), dy: min(0, (r.height - 5) / 2))   // at least 5 pt
            ctx.fill(Path(r), with: .color(TasmaniaMiniMap.ink.opacity(0.25)))
            ctx.stroke(Path(r), with: .color(TasmaniaMiniMap.ink), lineWidth: 1.5)
        }
        .background(DesignColor.keyPlate)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .clipped()
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

/// "No detailed areas yet": the state's silhouette with a dashed frame on
/// Mount Field — what an area is, drawn — and one line of what it does.
struct NoAreasYet: View {
    let outline: TasmaniaOutline?

    var body: some View {
        HStack(spacing: 12) {
            Canvas { ctx, size in
                guard let outline else { return }
                let b = outline.bbox
                let xs = TasmaniaMiniMap.xScale
                let k = min(size.width / ((b[2] - b[0]) * xs), size.height / (b[3] - b[1])) * 0.9
                let ox = (size.width - (b[2] - b[0]) * xs * k) / 2, oy = (size.height - (b[3] - b[1]) * k) / 2
                func pt(_ lon: Double, _ lat: Double) -> CGPoint { CGPoint(x: ox + (lon - b[0]) * xs * k, y: oy + (b[3] - lat) * k) }
                var land = Path()
                for ring in outline.rings {
                    guard let first = ring.first else { continue }
                    land.move(to: pt(first[0], first[1]))
                    for p in ring.dropFirst() { land.addLine(to: pt(p[0], p[1])) }
                    land.closeSubpath()
                }
                ctx.fill(land, with: .color(TasmaniaMiniMap.paper))
                ctx.stroke(land, with: .color(TasmaniaMiniMap.coast), lineWidth: 0.5)
                // a frame round Mount Field, drawn as framing draws one —
                // dashed ink — and big enough to read at thumbnail size
                let a = pt(146.2, -42.45), z = pt(147.0, -42.95)
                let r = CGRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y)
                ctx.fill(Path(r), with: .color(TasmaniaMiniMap.ink.opacity(0.12)))
                ctx.stroke(Path(r), with: .color(TasmaniaMiniMap.ink), style: StrokeStyle(lineWidth: 1.25, dash: [2.5, 1.5]))
            }
            .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            .background(DesignColor.keyPlate)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .environment(\.colorScheme, .light)
            .accessibilityHidden(true)
            Text("No detailed areas yet. Frame a place you know you’ll walk, and it stays sharp offline down to 0.4 m.")
                .font(.subheadline)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("areas-empty")
    }
}

/// Every detailed area as a small frame on the state's silhouette; a tap
/// shows the nearest one on the map.
struct AreasOverview: View {
    let outline: TasmaniaOutline
    let areas: [AreaRecord]
    let show: (AreaRecord) -> Void

    private var frame: (w: Double, s: Double, e: Double, n: Double) {
        let b = outline.bbox
        return (b[0] - 0.04, b[1] - 0.04, b[2] + 0.04, b[3] + 0.04)
    }

    private func project(_ size: CGSize) -> (Double, Double) -> CGPoint {
        let b = frame
        let xs = TasmaniaMiniMap.xScale
        let k = min(size.width / ((b.e - b.w) * xs), size.height / (b.n - b.s))
        let ox = (size.width - (b.e - b.w) * xs * k) / 2, oy = (size.height - (b.n - b.s) * k) / 2
        return { lon, lat in CGPoint(x: ox + (lon - b.w) * xs * k, y: oy + (b.n - lat) * k) }
    }

    var body: some View {
        GeometryReader { proxy in
            let pt = project(proxy.size)
            Canvas { ctx, _ in
                var land = Path()
                for ring in outline.rings {
                    guard let first = ring.first else { continue }
                    land.move(to: pt(first[0], first[1]))
                    for p in ring.dropFirst() { land.addLine(to: pt(p[0], p[1])) }
                    land.closeSubpath()
                }
                ctx.fill(land, with: .color(TasmaniaMiniMap.paper))
                ctx.stroke(land, with: .color(TasmaniaMiniMap.coast), lineWidth: 0.5)
                for area in areas {
                    let a = pt(area.box.west, area.box.north), z = pt(area.box.east, area.box.south)
                    var r = CGRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y)
                    r = r.insetBy(dx: min(0, (r.width - 6) / 2), dy: min(0, (r.height - 6) / 2))
                    ctx.fill(Path(r), with: .color(TasmaniaMiniMap.ink.opacity(0.3)))
                    ctx.stroke(Path(r), with: .color(TasmaniaMiniMap.ink), lineWidth: 1.25)
                }
            }
            .contentShape(.rect)
            .onTapGesture { location in
                let nearest = areas.min { a, b in
                    let pa = pt(a.box.centre.longitude, a.box.centre.latitude)
                    let pb = pt(b.box.centre.longitude, b.box.centre.latitude)
                    return hypot(pa.x - location.x, pa.y - location.y) < hypot(pb.x - location.x, pb.y - location.y)
                }
                if let nearest { show(nearest) }
            }
        }
        .background(DesignColor.keyPlate)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the detailed areas")
        .accessibilityHint("Shows the nearest area on the map")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("areas-overview")
    }
}
