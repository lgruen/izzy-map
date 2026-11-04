import IzzyKit
import SwiftUI

/// One plant in a list, photo first: a square thumbnail (pictogram
/// fallback), the botanical name in New York italic with ranks upright,
/// "common · forms", and an ink bar for the measure the list is ranked
/// by (`ListMetric`). A group (broad-sense name) shows its size and a
/// chevron.
struct PlantRow: View {
    let model: AppModel
    let entry: PlantCatalog.Entry
    let context: PlantContext
    /// Names the list, so the zoom transition knows which row it left.
    let list: String
    /// What the bar shows, and the list's largest value (bars are relative to it).
    var metric: ListMetric = .none
    var maxValue: Double = 1
    @Environment(\.cardNamespace) private var namespace
    @ScaledMetric(relativeTo: .body) private var thumb = 56

    private var source: String { "\(list)-\(entry.key)" }

    var body: some View {
        Button {
            if let group = entry.group {
                model.push(.group(key: group.key, context: context))
            } else {
                model.push(.plant(id: entry.plant.id, key: entry.key, context: context, source: source))
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                PlantThumb(plant: entry.plant, side: min(thumb, 80))
                    .modifier(ZoomSource(id: source, namespace: namespace))
                VStack(alignment: .leading, spacing: 3) {
                    if let group = entry.group {
                        Text(BotanicalNames.species(group.key) + AttributedString(" (broad sense)"))
                            .font(.body)
                            .fontDesign(.serif)
                            .foregroundStyle(DesignColor.ink)
                        Text([group.common, "\(group.size) species"].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                    } else {
                        Text(BotanicalNames.species(entry.plant.name))
                            .font(.body)
                            .fontDesign(.serif)
                            .foregroundStyle(DesignColor.ink)
                        if !entry.plant.subline.isEmpty {
                            Text(entry.plant.subline)
                                .font(.subheadline)
                                .foregroundStyle(DesignColor.secondaryInk)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let value = metric.value(entry) {
                    EvidenceBar(value: value, max: maxValue, figure: metric == .sites ? entry.sites : nil)
                }
                if entry.group != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DesignColor.secondaryInk)
                }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("plant-row-\(entry.key)")
    }

    private var spoken: String {
        if let g = entry.group {
            return "\(g.common.map { "\($0), " } ?? "")\(g.key) in the broad sense, \(g.size) species"
        }
        var parts = [entry.plant.name]
        if !entry.plant.subline.isEmpty { parts.append(entry.plant.subline) }
        if metric == .indicator, let v = metric.value(entry) {
            parts.append("indicator \(Int((100 * v / max(maxValue, 1e-12)).rounded())) percent of the top species")
        }
        if let s = entry.sites { parts.append("\(s) site\(s == 1 ? "" : "s") with a record") }
        if !entry.plant.flowering.isEmpty {
            parts.append(Flowering.spoken(entry.plant.flowering, now: Calendar.current.component(.month, from: .now)))
        }
        return parts.joined(separator: ", ")
    }
}

/// `matchedTransitionSource` when a namespace is set.
struct ZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// What a list is ranked by, which its bars show (never a different
/// measure from the order: bars that rise and fall down a ranked list read
/// as broken).
enum ListMetric: Equatable {
    /// The "often recorded" ranking: how characteristic of the community
    /// (IndVal), relative to the list's top species. No figure — the
    /// score's absolute value means nothing to a reader.
    case indicator
    /// Recorded sites, most first, with the count.
    case sites
    case none

    func value(_ e: PlantCatalog.Entry) -> Double? {
        switch self {
        case .indicator: e.score
        case .sites: e.sites.map(Double.init)
        case .none: nil
        }
    }

    /// The bar column's heading.
    var heading: String? {
        switch self {
        case .indicator: "Characteristic"
        case .sites: "Sites"
        case .none: nil
        }
    }
}

/// A short ink bar against the list's maximum, with the figure under it
/// when it is a count.
struct EvidenceBar: View {
    let value: Double
    let max: Double
    var figure: Int?
    @ScaledMetric(relativeTo: .caption2) private var width = 40

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignColor.keyline.opacity(0.35))
                Rectangle()
                    .fill(DesignColor.ink)
                    .frame(width: width * CGFloat(value / Swift.max(1e-12, max)).clamped(to: 0.06 ... 1))
            }
            .frame(width: width, height: 4)
            if let figure {
                Text("\(figure)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
            }
        }
        .accessibilityHidden(true)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// One of the three lists: a heading, a line of what it means, six rows,
/// then "Show all (n)".
struct PlantListSection: View {
    let model: AppModel
    let id: String
    let title: String
    let subtitle: Text
    let entries: [PlantCatalog.Entry]
    let context: PlantContext
    var metric: ListMetric = .sites
    @State private var showAll = false
    @ScaledMetric(relativeTo: .caption2) private var barWidth = 40
    static let first = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(DesignColor.ink)
                Spacer()
                Text("\(entries.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            subtitle
                .font(.footnote)
                .foregroundStyle(DesignColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            if let heading = metric.heading {
                // the bar column's heading, over the bars
                Text(heading)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            let maxValue = entries.compactMap { metric.value($0) }.max() ?? 1
            ForEach(showAll ? entries : Array(entries.prefix(Self.first)), id: \.key) { e in
                PlantRow(model: model, entry: e, context: context, list: id, metric: metric, maxValue: maxValue)
            }
            if !showAll, entries.count > Self.first {
                Button("Show all (\(entries.count))") { showAll = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("show-all-\(id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plant-list-\(id)")
    }
}
