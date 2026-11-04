import IzzyKit
import SwiftUI

/// The overlay's key, drawn like a printed map key (docs/DESIGN.md §4):
/// keylined boxes on a white plate, one box spanning every code that shares
/// a fill, small-caps codes in a fixed column, names in New York with
/// botanical italics; groups as sticky section headers. Only vegetation
/// gets a section index — its groups have one-letter labels (the codes'
/// first letter); a column of whole words would squeeze the list.
struct LegendView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var widthClass

    /// The overlay shown: the active one, or vegetation while none is.
    private var overlay: Overlay { model.layers.overlay == .none ? .vegetation : model.layers.overlay }

    private var sections: [Legend.Section] {
        switch overlay {
        case .geology: Legend.geology(model.tables.geology)
        case .pre1750: Legend.pre1750(model.tables.pre1750)
        case .vegetation, .none: Legend.vegetation(model.tables.communities)
        }
    }

    var body: some View {
        let sections = sections
        // the code column's width: the longest ordinary code (geology's lone
        // "Unknown" may overhang rather than widen every row)
        let codeTemplate = sections.flatMap { $0.runs.flatMap(\.rows) }.map(\.code).filter { $0.count <= 5 }
            .max { $0.count < $1.count } ?? "WWW"
        List {
            // strength and the note sit under the title, part of the key's
            // head rather than a card of their own
            VStack(alignment: .leading, spacing: 10) {
                if model.layers.overlay != .none {
                    StrengthPicker(model: model)
                }
                if let note {
                    Text(note).font(.footnote).foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            ForEach(sections) { section in
                Section {
                    ForEach(section.runs) { run in
                        RunRow(run: run, overlay: overlay, opacity: opacity, codeTemplate: codeTemplate,
                               highlighted: model.keyHighlight, onTap: tapAction)
                    }
                    .listRowBackground(Color.clear)
                    // a printed key: no rules between entries, just air
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                } header: {
                    SectionHeader(section: section, showsLetter: overlay == .vegetation)
                }
                .sectionIndexLabel(overlay == .vegetation ? section.shortTitle : nil)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(overlay == .vegetation ? .visible : .hidden)
        .panelListSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legend")
    }

    private var title: String {
        switch overlay {
        case .vegetation, .none: "Vegetation key"
        case .pre1750: "Pre-1750 key"
        case .geology: "Geology key"
        }
    }

    /// The key mirrors the map: boxes composited at the current strength.
    private var opacity: Double {
        var state = model.layers
        state.overlay = overlay
        if model.layers.overlay == .none { state.strength = .full }
        return state.fillOpacity
    }

    private var note: String? {
        if model.layers.overlay == .none { return "The overlay is hidden — choose one in Layers." }
        if overlay == .pre1750 {
            return "An estimate of the vegetation before European clearing, modelled from remnants and historical records (NVIS V7.0, 1 ha cells)."
        }
        if overlay == .geology { return "Groups run from oldest to youngest." }
        return nil
    }

    /// Only vegetation rows act: a tap draws the same-community line.
    private var tapAction: ((String) -> Void)? {
        guard overlay == .vegetation, model.layers.overlay == .vegetation else { return nil }
        return { code in tap(code) }
    }

    /// A vegetation row draws the same-community line for its code (a second
    /// tap clears it); on iPhone the sheet then gets out of the way.
    private func tap(_ code: String) {
        model.clearSelection()
        // a second tap on the highlighted row clears it (and its "Show on
        // map"); otherwise the community is soloed and framed statewide
        if model.keyHighlight == code {
            model.toggleKeyHighlight(code)
            return
        }
        model.showOnMap(code)
        if widthClass == .compact { model.dismissModal() }
    }
}

/// A group's sticky header: (vegetation's index letter,) name, count.
private struct SectionHeader: View {
    let section: Legend.Section
    let showsLetter: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsLetter {
                Text(section.shortTitle).fontWeight(.semibold)
            }
            Text(section.title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text("\(section.count)").monospacedDigit()
                .foregroundStyle(DesignColor.secondaryInk)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(DesignColor.ink)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One key box beside the rows that share it.
private struct RunRow: View {
    let run: Legend.Run
    let overlay: Overlay
    let opacity: Double
    let codeTemplate: String
    let highlighted: String?
    /// nil: the rows are a plain key (geology, pre-1750) — text, not buttons.
    let onTap: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KeyBox(hex: run.color, opacity: opacity, height: run.rows.count > 1 ? nil : 18)
                .padding(.top, 2)
                .padding(.bottom, 1)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.rows) { row in
                    if let onTap {
                        let isOn = highlighted == row.code
                        Button { onTap(row.code) } label: {
                            KeyRowContent(row: row, overlay: overlay, codeTemplate: codeTemplate, isHighlighted: isOn)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spoken(row))
                        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                        .accessibilityHint(isOn ? "Clears the outline on the map"
                                                : "Shows this community everywhere on the map, the rest faded")
                    } else {
                        KeyRowContent(row: row, overlay: overlay, codeTemplate: codeTemplate, isHighlighted: false)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(spoken(row))
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func spoken(_ row: Legend.Row) -> String {
        switch overlay {
        case .pre1750: DisplayText.corrected(row.name)
        case .geology: "\(row.code), \(DisplayText.unitTitle(row.name))"
        case .vegetation, .none: "\(row.code), \(row.name)"
        }
    }
}

/// Code column + name (+ the highlight's checkmark).
private struct KeyRowContent: View {
    let row: Legend.Row
    let overlay: Overlay
    let codeTemplate: String
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if overlay != .pre1750 {
                Text(codeTemplate).hidden()
                    .font(codeFont)
                    .tracking(0.5)
                    .fixedSize()
                    .overlay(alignment: .leading) {
                        Text(row.code).font(codeFont).tracking(0.5).foregroundStyle(DesignColor.codeInk)
                            .fixedSize()
                    }
            }
            name
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHighlighted {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
            }
        }
    }

    private var codeFont: Font {
        overlay == .vegetation ? .footnote.weight(.semibold).uppercaseSmallCaps() : .footnote.weight(.semibold)
    }

    @ViewBuilder private var name: some View {
        switch overlay {
        case .geology:
            ExpandableText(text: DisplayText.unitTitle(row.name))
        case .pre1750:
            Text(BotanicalNames.attributed(DisplayText.corrected(row.name)))
                .font(.body).fontDesign(.serif).foregroundStyle(DesignColor.ink)
        case .vegetation, .none:
            Text(BotanicalNames.attributed(row.name))
                .font(.body).fontDesign(.serif).foregroundStyle(DesignColor.ink)
        }
    }
}

/// A geology description: two lines, a tap shows the rest (VoiceOver always
/// reads it whole — the row's label carries the full text).
private struct ExpandableText: View {
    let text: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private var truncated: Bool { !expanded && fullHeight > shownHeight + 1 }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(text)
                .font(.body)
                .foregroundStyle(DesignColor.ink)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    // the untruncated text, measured at the same width
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if truncated || expanded {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DesignColor.secondaryInk)
            }
        }
            .contentShape(.rect)
            .onTapGesture {
                guard truncated || expanded else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            }
    }
}
