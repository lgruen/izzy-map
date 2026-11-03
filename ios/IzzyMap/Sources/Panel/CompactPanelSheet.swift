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

    @State private var contentHeight: CGFloat = 0
    /// The pinned search header's height, padding included.
    @State private var headerHeight: CGFloat = 80
    /// Bottom of the card's glance in the content (0: no card).
    @State private var peek: CGFloat = 0
    /// The sheet's bottom safe area (see the scroll view's comment).
    @State private var bottomInset: CGFloat = 0

    private var fitDetent: PresentationDetent { .height(fitHeight) }

    var body: some View {
        PanelStack(model: model) {
            ScrollViewReader { proxy in
                scroller
                    .environment(\.panelActions, PanelActions(
                        raise: { if detent == fitDetent { detent = .medium } },
                        scrollTo: { id in
                            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
                        },
                        peek: { y in
                            let rounded = y.rounded(.up)
                            guard abs(rounded - peek) > 0.5 else { return }
                            peek = rounded
                            updateFit(contentHeight)
                        }))
            }
        }
        // a pushed plant sheet or group list reads at the large detent
        .onChange(of: model.cardPath.count) { old, new in
            if new > old { detent = .large }
        }
        // "Show on map" / a key row: the card closed to show the map
        .onChange(of: model.keyHighlight) { _, code in
            if code != nil, model.selection == nil { detent = fitDetent }
        }
        .onChange(of: model.selection?.id) { _, id in
            if id == nil { peek = 0; updateFit(contentHeight) }
        }
        // "Show on map" from the card: the sheet drops to its glance so
        // the map shows the community statewide
        .onChange(of: model.spotlight?.code) { _, code in
            if code != nil { detent = fitDetent }
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

    private var scroller: some View {
        let hasBody = PanelContent.hasBody(model)
        return ScrollView {
            PanelContent(model: model)
                // 16 at the sides and bottom (the capsules stay concentric
                // with the sheet's corners); the header above keeps its 16
                .padding(.horizontal, Self.inset)
                .padding(.bottom, hasBody ? Self.inset : 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    contentHeight = height
                    updateFit(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // the search header stays put; the card scrolls under it behind the
        // system's soft edge (never bare under the grabber)
        .safeAreaBar(edge: .top) {
            PanelHeader(model: model) { detent = .large }
                // at the fitted detent the search row sits centred in the
                // sheet (the grabber lives in the top 16)
                .padding(.horizontal, Self.inset)
                .padding(.top, Self.inset)
                .padding(.bottom, hasBody ? 14 : Self.inset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    guard abs(height - headerHeight) > 0.5 else { return }
                    headerHeight = height
                    updateFit(contentHeight)
                }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
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
    }

    /// The fitted detent follows the content; a sheet resting on it grows
    /// or shrinks along (a card appears, Dynamic Type changes).
    private func updateFit(_ content: CGFloat) {
        // with a card: its glance (header, plant faces), not all of it
        let body = model.selection != nil && peek > 0 ? min(content, peek + 12) : content
        let height = max(44, headerHeight + body - bottomInset)
        guard abs(height - fitHeight) > 0.5 else { return }
        let wasResting = detent == fitDetent
        fitHeight = height
        if wasResting { detent = fitDetent }
    }
}
