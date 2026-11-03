import SwiftUI

/// Presents the window's modal (`AppModel.modal`) from one container. The
/// sheet layout attaches it to the panel sheet (UIKit presents from the
/// topmost controller, and the panel sheet already is one); the card layout
/// attaches it to the root. Each host shows only requests made in its own
/// layout, so on a layout switch nothing is adopted half-way.
struct ModalHost: ViewModifier {
    @Bindable var model: AppModel
    let layout: PanelLayout

    func body(content: Content) -> some View {
        content.sheet(item: item) { request in
            ModalContent(model: model, presentation: request.presentation)
        }
    }

    /// In the card layout Layers is a popover from its button, not a sheet.
    private var item: Binding<ModalRequest?> {
        Binding(
            get: {
                guard let modal = model.modal, modal.layout == layout else { return nil }
                if layout == .card, modal.presentation == .layers { return nil }
                return modal
            },
            set: { new in
                if new == nil, model.modal?.layout == layout { model.dismissModal() }
            }
        )
    }
}

/// The modal screens themselves.
struct ModalContent: View {
    let model: AppModel
    let presentation: Presentation

    var body: some View {
        switch presentation {
        case .layers:
            LayersSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationBackground { PanelPlate(grouped: true) }
                // no dimming scrim at medium: she judges the overlay's colours
                // and strength on the live map above the sheet (and can pan it)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .plantID:
            PlantIDPlaceholder()
                .presentationDetents([.medium])
                .presentationBackground { PanelPlate() }
        case .attribution:
            AttributionSheet(map: model.map)
                .presentationDetents([.medium, .large])
                .presentationBackground { PanelPlate(grouped: true) }
        }
    }
}
