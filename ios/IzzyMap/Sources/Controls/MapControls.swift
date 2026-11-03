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

    var body: some View {
        VStack(spacing: 0) {
            MapControlButton(symbol: "square.3.layers.3d", label: "Layers") {
                model.present(.layers)
            }
            .accessibilityIdentifier("layers-button")
            .popover(isPresented: layersPopoverBinding) {
                LayersSheet(model: model)
                    .frame(idealWidth: 360, idealHeight: 420)
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
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(label))
    }
}
