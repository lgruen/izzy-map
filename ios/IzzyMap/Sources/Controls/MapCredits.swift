import SwiftUI

/// The map's (i) control, bottom trailing: opens the credits for what is on
/// screen (replaces MapLibre's attribution button, hidden in MapCoordinator).
struct AttributionButton: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var size = 32

    var body: some View {
        Button(action: action) {
            Image(systemName: "info")
                .font(.footnote.weight(.semibold))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: max(44, size), height: max(44, size))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .hoverEffect(.highlight)
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
                            .foregroundStyle(.secondary)
                    }
                    ForEach(credits) { credit in
                        CreditRow(credit: credit)
                    }
                } header: {
                    Text("On the map now")
                }
                // TODO(M7): link to About's full credits by licence regime.
            }
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
            .foregroundStyle(.secondary)
            if let terms = credit.terms {
                Text(terms).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
