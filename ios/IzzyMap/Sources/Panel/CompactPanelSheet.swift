import SwiftUI

/// Compact width: the panel as one persistent, non-dismissible bottom sheet
/// (Maps pattern). The smallest detent fits the header (and a card when one
/// is shown); the map stays interactive behind it up to medium.
struct CompactPanelSheet: View {
    @Bindable var model: AppModel
    /// The sheet's top edge in global coordinates, for the map chrome.
    var onTopEdgeChange: (CGFloat) -> Void
    /// Whether the sheet rests at its smallest (fitted) detent.
    var onRestingChange: (Bool) -> Void

    @State private var fitHeight: CGFloat = 96
    @State private var detent: PresentationDetent = .height(96)

    private var fitDetent: PresentationDetent { .height(fitHeight) }

    var body: some View {
        ScrollView {
            PanelContent(model: model) { detent = .large }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    updateFit(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([fitDetent, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onTopEdgeChange($0) }
        .onChange(of: detent, initial: true) { _, new in onRestingChange(new == fitDetent) }
        // modals over the panel sheet (the topmost presented controller)
        .modifier(ModalHost(model: model, layout: .sheet))
    }

    /// The fitted detent follows the content; a sheet resting on it grows
    /// or shrinks along (a card appears, Dynamic Type changes).
    private func updateFit(_ height: CGFloat) {
        guard abs(height - fitHeight) > 0.5 else { return }
        let wasResting = detent == fitDetent
        fitHeight = height
        if wasResting { detent = fitDetent }
    }
}
