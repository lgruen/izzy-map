import IzzyKit
import SwiftUI

/// "Show on map": one TASVEG community soloed — every other community
/// faded to a trace — with the camera on its CORE distribution, then
/// stepping through its largest patches (where_patches.json). Below z11,
/// where TASVEG tiles are dominant-class generalisations that drop small
/// patches, the community is drawn from where.bin as bold presence cells
/// (SpotlightPresenter); from z11 its real polygons. The map's pill says
/// what is shown and steps; Escape or × exits and the camera flies back. A
/// tap on the map ends it where she is.
nonisolated struct Spotlight: Equatable, Sendable {
    let code: String
    /// 0: the overview; 1…n: the n-th largest patch.
    var step: Int
    /// The community's presence cells (where.bin) and their grid.
    let cells: [CommunityPresence.Cell]
    let grid: CommunityPresence.Grid
    /// Largest patches first.
    let patches: [CommunityPatches.Patch]
    /// Patches statewide (the caption's "3,383 patches").
    let patchCount: Int

    /// The cells follow from the code: comparing them on every SwiftUI
    /// update would be thousands of elements for nothing.
    static func == (a: Spotlight, b: Spotlight) -> Bool {
        a.code == b.code && a.step == b.step && a.patchCount == b.patchCount && a.patches == b.patches
    }

    /// The patch stepped to, nil on the overview.
    var patch: CommunityPatches.Patch? { step > 0 && step <= patches.count ? patches[step - 1] : nil }

    /// Share of the community's area the overview frames.
    static let coreFraction = 0.9
    /// The overview never comes closer than this (one 1.7 km cell would
    /// otherwise fill the screen at z14).
    static let overviewMaxZoom = 12.0
    /// A patch is framed whole, never closer than the packs' z15 (a 1 ha
    /// patch must not fly to street level). No lower bound: a huge patch is
    /// framed whole even below z11 — there its red ring and the presence
    /// regions mark it, and its outline appears as she zooms in.
    static let patchMaxZoom = Double(StyleBuilder.packMaxZoom)

    /// The closest the camera frames the current view at.
    var maxZoom: Double { step == 0 ? Self.overviewMaxZoom : Self.patchMaxZoom }

    /// From this zoom the soloed community is drawn from its own TASVEG
    /// polygons; below it from where.bin. The z0–10 tiles are dominant-class
    /// generalisations, but compared on the device (2026-11-03, DAM around
    /// Ben Lomond, DEBUG `-spotlightPolygonsFrom` + `-debugSpotlightFrame
    /// NO`): from the z9 tiles its stands read true to shape and the 1.7 km
    /// cells look crude beside them; at z8 the tiles keep only a scatter of
    /// specks and DAM all but vanishes — so the cells hand over at z9.
    /// (Ids, and so the stepped-to patch's red line, still need z11.)
    static let polygonsFrom: Int = {
        #if DEBUG
        let v = UserDefaults.standard.integer(forKey: "spotlightPolygonsFrom")
        if v > 0 { return v }
        #endif
        return 9
    }()

    /// What the camera frames now [west, south, east, north], for a view of
    /// width / height `aspect`: the core (the smallest box holding 90 % of
    /// the area — outliers framed out), or the whole patch.
    func bounds(aspect: Double = 1) -> [Double] {
        if let patch { return patch.bbox }
        guard let core = grid.coreBox(cells, fraction: Self.coreFraction, aspect: aspect),
              let all = grid.coreBox(cells, fraction: 1, aspect: aspect)
        else { return [143.8, -43.7, 148.5, -39.5] }
        let coreBounds = grid.bounds(of: core), allBounds = grid.bounds(of: all)
        // every cell when that costs next to nothing: DOB's core leaves
        // out the far south (Bruny, the Huon) to save 0.38 of a level
        let view = CGSize(width: 1000 * aspect, height: 1000)
        let cost = Self.fitZoom(coreBounds, in: view) - Self.fitZoom(allBounds, in: view)
        return cost.isFinite && cost <= Self.wholeCost ? allBounds : coreBounds
    }

    /// The most zoom the overview gives up to show every cell rather than
    /// the core. On a landscape iPad DOB's far south costs 0.38 (shown);
    /// DAM's outliers cost more than 0.41 on the phone (its core stays: Leo's
    /// TestFlight case; SpotlightTests and MapFramingTests pin both).
    static let wholeCost = 0.4

    /// The patch's label point (inside it), for finding its polygon's id.
    var patchPoint: (latitude: Double, longitude: Double)? {
        guard let p = patch?.p, p.count == 2 else { return nil }
        return (p[1], p[0])
    }

    /// The zoom at which box `b` just fits a view of `size` points
    /// (MapLibre Native's world is 512 pt across at z0; Web Mercator y).
    static func fitZoom(_ b: [Double], in size: CGSize) -> Double {
        func y(_ lat: Double) -> Double {
            let s = sin(lat * .pi / 180)
            return 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
        }
        let dx = (b[2] - b[0]) / 360, dy = abs(y(b[1]) - y(b[3]))
        guard dx > 0, dy > 0, size.width > 0, size.height > 0 else { return .nan }
        return log2(min(Double(size.width) / (dx * 512), Double(size.height) / (dy * 512)))
    }

    // MARK: Presence overlay (below `polygonsFrom`, rare patches below z11)

    /// A community of at most this many cells is "rare": its small patches
    /// are drawn as ringed dots — a 3.5 ha patch is a speck, not a 1.7 km
    /// square (a 30× exaggeration) — at every zoom, phone and iPad alike.
    static let dotsUpToCells = 40

    /// The presence cells as GeoJSON, property `k`:
    /// - `cell`: the cells with ≥ 5 % of their area in the community,
    ///   dissolved into regions (`Grid.regions`): one polygon per connected
    ///   region, holes kept, so the map draws ONE casing round each region —
    ///   never a keyline per cell;
    /// - `trace`: cells with less (a little of it somewhere in here), also
    ///   dissolved, drawn as a pale tint without a line — except for a rare
    ///   community, whose traces are spots instead;
    /// - `spot`: ringed dots for a rare community: on every patch's label
    ///   point when all its patches are known (`patchCount` ≤ the ten
    ///   listed), else on each trace cell's centre;
    /// - `patch`: the largest patches' label points, `n` = 1…10 (the red ring
    ///   of the stepped-to one).
    static func presenceGeoJSON(cells: [CommunityPresence.Cell], grid: CommunityPresence.Grid,
                                patches: [CommunityPatches.Patch], patchCount: Int = .max) -> [String: Any] {
        func feature(_ kind: String, _ type: String, _ coordinates: Any, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "Feature", "geometry": ["type": type, "coordinates": coordinates],
             "properties": extra.merging(["k": kind]) { a, _ in a }]
        }
        var features: [[String: Any]] = []
        let rare = cells.count <= dotsUpToCells
        let full = Set(cells.lazy.filter { $0.level >= 2 }.map(\.index))
        let traces = cells.filter { $0.level < 2 }
        for polygon in grid.regions(full) { features.append(feature("cell", "Polygon", polygon)) }
        if !rare {
            for polygon in grid.regions(Set(traces.map(\.index))) { features.append(feature("trace", "Polygon", polygon)) }
        } else if patchCount <= patches.count {
            for patch in patches where patch.p.count == 2 { features.append(feature("spot", "Point", patch.p)) }
        } else {
            for cell in traces {
                let p = grid.centre(cell.index)
                features.append(feature("spot", "Point", [p.longitude, p.latitude]))
            }
        }
        for (i, patch) in patches.enumerated() where patch.p.count == 2 {
            features.append(feature("patch", "Point", patch.p, ["n": i + 1]))
        }
        return ["type": "FeatureCollection", "features": features]
    }
}

