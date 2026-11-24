import SwiftUI

/// Compact width: the panel as one persistent, non-dismissible bottom sheet
/// (Maps pattern). The smallest detent fits the header (and a card when one
/// is shown); the map stays interactive behind it up to medium.
struct CompactPanelSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: AppModel
    /// The sheet's frame in global coordinates (the system places the
    /// floating sheet; the map's bottom ornaments line up with its edges).
    var onFrameChange: (CGRect) -> Void
    /// Whether the sheet rests at its smallest (fitted) detent.
    var onRestingChange: (Bool) -> Void

    static let inset: CGFloat = 16

    @State private var fitHeight: CGFloat = 80
    @State private var detent: PresentationDetent = .height(80)
    /// Where the sheet was before a pin field took the keyboard.
    @State private var detentBeforeEditing: PresentationDetent?

    @State private var contentHeight: CGFloat = 0
    /// The pinned search header's height, padding included.
    @State private var headerHeight: CGFloat = 80
    /// Bottom of the card's glance in the content (0: no card).
    @State private var peek: CGFloat = 0
    /// The sheet's bottom safe area (see the scroll view's comment).
    @State private var bottomInset: CGFloat = 0
    /// How far the sheet is raised above its glance, for the fade below a
    /// card's glance (`belowGlance()`).
    @State private var fade = GlanceFadeLevel()

    private var fitDetent: PresentationDetent { .height(fitHeight) }

    var body: some View {
        PanelStack(model: model) {
            ScrollViewReader { proxy in
                scroller
                    .environment(\.panelActions, PanelActions(
                        raise: { if detent == fitDetent { detent = .medium } },
                        scrollTo: { id in
                            withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(id, anchor: .top) }
                        },
                        peek: { y in
                            let rounded = y.rounded(.up)
                            guard abs(rounded - peek) > 0.5 else { return }
                            peek = rounded
                            updateFit(contentHeight)
                        }))
            }
        }
        // search: results at the large detent (⌘F too); a pick or Cancel
        // drops the sheet to its glance, the place's chip in the field
        .onChange(of: model.search.isActive) { _, active in
            detent = active ? .large : fitDetent
        }
        // dragged down to the glance mid-search: the results can't show there
        .onChange(of: detent) { _, new in
            if new == fitDetent, model.search.isActive { model.search.end() }
        }
        // a pushed plant sheet or group list reads at the large detent
        .onChange(of: model.cardPath.count) { old, new in
            if new > old { detent = .large }
        }
        // "Show on map" / a key row: the card closed to show the map
        .onChange(of: model.keyHighlight) { _, code in
            if code != nil, model.selection == nil { detent = fitDetent }
        }
        // the card went (closed, deleted, deleted on the other device): the
        // sheet goes back to its glance with it — a raised sheet with
        // nothing in it reads as a crash, and it would hide the map (and
        // the Undo pill above the sheet)
        .onChange(of: model.selection?.id) { _, id in
            guard id == nil else { return }
            peek = 0
            updateFit(contentHeight)
            // (every way a card goes ends here: ✕, Delete, Escape, a map
            // tap, a pick, the pin deleted on the other device — with or
            // without a field's keyboard still up: the fitted height never
            // depends on the keyboard)
            detentBeforeEditing = nil
            guard !model.search.isActive else { return }
            detent = fitDetent
        }
        // a pin card's title or note has the keyboard: room to type; after,
        // the sheet goes back — undoing only our own change: not when
        // search took over (its results live at large, and the fit detent
        // would end it), she moved the sheet herself, or a pin is moving
        .onChange(of: model.pinEditing != nil) { _, editing in
            if editing {
                if detentBeforeEditing == nil { detentBeforeEditing = detent }
                detent = .large
            } else if let before = detentBeforeEditing {
                detentBeforeEditing = nil
                guard !model.search.isActive, model.movingPin == nil, detent == .large else { return }
                detent = before == .medium || before == .large ? before : fitDetent
            }
        }
        // moving a pin: the map is where she taps, the sheet at its glance
        // until the move ends (a field losing focus restores nothing)
        .onChange(of: model.movingPin) { _, id in
            if id != nil {
                detentBeforeEditing = nil
                detent = fitDetent
            }
        }
        // a pin moved ("Move to my location" from the raised card): the
        // sheet drops to its glance, so the pin and the "Pin moved · Undo"
        // pill above the sheet are in sight (the large sheet covers both)
        .onChange(of: model.pinUndo?.serial) {
            guard model.pinUndo?.movedFrom != nil, detent == .large else { return }
            detentBeforeEditing = nil
            detent = fitDetent
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
                .environment(\.glanceFade, GlanceFade(level: fade, active: hidesBelowGlance))
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                    contentHeight = height
                    updateFit(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // scrolling the results puts the keyboard away (they stay)
        .scrollDismissesKeyboard(.immediately)
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
        // the system adds below it once the sheet is tall enough to reach
        // the home indicator (34 pt on the 16e; a glance of only the search
        // row floats clear of it: 0). The content runs through that band;
        // scrolled content at medium and large keeps clear of it. The fitted
        // detent never reads it (see `fitHeight`).
        //
        // Measured with the keyboard left out (a child of a container that
        // ignores the keyboard's region): the scroll view's own inset
        // includes the keyboard's overlap with the sheet, which depends on
        // the sheet's height, and the sheet's keyboard handling would lay
        // the sheet out again on every change. The scroll view keeps its own
        // keyboard avoidance.
        .contentMargins(.bottom, detent == fitDetent ? 0 : bottomInset, for: .scrollContent)
        .ignoresSafeArea(.container, edges: .bottom)
        .background {
            ZStack {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom.rounded() } action: { inset in
                        guard abs(inset - bottomInset) > 0.5 else { return }
                        bottomInset = inset
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { height in
                        fade.update(height: height)
                    }
            }
            .ignoresSafeArea(.keyboard)
        }
    }

    /// Whether a card's content below its glance fades with the sheet's
    /// height (`belowGlance()`): only a card has anything below its glance.
    private var hidesBelowGlance: Bool {
        model.selection != nil && !model.search.isActive && peek > 0
    }

    /// The fitted detent's height: the search header plus the glance below
    /// it (a card's glance — header, plant faces — or the notice rows), and
    /// nothing else, so it changes only with the content. Never the sheet's
    /// bottom safe area: the system adds that below a detent itself, and
    /// sets it from the sheet's own height (iPhone 16e: 0 while a short
    /// sheet floats, 34 once a taller one reaches the home indicator, the
    /// switch between 99 and 105 pt). Subtracting it fed the sheet's shape
    /// back into its detent: with the "No offline maps" row (133 pt) it
    /// cycled 133 → 115 → 99 → 133, the system dropped the last change,
    /// and the glance rested at a different height after a card than at
    /// launch — the map's resting inset followed and moved every pin.
    nonisolated static func fitHeight(header: CGFloat, content: CGFloat, peek: CGFloat) -> CGFloat {
        // with a card: its glance, not all of it
        let body = peek > 0 ? min(content, peek + 12) : content
        return max(44, header + body)
    }

    /// The fitted detent follows the content; a sheet resting on it grows
    /// or shrinks along (a card appears, Dynamic Type changes).
    private func updateFit(_ content: CGFloat) {
        let height = Self.fitHeight(header: headerHeight, content: content, peek: model.selection != nil ? peek : 0)
        fade.update(fit: height)
        guard abs(height - fitHeight) > 0.5 else { return }
        let wasResting = detent == fitDetent
        fitHeight = height
        if wasResting { detent = fitDetent }
    }
}

