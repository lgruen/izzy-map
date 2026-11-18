import IzzyKit
import SwiftUI

/// A soil unit's facts on its card, in the geology card's form: the
/// unit's description (two lines, a tap shows the rest), then label/value
/// rows — soil order(s) with their glosses one tap away, profile class,
/// the sheet that mapped this polygon, the unit's mapped extent.
struct SoilFacts: View {
    let soils: SoilsFile?
    let selection: SoilSelection

    var body: some View {
        let unit = soils?.units[selection.code]
        VStack(alignment: .leading, spacing: 10) {
            if let description = unit?.description, !description.isEmpty {
                ExpandableText(text: description)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(description)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                if let unit {
                    row("Soil order") { OrderList(orders: unit.orders, glossary: soils?.orders ?? [:]) }
                    if let profile = unit.profile, !profile.isEmpty {
                        row("Profile class") { value(profile) }
                    }
                }
                if let sheet = selection.sheet.flatMap({ soils?.sheets[$0]?.name }) {
                    row("Map sheet") { value(sheet) }
                }
                if let unit {
                    row("Mapped extent") { value(unit.extentText()) }
                }
            }
        }
        .accessibilityIdentifier("soil-facts")
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(DesignColor.secondaryInk)
                .gridColumnAlignment(.leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(DesignColor.ink)
    }
}

/// The unit's ASC orders, main one first: names in one line, a tap opens
/// each order's one-sentence gloss under it (the key's disclosure idiom —
/// the card stays short; comparing units by tapping is the core gesture).
/// No order in the source: said so, not hidden.
private struct OrderList: View {
    let orders: [String]
    let glossary: [String: SoilsFile.Order]
    @State private var expanded = false

    var body: some View {
        if orders.isEmpty {
            Text("Not classified in the source")
                .font(.body)
                .foregroundStyle(DesignColor.secondaryInk)
        } else {
            let hasGloss = orders.contains { glossary[$0] != nil }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if expanded {
                        ForEach(orders, id: \.self) { order in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(order).font(.body).foregroundStyle(DesignColor.ink)
                                if let gloss = glossary[order]?.gloss {
                                    Text(gloss)
                                        .font(.footnote)
                                        .foregroundStyle(DesignColor.secondaryInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else {
                        Text(orders.joined(separator: ", "))
                            .font(.body)
                            .foregroundStyle(DesignColor.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if hasGloss {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DesignColor.secondaryInk)
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                guard hasGloss else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(orders.map { o in glossary[o].map { "\(o): \($0.gloss)" } ?? o }.joined(separator: ". "))
            .accessibilityIdentifier("soil-orders")
        }
    }
}

/// The key symbol of the mapped area's edge (the map's dash-dot line) on a
/// key box's white plate: the unmapped card's mark.
struct SoilExtentMark: View {
    var body: some View {
        Canvas { ctx, size in
            var line = Path()
            line.move(to: CGPoint(x: 3, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width - 3, y: size.height / 2))
            ctx.stroke(line, with: .color(.black.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .butt, dash: [7, 2, 1.4, 2]))
        }
        .frame(width: 28, height: 18)
        .background(DesignColor.keyPlate)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// "Show mapped areas": the camera frames every reconnaissance sheet.
struct ShowMappedAreasButton: View {
    let model: AppModel

    var body: some View {
        if let b = model.tables.soils?.sheetsBounds {
            Button {
                model.showArea(AreaBox(west: b.west, south: b.south, east: b.east, north: b.north))
            } label: {
                Label("Show mapped areas", systemImage: "viewfinder")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("show-mapped-soils")
        }
    }
}
