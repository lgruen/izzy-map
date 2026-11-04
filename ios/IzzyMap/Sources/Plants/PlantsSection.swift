import IzzyKit
import SwiftUI

/// A community card's plant data for one tap.
nonisolated enum PlantsState: Equatable, Sendable {
    case loading
    /// Nothing to list (water, urban, …): no section at all.
    case empty
    case failed
    case ready(PlantCatalog.CardLists)

    var lists: PlantCatalog.CardLists? {
        if case let .ready(l) = self { return l }
        return nil
    }

    /// Builds the three lists off the main thread.
    @MainActor static func load(code: String, latitude: Double?, longitude: Double?) async -> PlantsState {
        guard let catalog = await PlantLibrary.shared.load() else { return .failed }
        let lists = await Task.detached(priority: .userInitiated) {
            catalog.cardLists(code: code, latitude: latitude, longitude: longitude)
        }.value
        return lists.isEmpty ? .empty : .ready(lists)
    }
}

/// Actions the panel container offers its content.
struct PanelActions {
    /// Raise the compact sheet (no-op in the floating card).
    var raise: () -> Void = {}
    /// Scroll the panel to an anchor id.
    var scrollTo: (String) -> Void = { _ in }
    /// The card reports the bottom of its glance (y in `PanelContent.space`).
    var peek: (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var panelActions = PanelActions()
}

/// The card's peek: the community's most characteristic plants as faces
/// (photos, pictograms when there are none) — each opens its plant — and
/// under them a plain chevron row, "All 342 plants", which opens the
/// lists. (Not a capsule beside the faces: "+307" read as more photos,
/// and a filled capsule on the sheet's glass is glass on glass.)
struct PlantFaces: View {
    let model: AppModel
    let state: PlantsState
    let context: PlantContext
    @Environment(\.panelActions) private var actions
    @Environment(\.cardNamespace) private var namespace
    @ScaledMetric(relativeTo: .body) private var side = 44

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading plants…")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .frame(minHeight: side)
        case .failed:
            // bundled data that can't be read: the one remedy is a reinstall
            StateLine(symbol: StateSymbol.failed,
                      text: "The plant lists couldn’t be read. Reinstalling IzzyMap restores them.")
                .accessibilityIdentifier("plants-failed")
        case .empty:
            // water, rock, cleared or built land: say so in one line, so
            // the card doesn't look as if something went missing
            StateLine(symbol: "leaf", text: Self.emptyText(group: model.communities[context.code ?? ""]?.group))
                .accessibilityIdentifier("plants-empty")
        case let .ready(lists):
            ViewThatFits(in: .horizontal) {
                strip(lists, count: 5)
                strip(lists, count: 4)
                strip(lists, count: 3)
                strip(lists, count: 2)
            }
        }
    }

    /// No plant named, recorded in, or recorded near this community.
    nonisolated static func emptyText(group: String?) -> String {
        switch group {
        case "Modified land": "No plant lists for cleared or built land."
        case "Other natural environments": "No plant lists for water, sand or bare rock."
        default: "No plants named or recorded for this community."
        }
    }

    private func strip(_ lists: PlantCatalog.CardLists, count: Int) -> some View {
        let faces = lists.faces(limit: count)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ForEach(faces, id: \.key) { e in
                    Button {
                        if let g = e.group {
                            model.push(.group(key: g.key, context: context))
                        } else {
                            model.push(.plant(id: e.plant.id, key: e.key, context: context, source: "face-\(e.key)"))
                        }
                    } label: {
                        PlantThumb(plant: e.plant, side: side)
                            .modifier(ZoomSource(id: "face-\(e.key)", namespace: namespace))
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel(e.group.map { "\($0.common ?? $0.key), \($0.size) species" } ?? e.plant.name)
                    .accessibilityIdentifier("plant-face")
                }
                Spacer(minLength: 0)
            }
            Button {
                PlantLibrary.shared.sectionExpanded = true
                actions.raise()
                actions.scrollTo(PlantsSection.anchor)
            } label: {
                HStack(spacing: 6) {
                    Text("All \(lists.distinctCount.formatted()) plants")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DesignColor.ink)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("All \(lists.distinctCount) plants: \(lists.summary)")
            .accessibilityHint("Shows the plant lists")
            .accessibilityIdentifier("plants-more")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plant-faces")
    }
}

