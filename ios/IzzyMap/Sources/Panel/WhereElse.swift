import IzzyKit
import SwiftUI

/// "Where else does this grow?": the community's cells statewide (where.bin)
/// in ink — graded by how much of each ~2 km square it covers — on the
/// paper Tasmania, the tapped spot ringed, its extent as a caption, and
/// "Show on map", which solos it on the map and flies there (Spotlight).
struct WhereElse: View {
    let model: AppModel
    let code: String
    let latitude: Double?
    let longitude: Double?
    @State private var cells: [(latitude: Double, longitude: Double, level: Int)]?
    @ScaledMetric(relativeTo: .body) private var mapWidth = 128

    private var library: PlantLibrary { .shared }

    var body: some View {
        if let outline = library.outline, let presence = library.presence, presence.cellCount(code) > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where else it grows")
                    .font(.headline)
                    .foregroundStyle(DesignColor.ink)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .top, spacing: 14) {
                    Button(action: showOnMap) {
                        TasmaniaMiniMap(outline: outline,
                                        marks: .presence(cells ?? [], cellSize: (presence.grid.lonStep, presence.grid.latStep)),
                                        ring: latitude.flatMap { lat in longitude.map { (lat, $0) } })
                            .frame(width: min(mapWidth, 170))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(caption)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        InkKey(items: [(TasmaniaMiniMap.presenceInk[1], "trace"), (TasmaniaMiniMap.presenceInk[4], "most of a 2 km square")])
                            .fixedSize()
                        Button(action: showOnMap) {
                            Label("Show on map", systemImage: "scope")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignColor.ink)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityHint("Shows every patch of \(code) on the map, the rest faded")
                        .accessibilityIdentifier("show-on-map")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(MiniMapCredits.presence)
                    .font(.caption2)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("where-else")
            .task(id: code) {
                let grid = presence.grid
                let code = self.code
                cells = await Task.detached(priority: .utility) {
                    presence.cells(code).map { c in
                        let p = grid.centre(c.index)
                        return (p.latitude, p.longitude, c.level)
                    }
                }.value
            }
        }
    }

    private var caption: String {
        guard let c = library.patches?.communities[code] else { return "\(code) across the state." }
        let ha = c.ha >= 100 ? "About \(Self.round(c.ha).formatted()) ha" : "\(c.ha.formatted(.number.precision(.fractionLength(0 ... 1)))) ha"
        return "\(ha) statewide, in \(c.patches.formatted()) patch\(c.patches == 1 ? "" : "es")."
    }

    /// Two significant figures: "about 12 000 ha", never false precision.
    static func round(_ ha: Double) -> Int {
        guard ha >= 100 else { return Int(ha.rounded()) }
        let p = pow(10, floor(log10(ha)) - 1)
        return Int((ha / p).rounded() * p)
    }

    private func showOnMap() { model.showOnMap(code) }
}