extension AppModel {
    /// Solo `code` on the map and fly to its core distribution. The card (if
    /// any) stays: on the iPad it sits beside the map, on the phone the
    /// sheet drops to its glance.
    func showOnMap(_ code: String) {
        let library = PlantLibrary.shared
        let cells = library.presence?.cells(code) ?? []
        guard layers.overlay == .vegetation, let presence = library.presence, !cells.isEmpty else {
            // no table: the same-community line alone
            if keyHighlight != code { keyHighlight = code }
            return
        }
        let info = library.patches?.communities[code]
        spotlightRestoresCamera = false
        spotlight = Spotlight(code: code, step: 0, cells: cells, grid: presence.grid, patches: info?.top ?? [],
                              patchCount: info?.patches ?? 0)
        if keyHighlight != code { keyHighlight = code }
    }

    /// Previous / next: the overview ↔ the largest patches, in order (›
    /// from the overview flies straight to the largest).
    func stepSpotlight(_ delta: Int) {
        guard var s = spotlight else { return }
        let next = s.step + delta
        guard (0 ... s.patches.count).contains(next) else { return }
        s.step = next
        spotlight = s
    }

    /// × / Escape: the fade goes and the camera flies back.
    func exitSpotlight() {
        guard let code = spotlight?.code else { return }
        spotlightRestoresCamera = true
        spotlight = nil
        // its own highlight goes with it (never one set since)
        if keyHighlight == code { keyHighlight = nil }
    }