/// How far the phone's sheet stands above its fitted height, in 2-pt
/// steps from 0 (resting at its glance) to 22 (44 pt or more higher). Fed
/// the sheet's height as its detents count it (home-indicator band and
/// keyboard left out; equal to the fitted height at rest) on every layout
/// pass, it publishes only a change of step: only the fade reads it, and
/// sub-step jitter (a keyboard's layout passes, a large sheet) never
/// re-renders anything — publishing every height kept the app from ever
/// going idle in some UI test runs.
@Observable final class GlanceFadeLevel {
    static let steps = 22
    private(set) var step = GlanceFadeLevel.steps
    @ObservationIgnored private var height: CGFloat = 0
    @ObservationIgnored private var fit: CGFloat = 0

    func update(height: CGFloat? = nil, fit: CGFloat? = nil) {
        if let height { self.height = height }
        if let fit { self.fit = fit }
        let raised = Int(((self.height - self.fit) / 2).rounded(.down))
        let next = self.height > 0 ? min(Self.steps, max(0, raised)) : Self.steps
        if next != step { step = next }
    }
}

/// What a card's content below its glance needs to fade (the compact
/// sheet sets it; elsewhere inactive: always fully there).
struct GlanceFade {
    var level: GlanceFadeLevel?
    var active = false

    /// 0 while the sheet rests at its fitted height, 1 from 44 pt higher.
    var opacity: Double {
        guard active, let level else { return 1 }
        return Double(level.step) / Double(GlanceFadeLevel.steps)
    }
}

extension EnvironmentValues {
    @Entry var glanceFade = GlanceFade()
}

extension View {
    /// A card's content below its glance: hidden while the phone's sheet
    /// rests at its glance — the home-indicator band under it stays empty,
    /// never a sliver of the next row cut by the sheet's corner — and
    /// fading in over the first 44 pt the sheet is raised, so it follows a
    /// drag. Opacity only (no layout change, so nothing feeds back into the
    /// fitted height); no taps while invisible. On the sections themselves,
    /// not a mask over the panel content: with a mask, text typed into a
    /// modal presented from the card (the Pins screen, the photo viewer's
    /// caption) got lost.
    func belowGlance() -> some View { modifier(BelowGlance()) }
}

private struct BelowGlance: ViewModifier {
    @Environment(\.glanceFade) private var fade

    func body(content: Content) -> some View {
        let opacity = fade.opacity
        content
            .opacity(opacity)
            .allowsHitTesting(opacity > 0)
    }
}
