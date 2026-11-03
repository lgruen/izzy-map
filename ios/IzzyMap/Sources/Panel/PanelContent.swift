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
                FeatureCard(model: model, selection: selection) { model.clearSelection() }
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
    @ScaledMetric(relativeTo: .title3) private var glyphSize = 22

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignColor.inkSecondary)
                    .accessibilityHidden(true)
                // TODO(M4): place and address search (IzzyKit index)
                // The prompt in secondaryLabel (≈ 3.4:1 on the field), not the
                // system placeholder grey (≈ 1.8:1): "Search places" is the
                // panel's resting label and must read over any map.
                TextField(text: $model.searchText,
                          prompt: Text("Search places").foregroundStyle(DesignColor.inkSecondary)) {
                    Text("Search places")
                }
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
                // ink, like every chrome glyph: no accent hue (DESIGN.md §2)
                LeafViewfinder(pointSize: glyphSize)
                    .foregroundStyle(DesignColor.ink)
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

/// The "Identify a plant" glyph: a leaf framed by viewfinder corners
/// (docs/DESIGN.md "Iconography"). SF Symbols has no such symbol, so it is
/// two system symbols: `viewfinder` at `pointSize`, `leaf` at
/// half that, set at its own point size and a heavier weight so its strokes
/// match the corners' (a scaled-down copy would thin them). Callers pass a
/// `@ScaledMetric`, so the pair follows Dynamic Type.
struct LeafViewfinder: View {
    var pointSize: CGFloat

    var body: some View {
        Image(systemName: "viewfinder")
            .font(.system(size: pointSize, weight: .medium))
            .overlay {
                Image(systemName: "leaf")
                    .font(.system(size: pointSize * 0.5, weight: .semibold))
            }
            .accessibilityHidden(true)
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
                    .foregroundStyle(DesignColor.inkSecondary)
            }
        } icon: {
            Image(systemName: "map")
                .foregroundStyle(DesignColor.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
