import SwiftUI

/// Floating glass controls at the top trailing edge (Maps pattern):
/// Layers and Location in one vertical capsule. MapLibre's compass sits
/// below it and appears once the map is rotated.
struct MapControls: View {
    @Bindable var model: AppModel
    /// Regular width presents Layers as a popover from its button; compact
    /// width presents it from the bottom sheet (which is already presented).
    var layersAsPopover: Bool

    static let buttonSize: CGFloat = 48
    /// The system appearance, for the popover (the buttons themselves are
    /// always light: they float over the always-light map).
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        VStack(spacing: 0) {
            MapControlButton(symbol: "square.3.layers.3d", label: "Layers") {
                model.present(.layers)
            }
            .accessibilityIdentifier("layers-button")
            .popover(isPresented: layersPopoverBinding) {
                LayersSheet(model: model)
                    .frame(idealWidth: 400, idealHeight: 860)
                    // the popover follows the system appearance, not the
                    // buttons' forced-light one
                    .environment(\.colorScheme, systemScheme)
                    // the system's popover glass, content straight on it in
                    // explicit label colours (DESIGN.md §2: no plate)
                    .presentationCompactAdaptation(.popover)
            }

            Divider()
                .frame(width: Self.buttonSize - 20)

            MapControlButton(symbol: model.trackingMode.symbol, label: "Location", active: model.trackingMode != .off) {
                model.cycleTracking()
            }
            .accessibilityValue(model.trackingMode.spokenState)
            .accessibilityIdentifier("location-button")
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .mapChrome()
    }

    /// The card layout's Layers popover; the sheet layout's Layers sheet is
    /// hosted by the panel sheet (ModalHost).
    private var layersPopoverBinding: Binding<Bool> {
        Binding(
            get: { layersAsPopover && model.isPresenting(.layers, in: .card) },
            set: { shown in
                if !shown, model.isPresenting(.layers, in: .card) { model.dismissModal() }
            }
        )
    }
}

/// One square glass-capsule button with a symbol.
struct MapControlButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: MapControls.buttonSize, height: MapControls.buttonSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(DesignColor.ink))
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(label))
    }
}

extension View {
    /// Chrome floating over the map runs in light appearance always: the
    /// map never goes dark, and dark glass over light paper turned the
    /// controls, readout and scale into khaki smudges. Sheets, cards and
    /// popovers keep following the system (scoped environment, supported
    /// API: `\.colorScheme` for this subtree only).
    func mapChrome() -> some View {
        environment(\.colorScheme, .light)
    }
}
