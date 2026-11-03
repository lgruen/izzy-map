import IzzyKit
import SwiftUI

/// The tapped feature's card: key box, code and name answer "what is this?"
/// at a glance; facts follow. (Milestone 3 adds the F2F description, plants
/// and the tree data sheet.)
struct FeatureCard: View {
    let model: AppModel
    let selection: FeatureSelection
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            facts
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feature-card")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            mark
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                codeLine
                title
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenTitle)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            CloseButton(action: onClose)
        }
    }

    @ViewBuilder private var mark: some View {
        // The card's box names the unit by its OFFICIAL fill, at every
        // strength. Composited at the map's opacity over white (the key's
        // rule) it washed out to near-white for dark fills — WDR #326565 at
        // aerial-light 0.20 is #D6E0E0 — and Outlines left a white box with
        // a thin band: nothing that reads as "this community's colour". The
        // Layers key keeps mirroring the mode (its job is matching the map).
        switch selection.feature {
        case let .community(c):
            KeyBox(hex: c.colorHex, opacity: 1)
        case let .geology(symb):
            KeyBox(hex: model.tables.geology[symb]?.color, opacity: 1)
        case let .pre1750(mvs):
            KeyBox(hex: model.tables.pre1750[mvs]?.color, opacity: 1)
        case .tree:
            // the map's disc on a key box's white plate: treeGreen stays
            // 9:1 against white in dark mode too (on #1C1C1E it's ~2:1)
            Circle()
                .fill(DesignColor.treeGreen)
                .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
                .frame(width: 11, height: 11)
                .frame(width: 28, height: 18)
                .background(DesignColor.keyPlate)
                .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var codeLine: some View {
        switch selection.feature {
        case let .community(c): CodeText(code: c.code)
        case let .geology(symb): CodeText(code: symb, smallCaps: false)
        case let .pre1750(mvs): CodeText(code: "MVS \(mvs)")
        case let .tree(t):
            Text(t.isArea ? "Hobart significant trees" : "Hobart significant tree")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DesignColor.inkSecondary)
        }
    }

    @ViewBuilder private var title: some View {
        switch selection.feature {
        case let .community(c):
            NameText(BotanicalNames.attributed(c.name))
        case let .geology(symb):
            Text(model.tables.geology[symb].map { DisplayText.unitTitle($0.description) } ?? "Unknown unit")
                .font(.headline)
                .foregroundStyle(DesignColor.ink)
        case let .pre1750(mvs):
            NameText(BotanicalNames.attributed(model.tables.pre1750[mvs].map { DisplayText.corrected($0.name) } ?? "Unknown class"))
        case let .tree(t):
            let ref = model.tables.trees?.refs[t.ref]
            VStack(alignment: .leading, spacing: 1) {
                if let common = ref?.common, !common.isEmpty {
                    NameText(AttributedString(common.prefix(1).uppercased() + common.dropFirst()))
                    Text(BotanicalNames.species(ref?.name ?? ""))
                        .font(.body)
                        .fontDesign(.serif)
                        .foregroundStyle(DesignColor.ink)
                } else {
                    NameText(BotanicalNames.species(ref?.name ?? "Significant tree"))
                }
            }
        }
    }

    private var spokenTitle: String {
        switch selection.feature {
        case let .community(c): "Vegetation community \(c.code), \(c.name)"
        case let .geology(symb): "Geology unit \(symb), \(model.tables.geology[symb].map { DisplayText.unitTitle($0.description) } ?? "")"
        case let .pre1750(mvs): "Pre-1750 vegetation, \(model.tables.pre1750[mvs].map { DisplayText.corrected($0.name) } ?? mvs)"
        case let .tree(t):
            "Hobart significant tree, \(model.tables.trees?.refs[t.ref].map { [$0.common, $0.name].filter { !$0.isEmpty }.joined(separator: ", ") } ?? t.ref)"
        }
    }

    // MARK: Facts

    @ViewBuilder private var facts: some View {
        let rows = factRows
        if !rows.isEmpty || note != nil || link != nil {
            VStack(alignment: .leading, spacing: 10) {
                // label column + value column, both leading and top-aligned
                // on the first line: a long address wraps under itself
                // instead of ragged right-aligned lines
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(rows, id: \.label) { row in
                        GridRow {
                            Text(row.label)
                                .font(.subheadline)
                                .foregroundStyle(DesignColor.inkSecondary)
                                .gridColumnAlignment(.leading)
                            Text(row.value)
                                .font(.body)
                                .foregroundStyle(DesignColor.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(DesignColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private struct Row { let label: String; let value: String }

    private var factRows: [Row] {
        func rows(_ pairs: [(String, String?)]) -> [Row] {
            pairs.compactMap { label, value in
                guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return Row(label: label, value: value)
            }
        }
        switch selection.feature {
        case let .community(c):
            // (no "Map colour #hex" row: the key box is the colour)
            return rows([("Group", c.group), ("Structure", c.structure), ("Notable trees", c.notableTrees),
                         ("Weeds", c.weeds)])
        case let .geology(symb):
            let u = model.tables.geology[symb]
            return rows([("Age", u?.ageText()), ("Group", u?.group), ("Stratigraphy", u?.strat)])
        case let .pre1750(mvs):
            let u = model.tables.pre1750[mvs]
            // the plain-English gloss ("swampy grasses, sedges, etc."); the
            // NVIS group names are in the key
            let gloss = u.map { $0.groupDesc.prefix(1).uppercased() + $0.groupDesc.dropFirst() }
            return rows([("Group", gloss), ("Pre-1750 extent", u?.extentText())])
        case let .tree(t):
            let trees = model.tables.trees
            let ref = trees?.refs[t.ref]
            return rows([("Address", ref?.address), ("Trees", ref?.trees.map { "\($0)" }),
                         ("Register", t.ref), ("Position", DisplayText.treePosition(code: t.accuracy))])
        }
    }

    private var note: String? {
        switch selection.feature {
        case .pre1750:
            "Estimated vegetation before European clearing — a model built from remnants and historical records (NVIS V7.0, 1 ha cells). Cell edges are grid artefacts, not real boundaries."
        case let .tree(t):
            model.tables.trees?.refs[t.ref].flatMap { $0.note.isEmpty ? nil : $0.note }
        default: nil
        }
    }

    private var link: (title: String, url: URL)? {
        guard case let .geology(symb) = selection.feature,
              let s = model.tables.geology[symb]?.link, !s.isEmpty, let url = URL(string: s) else { return nil }
        return ("More about this unit — Geoscience Australia", url)
    }
}

/// A living thing's name: New York, botanical italics from the attributes.
struct NameText: View {
    let text: AttributedString
    init(_ text: AttributedString) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .fontDesign(.serif)
            .foregroundStyle(DesignColor.ink)
    }
}

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(DesignColor.inkSecondary)
                .frame(width: 32, height: 32)
                .background(.fill.tertiary, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .padding(.top, -6)
        // (Escape on a hardware keyboard: MapCommands)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("card-close")
    }
}
