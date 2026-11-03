import SwiftUI

/// The map's (i) control, bottom trailing: opens the credits for what is on
/// screen (replaces MapLibre's attribution button, hidden in MapCoordinator).
struct AttributionButton: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var size = 32
    private var hitSize: CGFloat { max(44, size) }

    var body: some View {
        Button(action: action) {
            Image(systemName: "info")
                .font(.footnote.weight(.semibold))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: hitSize, height: hitSize)
                .contentShape(.circle)
        }
        // the hit area overhangs the glyph: lay out by the glyph, so its
        // edges sit exactly on the margins the root gives it
        .padding(-(hitSize - size) / 2)
        .buttonStyle(.plain)
        .foregroundStyle(DesignColor.ink)
        .hoverEffect(.highlight)
        .mapChrome()
        .accessibilityLabel("Map credits")
        .accessibilityIdentifier("attribution-button")
    }
}

/// Credits for the sources visible right now.
struct AttributionSheet: View {
    let map: MapLiveState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let credits = Attribution.credits(forSources: map.visibleSources)
                Section {
                    if credits.isEmpty {
                        Text("Nothing from a data provider is on the map right now.")
                            .foregroundStyle(DesignColor.inkSecondary)
                    }
                    ForEach(credits) { credit in
                        CreditRow(credit: credit)
                    }
                } header: {
                    Text("On the map now").panelHeader()
                }
                .panelRows()
                Section {
                    NavigationLink {
                        AcknowledgementsView(onGlass: true)
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("acknowledgements-link")
                } footer: {
                    Text("The software and model inside IzzyMap, with their licences.")
                }
                .panelRows()
                // TODO(M7): link to About's full credits by licence regime.
            }
            .panelListSurface()
            .navigationTitle("Map Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("attribution-sheet")
    }
}

private struct CreditRow: View {
    let credit: Credit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source = credit.source {
                Link(credit.title, destination: source).font(.body)
            } else {
                Text(credit.title)
            }
            HStack(spacing: 6) {
                if !credit.holder.isEmpty { Text(credit.holder) }
                Link(credit.licence.name, destination: credit.licence.url)
            }
            .font(.subheadline)
            .foregroundStyle(DesignColor.inkSecondary)
            if let terms = credit.terms {
                Text(terms).font(.footnote).foregroundStyle(DesignColor.inkSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}
