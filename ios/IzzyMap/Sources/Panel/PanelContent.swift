import SwiftUI

/// The panel's content, identical in the compact bottom sheet and the
/// regular-width floating card: search, plant ID, and the tapped feature.
struct PanelContent: View {
    @Bindable var model: AppModel
    /// The search field gained focus (the compact sheet rises to large).
    var onSearchFocus: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(model: model, onSearchFocus: onSearchFocus)
            if let selection = model.selection {
                FeatureCard(selection: selection) { model.clearSelection() }
                    .id(selection.id)
                    .transition(.opacity)
            } else if model.data.isEmpty {
                NoDataNotice()
            }
        }
        .animation(.snappy, value: model.selection?.id)
    }
}

/// Search field and the "Identify a plant" button.
struct PanelHeader: View {
    @Bindable var model: AppModel
    var onSearchFocus: () -> Void
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldHeight = 48

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // TODO(M4): place and address search (IzzyKit index)
                TextField("Search places", text: $model.searchText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("search-field")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: fieldHeight)
            .background(.fill.tertiary, in: .capsule)
            .contentShape(.capsule)
            .onTapGesture { searchFocused = true }

            Button {
                model.present(.plantID)
            } label: {
                Image(systemName: "camera.macro")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(width: fieldHeight, height: fieldHeight)
                    .background(.fill.tertiary, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Identify a plant")
            .accessibilityIdentifier("plant-id-button")
        }
        .onChange(of: searchFocused) { _, focused in
            if focused { onSearchFocus() }
        }
    }
}

/// Shown when no map archive is on the device.
struct NoDataNotice: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("No offline maps on this device yet")
                    .font(.subheadline.weight(.semibold))
                Text("Online, the detailed topographic map still loads when you zoom in close.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "map")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