/// The card's Plants section: a header row with the counts that expands
/// to the three lists — Named in the description (B), Often recorded in
/// this community (C1), Recorded near here (C2). Collapsed by default so
/// the card stays a compact label; once opened, later cards this session
/// open expanded.
struct PlantsSection: View {
    static let anchor = "plants-section"
    let model: AppModel
    let code: String
    let state: PlantsState
    let context: PlantContext
    @Environment(\.panelActions) private var actions

    private var expanded: Bool { PlantLibrary.shared.sectionExpanded }

    var body: some View {
        if let lists = state.lists {
            VStack(alignment: .leading, spacing: 20) {
                Button {
                    let open = !expanded
                    PlantLibrary.shared.sectionExpanded = open
                    if open { actions.raise() }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plants")
                                .font(.headline)
                                .foregroundStyle(DesignColor.ink)
                            Text(lists.summary)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(DesignColor.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DesignColor.secondaryInk)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                .accessibilityIdentifier("plants-toggle")
                if expanded {
                    listsBody(lists)
                }
            }
            .id(Self.anchor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plants-section")
            #if DEBUG
            // screenshots of the scroll edge: `-debugScrollCard YES`
            .task {
                guard UserDefaults.standard.bool(forKey: "debugScrollCard") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                actions.scrollTo(Self.anchor)
            }
            #endif
        }
    }

    @ViewBuilder private func listsBody(_ lists: PlantCatalog.CardLists) -> some View {
        if !lists.named.isEmpty {
            PlantListSection(model: model, id: "named", title: "Named in the description",
                             subtitle: Text("Species the \(Text("From Forest to Fjaeldmark").italic()) account of this community mentions."),
                             entries: lists.named, context: context, metric: .none)
        }
        let often = lists.often
        if !often.entries.isEmpty {
            let sites = often.sites.map { "\($0.formatted()) site\($0 == 1 ? "" : "s")" }
            if often.isTally {
                PlantListSection(model: model, id: "often", title: "Recorded in this community",
                                 subtitle: Text("\(Text("Few records\(sites.map { " (\($0))" } ?? "")").fontWeight(.semibold)) — every species with an Atlas of Living Australia record inside mapped \(code), most sites first. Bars count ~100 m sites with a record."),
                                 entries: often.entries, context: context, metric: .sites)
            } else {
                PlantListSection(model: model, id: "often", title: "Often recorded in this community",
                                 subtitle: Text("Species with Atlas of Living Australia records inside mapped \(code) across the state\(sites.map { " (\($0) recorded)" } ?? ""), most characteristic first: recorded in many of its sites and seldom elsewhere. Bars show that score against the top species."),
                                 entries: often.entries, context: context, metric: .indicator)
            }
        }
        if let near = lists.nearby, !near.entries.isEmpty {
            PlantListSection(model: model, id: "near", title: "Recorded near here",
                             subtitle: Text("\(near.entries.count.formatted()) species, \(near.shownTotal.formatted()) site records within roughly 1–1.5 km — what people happened to record, not a full survey. Most sites first."),
                             entries: near.entries, context: context, metric: .sites)
        } else if lists.nearby != nil {
            // a tapped spot nobody has recorded around: say it, honestly
            VStack(alignment: .leading, spacing: 2) {
                Text("Recorded near here")
                    .font(.headline)
                    .foregroundStyle(DesignColor.ink)
                    .accessibilityAddTraits(.isHeader)
                StateLine(symbol: "mappin.and.ellipse",
                          text: "No plant records within about 1.5 km of this spot — unrecorded, not necessarily bare.")
            }
            .accessibilityIdentifier("nearby-empty")
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(PlantCredits.plants)
            Text(PlantCredits.records)
            Text("“Named” lists from \(Text("From Forest to Fjaeldmark").italic()).")
        }
        .font(.caption)
        .foregroundStyle(DesignColor.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
}
