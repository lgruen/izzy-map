import SwiftUI

/// The panel's scrolling content, identical in the compact bottom sheet
/// and the regular-width floating card: the tapped feature's card. The
/// search header is not in it: each container pins that as its top bar
/// (`.safeAreaBar`), so the card scrolls under it behind the system's soft
/// scroll edge instead of sliding bare under the grabber.
struct PanelContent: View {
    /// Coordinate space the card's glance is measured in.
    nonisolated static let space = "panel-content"
    @Bindable var model: AppModel

    /// Whether there is anything under the header.
    static func hasBody(_ model: AppModel) -> Bool {
        model.search.isActive || model.selection != nil || (model.data.isEmpty && model.shared.packs.isResolved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.search.isActive {
                // while searching the results stand in for the card (it
                // comes back when search closes)
                SearchResultsView(search: model.search)
                    .transition(.opacity)
            } else if let selection = model.selection {
                FeatureCard(model: model, selection: selection) { model.clearSelection() }
                    .id(selection.id)
                    .transition(.opacity)
            } else if model.data.isEmpty, model.shared.packs.isResolved {
                NoDataNotice()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: model.selection?.id)
        .animation(.snappy, value: model.search.isActive)
        .coordinateSpace(.named(Self.space))
    }
}

/// Search field and the "Identify a plant" button (Cancel while searching).
struct PanelHeader: View {
    @Bindable var model: AppModel
    var onSearchFocus: () -> Void = {}
    @ScaledMetric(relativeTo: .body) private var fieldHeight = 48
    @ScaledMetric(relativeTo: .title3) private var glyphSize = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row
            // the picked place: tap to fly there again, × to clear
            if let pin = model.search.pin, !model.search.isActive {
                SearchPlaceChip(result: pin.result) { model.search.refly() } onClear: { model.search.clearPin() }
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: model.search.pin?.result.id)
    }

    private var row: some View {
        HStack(spacing: 10) {
            SearchField(search: model.search, onFocus: onSearchFocus)

            if model.search.isActive {
                Button("Cancel") { model.search.end() }
                    .font(.body)
                    .foregroundStyle(DesignColor.ink)
                    .frame(minHeight: fieldHeight)
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("search-cancel")
                    .transition(.opacity)
            } else {
                Button {
                    model.present(.plantID)
                } label: {
                    // ink, like every chrome glyph: no accent hue (DESIGN.md §2)
                    LeafViewfinder(pointSize: glyphSize)
                        .foregroundStyle(DesignColor.ink)
                        .frame(width: fieldHeight, height: fieldHeight)
                        .background(.fill.tertiary, in: .circle)
                        .contentShape(.circle)
                        // the welcome's "this one" (App/FirstLaunch.swift),
                        // in the label colour: the sheet follows the system
                        .overlay {
                            if model.showsWelcome {
                                Circle().strokeBorder(DesignColor.ink.opacity(0.85), lineWidth: 2)
                                    .padding(-3)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Identify a plant")
                .accessibilityIdentifier("plant-id-button")
                #if DEBUG
                // screenshots: `-debugPlantID YES` opens Identify at launch
                .task {
                    guard UserDefaults.standard.bool(forKey: "debugPlantID"), !PlantIDDebug.opened else { return }
                    PlantIDDebug.opened = true
                    try? await Task.sleep(for: .seconds(1.5))
                    model.present(.plantID)
                }
                #endif
            }
        }
        .animation(.snappy, value: model.search.isActive)
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

/// Shown when no map archive is on the device (the essential pack missing
/// after a dropout; the "Maps arriving" chip has the progress).
struct NoDataNotice: View {
    var body: some View {
        let online = Connectivity.shared.online
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("No offline maps on this \(DeviceNoun.current) yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                Text(online ? "They’re on their way. Meanwhile the topographic map streams from theLIST."
                     : "They arrive once there’s reception.")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
            }
        } icon: {
            Image(systemName: online ? StateSymbol.get : StateSymbol.offline)
                .foregroundStyle(DesignColor.secondaryInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("no-data")
    }
}