    /// A new view — a map tap, a search pick, a selection: the fade goes,
    /// the camera stays, and so does nothing of it: its own key highlight
    /// (the dashed same-community line) goes too (finding 11).
    func endSpotlight() {
        guard let code = spotlight?.code else { return }
        spotlightRestoresCamera = false
        spotlight = nil
        if keyHighlight == code { keyHighlight = nil }
    }
}

/// The map's state line while a community is soloed: "DCO everywhere" or
/// "DCO · largest patch 2 of 10", previous / next, and ×. One glass
/// capsule on the navigation layer.
struct SpotlightPill: View {
    let model: AppModel
    let spotlight: Spotlight

    var body: some View {
        HStack(spacing: 2) {
            step(-1, "chevron.left", "Previous", enabled: spotlight.step > 0)
            // never truncated: the lines wrap (Dynamic Type) and the pill grows
            VStack(alignment: .leading, spacing: 0) {
                Text("\(codeText)  \(titleText)")
                Text(subtitle)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.ink)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenTitle)
            .accessibilityIdentifier("spotlight-title")
            step(1, "chevron.right", "Next patch", enabled: spotlight.step < spotlight.patches.count)
            Button {
                model.exitSpotlight()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Stop showing \(spotlight.code)")
            .accessibilityIdentifier("spotlight-close")
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        // a step to the next patch is a detent she chose (DESIGN.md
        // "Haptics"); the flight itself is a cut under Reduce Motion
        .sensoryFeedback(.selection, trigger: spotlight.step)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spotlight-pill")
    }

    private var codeText: Text {
        Text(spotlight.code)
            .font(.footnote.weight(.semibold).uppercaseSmallCaps())
            .tracking(0.5)
            .foregroundStyle(DesignColor.codeInk)
    }

    private var titleText: Text {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DesignColor.ink)
    }

    private var title: String {
        spotlight.step == 0 ? "everywhere" : "patch \(spotlight.step) of \(spotlight.patches.count)"
    }

    /// "1,537 patches" on the overview; the patch's area on a step
    /// ("4,400 ha"). The order (largest first) is said to VoiceOver only.
    private var subtitle: String {
        if spotlight.step == 0 {
            let n = spotlight.patchCount
            return n > 0 ? "\(n.formatted()) patch\(n == 1 ? "" : "es")" : "statewide"
        }
        return "\(Self.area(spotlight.patches[spotlight.step - 1].ha)) ha"
    }

    /// Hectares as the pill prints them: rounded to two figures from 100 ha.
    static func area(_ ha: Double) -> String {
        ha >= 100 ? WhereElse.round(ha).formatted() : ha.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    private var spokenTitle: String {
        if spotlight.step == 0 { return "\(spotlight.code) everywhere, \(subtitle)" }
        let ha = spotlight.patches[spotlight.step - 1].ha
        return "\(spotlight.code), patch \(spotlight.step) of \(spotlight.patches.count), largest first, "
            + "\(ha >= 100 ? "about " : "")\(Self.area(ha)) hectares"
    }

    private func step(_ delta: Int, _ symbol: String, _ label: String, enabled: Bool) -> some View {
        Button {
            model.stepSpotlight(delta)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(delta < 0 && spotlight.step == 1 ? "Back to everywhere" : label)
        .accessibilityIdentifier(delta < 0 ? "spotlight-previous" : "spotlight-next")
    }
}
