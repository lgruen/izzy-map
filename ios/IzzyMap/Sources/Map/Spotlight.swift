import IzzyKit
import SwiftUI

/// "Show on map": one TASVEG community soloed — every other community
/// faded to a trace — with the camera on its statewide extent, then
/// stepping through its largest patches (where_patches.json). The map's
/// pill says what is shown and steps; Escape or × exits and the camera
/// flies back. A tap on the map ends it where she is.
nonisolated struct Spotlight: Equatable, Sendable {
    let code: String
    /// 0: statewide; 1…n: the n-th largest patch.
    var step: Int
    /// The community's statewide extent [west, south, east, north].
    let extent: [Double]
    /// Largest patches first.
    let patches: [CommunityPatches.Patch]
    /// Patches statewide (the caption's "3,383 patches").
    let patchCount: Int

    /// What the camera frames now [west, south, east, north].
    var bounds: [Double] { step == 0 ? extent : patches[step - 1].bbox }

    /// Statewide extent of a community's presence cells (half a cell of
    /// margin), nil when it has none.
    static func extent(of cells: [CommunityPresence.Cell], grid: CommunityPresence.Grid) -> [Double]? {
        guard !cells.isEmpty else { return nil }
        var w = Double.infinity, s = Double.infinity, e = -Double.infinity, n = -Double.infinity
        for c in cells {
            let p = grid.centre(c.index)
            w = min(w, p.longitude); e = max(e, p.longitude)
            s = min(s, p.latitude); n = max(n, p.latitude)
        }
        return [w - grid.lonStep / 2, s - grid.latStep / 2, e + grid.lonStep / 2, n + grid.latStep / 2]
    }

    /// A box at least `minSpan` degrees across (a 1 ha patch must not fly
    /// the camera to street level).
    static func padded(_ b: [Double], minSpan: Double = 0.025) -> [Double] {
        let cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2
        let hw = max((b[2] - b[0]) / 2, minSpan / 2), hh = max((b[3] - b[1]) / 2, minSpan * 0.75 / 2)
        return [cx - hw, cy - hh, cx + hw, cy + hh]
    }
}

extension AppModel {
    /// Solo `code` on the map and fly to its statewide extent. The card (if
    /// any) stays: on the iPad it sits beside the map, on the phone the
    /// sheet drops to its glance.
    func showOnMap(_ code: String) {
        let library = PlantLibrary.shared
        guard layers.overlay == .vegetation, let presence = library.presence,
              let extent = Spotlight.extent(of: presence.cells(code), grid: presence.grid) else {
            // no table: the same-community line alone
            if keyHighlight != code { keyHighlight = code }
            return
        }
        let info = library.patches?.communities[code]
        spotlightRestoresCamera = false
        spotlight = Spotlight(code: code, step: 0, extent: extent, patches: info?.top ?? [],
                              patchCount: info?.patches ?? 0)
        if keyHighlight != code { keyHighlight = code }
    }

    /// Previous / next: statewide ↔ the largest patches, in order.
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

    /// A map tap: the fade goes, the camera stays.
    func endSpotlight() {
        guard spotlight != nil else { return }
        spotlightRestoresCamera = false
        spotlight = nil
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
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(spotlight.code)
                        .font(.footnote.weight(.semibold).uppercaseSmallCaps())
                        .tracking(0.5)
                        .foregroundStyle(DesignColor.codeInk)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                }
                Text(subtitle)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.ink)
            }
            .lineLimit(1)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
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
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spotlight-pill")
    }

    private var title: String {
        spotlight.step == 0 ? "everywhere" : "patch \(spotlight.step) of \(spotlight.patches.count)"
    }

    private var subtitle: String {
        if spotlight.step == 0 {
            let n = spotlight.patchCount
            return n > 0 ? "\(n.formatted()) patch\(n == 1 ? "" : "es")" : "statewide"
        }
        let ha = spotlight.patches[spotlight.step - 1].ha
        let size = ha >= 100 ? "about \(WhereElse.round(ha).formatted()) ha" : "\(ha.formatted(.number.precision(.fractionLength(0 ... 1)))) ha"
        return "largest first · \(size)"
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
