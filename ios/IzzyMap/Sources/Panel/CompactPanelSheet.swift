import SwiftUI

/// Compact width: the panel as one persistent, non-dismissible bottom sheet
/// (Maps pattern). The smallest detent fits the header (and a card when one
/// is shown); the map stays interactive behind it up to medium.
struct CompactPanelSheet: View {
    @Bindable var model: AppModel
    /// The sheet's frame in global coordinates (the system places the
    /// floating sheet; the map's bottom ornaments line up with its edges).
    var onFrameChange: (CGRect) -> Void
    /// Whether the sheet rests at its smallest (fitted) detent.
    var onRestingChange: (Bool) -> Void

    static let inset: CGFloat = 16

    @State private var fitHeight: CGFloat = 80
    @State private var detent: PresentationDetent = .height(80)

    @State private var contentHeight: CGFloat = 80
    /// The sheet's bottom safe area (see the scroll view's comment).
    @State private var bottomInset: CGFloat = 0

    private var fitDetent: PresentationDetent { .height(fitHeight) }

    var body: some View {
        ScrollView {
            PanelContent(model: model) { detent = .large }
                // 16 on every side: at the fitted detent the search row sits
                // centred in the sheet (the grabber lives in the top 16), and
                // the capsules stay concentric with the sheet's corners
                .padding(Self.inset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    contentHeight = height
                    updateFit(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // a detent's height leaves out the sheet's bottom safe area, which
        // the system adds below it once the sheet sits low enough to reach
        // the home indicator (AX text sizes; at default sizes the small
        // sheet floats clear of it and the inset is 0). The content runs
        // through that band, and the fitted detent subtracts it, so the
        // search row stays centred; scrolled content keeps clear of it.
        .contentMargins(.bottom, detent == fitDetent ? 0 : bottomInset, for: .scrollContent)
        .ignoresSafeArea(.container, edges: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
            guard abs(inset - bottomInset) > 0.5 else { return }
            bottomInset = inset
            updateFit(contentHeight)
        }
        .presentationDetents([fitDetent, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        // the system's own sheet glass, content straight on it (no
        // presentationBackground); DEBUG `-sheetStyle plate` swaps in the
        // near-opaque plate
        .modifier(SheetSurface(surface: PanelSurface.current))
        .interactiveDismissDisabled()
        // the sheet's own bounds (the background ignores the sheet's safe
        // area), not the scroll view's
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrameChange($0) }
        }
        .onChange(of: detent, initial: true) { _, new in onRestingChange(new == fitDetent) }
        #if DEBUG
        // screenshots: `-sheetDetent medium|large` opens the sheet there
        .task {
            switch UserDefaults.standard.string(forKey: "sheetDetent") {
            case "medium": detent = .medium
            case "large": detent = .large
            default: break
            }
        }
        #endif
        // modals over the panel sheet (the topmost presented controller)
        .modifier(ModalHost(model: model, layout: .sheet))
    }

    /// The fitted detent follows the content; a sheet resting on it grows
    /// or shrinks along (a card appears, Dynamic Type changes).
    private func updateFit(_ content: CGFloat) {
        let height = max(44, content - bottomInset)
        guard abs(height - fitHeight) > 0.5 else { return }
        let wasResting = detent == fitDetent
        fitHeight = height
        if wasResting { detent = fitDetent }
    }
}
