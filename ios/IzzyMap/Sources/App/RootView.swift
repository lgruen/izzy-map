import os
import SwiftUI
import UIKit

/// Full-bleed map with floating chrome. Layout follows the size classes,
/// never the device (Maps pattern): compact width with regular height (a
/// phone held upright, a narrow iPad window) = bottom sheet; anything wider
/// or shorter (iPad, a phone on its side) = floating card on the leading side.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var screen = ScreenMetrics()
    /// The compact sheet's frame in global coordinates, as measured inside
    /// it (the system places the floating sheet; nil until it reports).
    @State private var sheetFrame: CGRect?
    @State private var sheetResting = true
    /// Sheet height at its smallest detent with no card: the map's bottom inset.
    @State private var restingLift: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0
    @State private var pillHeight: CGFloat = 0
    /// Where each floating piece of chrome sits over the map (global), for
    /// framing extents clear of them (`MapFraming`).
    @State private var chromeFrames: [ChromePiece: CGRect] = [:]

    /// Bottom sheet vs floating card.
    private var usesSheet: Bool { widthClass != .regular && heightClass != .compact }
    private var layout: PanelLayout { usesSheet ? .sheet : .card }
    private static let margin: CGFloat = 16
    /// The floating card's width (card layout): 300–380 pt for a
    /// community card; on a regular-size iPad window a pushed plant sheet
    /// or group list reads as a larger card, 380–500 pt — its photo plate
    /// and elevation drawing are made for more than a key's width.
    private var cardWidth: CGFloat {
        let roomy = widthClass == .regular && heightClass == .regular && !model.cardPath.isEmpty
        return roomy ? min(500, max(380, screen.size.width * 0.4)) : min(380, max(300, screen.size.width * 0.42))
    }

    /// The iPad Layers popover: 400–500 pt, 40 % of the window — the roomy
    /// card's rule (DESIGN.md §3), never narrower than its old 400.
    private var layersPopoverWidth: CGFloat { min(500, max(400, screen.size.width * 0.4)) }

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.body("RootView")
        #endif
        ZStack {
            MapLayer(
                model: model,
                chrome: chrome,
                trackingMode: model.trackingMode,
                hasSelection: model.selection != nil,
                layers: model.layers,
                keyHighlight: model.keyHighlight,
                spotlight: model.spotlight
            )

            // framing a detailed area: the frame over the uncovered map (with
            // the setup card open beside it: the framed box, wherever the map
            // puts it)
            if showsSetupCard {
                AreaDraftLayer(map: model.map)
                    .ignoresSafeArea()
            } else if model.isFraming, let rect = areaFrame {
                AreaFrameLayer(map: model.map, rect: rect)
                    .ignoresSafeArea()
            }

            if showsSetupCard {
                // the setup as the side card (DESIGN.md ≥ 700 pt): the frame
                // stays in sight beside it
                AreaSetupSheet(model: model)
                    .frame(width: max(cardWidth, 360))
                    .frame(maxHeight: max(320, screen.size.height - pillHeight - 4 * Self.margin))
                    // opaque: a dense form over a busy map (glass let the
                    // map read through the words in dark mode)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                    // its own piece: the panel it replaces clears `.card` as it goes
                    .reportFrame(.setupCard, into: $chromeFrames)
                    .padding([.leading, .top], Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            } else if !usesSheet {
                FloatingPanel(model: model, maxHeight: max(120, screen.size.height - pillHeight - 4 * Self.margin))
                    .frame(width: cardWidth)
                    .animation(.snappy, value: cardWidth)
                    .reportFrame(.card, into: $chromeFrames)
                    .padding([.leading, .top], Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            MapControls(model: model, layersAsPopover: !usesSheet, popoverWidth: layersPopoverWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .reportFrame(.controls, into: $chromeFrames)
                .padding([.trailing, .top], Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Bottom ornaments on the panel's grid: on a phone the cluster's
            // leading edge and the (i)'s trailing edge sit on the sheet's
            // edges, the same gap above its top; beside the card they share
            // the card's and the controls' margins.
            GridPill(map: model.map)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                .reportFrame(.gridPill, into: $chromeFrames)
                .padding(.leading, ornamentInsets.leading)
                .padding(.bottom, bottomOrnamentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            AttributionButton { model.present(.attribution) }
                .reportFrame(.attribution, into: $chromeFrames)
                .padding(.trailing, ornamentInsets.trailing)
                .padding(.bottom, bottomOrnamentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // "Show on map": what is soloed, previous / next, ×
            if let spotlight = model.spotlight {
                SpotlightPill(model: model, spotlight: spotlight)
                    .reportFrame(.spotlightPill, into: $chromeFrames)
                    .padding(.leading, usesSheet ? Self.margin : 2 * Self.margin + cardWidth)
                    .padding(.trailing, MapControls.buttonSize + 2 * Self.margin)
                    .padding(.top, Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: usesSheet ? .topLeading : .top)
                    .transition(.opacity)
            }

            if model.isFraming, !showsSetupCard {
                AreaFramingBar(model: model, map: model.map)
                    .frame(maxWidth: 520)
                    .reportFrame(.framingBar, into: $chromeFrames)
                    .padding(.leading, usesSheet ? Self.margin : 2 * Self.margin + cardWidth)
                    .padding(.trailing, MapControls.buttonSize + 2 * Self.margin)
                    .padding(.top, Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: usesSheet ? .topLeading : .top)
                    .transition(.opacity)
            }

            // the top status slot: the one-time welcome, "Maps arriving",
            // a location message — phone sheet: leading, clear of the
            // controls; card layout: centred in the map area between the
            // card and the controls
            MapStatusStack(model: model, reduceMotion: reduceMotion,
                           showsModeBar: model.spotlight != nil || model.isFraming, frames: $chromeFrames)
                .frame(maxWidth: 440)
                .padding(.leading, usesSheet ? Self.margin : 2 * Self.margin + cardWidth)
                .padding(.trailing, MapControls.buttonSize + 2 * Self.margin)
                .padding(.top, Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: usesSheet ? .topLeading : .top)
        }
        .animation(.snappy, value: model.isFraming)
        .animation(.snappy, value: showsSetupCard)
        .animation(.snappy, value: model.spotlight?.code)
        // card layout: modals hang off the root (the sheet layout's are on the panel sheet)
        .modifier(ModalHost(model: model, layout: .card))
        .modifier(ReaderHost(model: model, layout: .card))
        .onChange(of: layout, initial: true) { _, new in model.layoutChanged(to: new) }
        // reference photos stand in for guide plants without one of their
        // own (plant sheets, Plants lists), not only inside Identify
        .onChange(of: model.shared.packs.state(.refphotos), initial: true) { PlantIDRefPhotos.shared.use(packs: model.shared.packs) }
        .onGeometryChange(for: ScreenMetrics.self) { proxy in
            ScreenMetrics(
                size: proxy.size,
                frame: proxy.frame(in: .global),
                safe: proxy.safeAreaInsets,
                bottom: proxy.frame(in: .global).maxY + proxy.safeAreaInsets.bottom
            )
        } action: { screen = $0 }
        .sheet(isPresented: .constant(usesSheet)) {
            CompactPanelSheet(model: model) { frame in
                // whole points: sub-point jitter during a detent change
                // would re-render the root for nothing
                let rounded = CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                                     width: frame.width.rounded(), height: frame.height.rounded())
                if rounded != sheetFrame { sheetFrame = rounded }
            } onRestingChange: { sheetResting = $0 }
            // the reader over the panel sheet (the topmost presented controller)
            .modifier(ReaderHost(model: model, layout: .sheet))
            .environment(model.documents)
        }
        // Remember the header-only sheet height once the sheet settles there.
        .task(id: RestingProbe(lift: sheetLift, resting: sheetResting, empty: model.selection == nil)) {
            guard usesSheet, sheetResting, model.selection == nil, sheetLift > 0 else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { restingLift = sheetLift }
        }
    }

    /// Gap between the bottom ornaments and the sheet's top edge (or the
    /// safe area's bottom beside the card).
    private static let ornamentGap: CGFloat = 8

    /// Bottom padding of the pill and the (i) control.
    private var bottomOrnamentInset: CGFloat { bottomBase - screen.safe.bottom + ornamentLift + Self.ornamentGap }

    /// Leading padding of the pill, trailing padding of the (i), from the
    /// safe area. Sheet: the measured sheet's edges (the floating sheet is
    /// inset by the system, more on some phones than others); before the
    /// first measurement, and beside the card: the chrome margin.
    private var ornamentInsets: (leading: CGFloat, trailing: CGFloat) {
        guard usesSheet, let sheetFrame, sheetFrame.width > 0, screen.frame.width > 0 else {
            return (Self.margin, Self.margin)
        }
        return (max(0, sheetFrame.minX - screen.frame.minX),
                max(0, screen.frame.maxX - sheetFrame.maxX))
    }

    /// Distance of the compact sheet's top edge above the screen bottom.
    private var sheetLift: CGFloat {
        guard usesSheet, let sheetFrame else { return 0 }
        return max(0, screen.bottom - sheetFrame.minY)
    }

    /// Bottom edge of the uncovered map, from the screen bottom.
    private var bottomBase: CGFloat {
        usesSheet ? max(restingLift, screen.safe.bottom) : screen.safe.bottom + 8
    }

    /// How far the bottom ornaments ride up with a raised sheet: they stay
    /// on its top edge through the medium detent (taller than half the
    /// screen on iOS 26) and stop below the top-trailing controls, where the
    /// large sheet covers them.
    private var ornamentLift: CGFloat {
        guard usesSheet else { return 0 }
        let highest = screen.safe.top + Self.margin + controlsHeight + Self.margin
            + max(pillHeight, 44) + Self.ornamentGap
        let cap = max(0, screen.size.height + screen.safe.top + screen.safe.bottom - highest - bottomBase)
        return min(max(0, sheetLift - bottomBase), cap)
    }

    private var chrome: MapChrome {
        MapChrome(
            contentInset: UIEdgeInsets(top: screen.safe.top, left: screen.safe.leading,
                                       bottom: bottomBase, right: screen.safe.trailing),
            ornamentLift: ornamentLift,
            pillHeight: pillHeight,
            compassTop: Self.margin + controlsHeight + 12,
            controlsCentreFromTrailing: Self.margin + MapControls.buttonSize / 2,
            framingInsets: framingInsets,
            areaFrame: model.isFraming && !showsSetupCard ? areaFrame : nil,
            areaDraft: showsSetupCard ? model.areaDraft : nil
        )
    }

    /// Wide layouts show an area's setup as the side card, not a sheet.
    private var showsSetupCard: Bool {
        !usesSheet && model.isFraming && model.modal?.presentation == .areaSetup && model.areaDraft != nil
    }

    /// The window in the map view's coordinates (the map is full-window).
    private var windowSize: CGSize {
        CGSize(width: screen.size.width + screen.safe.leading + screen.safe.trailing,
               height: screen.size.height + screen.safe.top + screen.safe.bottom)
    }

    /// Framing an area: the uncovered map (clear of every piece of chrome,
    /// the framing bar included), inset 8 % × 10 %.
    private var areaFrame: CGRect? {
        let size = windowSize
        guard size.width > 0, size.height > 0 else { return nil }
        return AreaFramingMetrics.frame(in: CGRect(origin: .zero, size: size).inset(by: framingInsets))
    }

    /// The map area no chrome covers, from the measured frames: the map is
    /// full-window, so its bounds are the safe-area frame grown by the
    /// safe insets.
    private var framingInsets: UIEdgeInsets {
        let safe = UIEdgeInsets(top: screen.safe.top, left: screen.safe.leading,
                                bottom: screen.safe.bottom, right: screen.safe.trailing)
        let window = screen.frame.inset(by: UIEdgeInsets(top: -safe.top, left: -safe.left,
                                                         bottom: -safe.bottom, right: -safe.right))
        guard window.width > 0, window.height > 0 else { return safe }
        var pieces = Array(chromeFrames.values)
        if usesSheet, let sheetFrame, sheetFrame.height > 0 {
            // the floating sheet and everything below its top edge
            pieces.append(CGRect(x: sheetFrame.minX, y: sheetFrame.minY,
                                 width: sheetFrame.width, height: max(0, window.maxY - sheetFrame.minY)))
        }
        let local = pieces.map { $0.offsetBy(dx: -window.minX, dy: -window.minY) }
        return MapFraming.insets(bounds: CGRect(origin: .zero, size: window.size), safe: safe, obstructions: local)
    }
}

/// Floating chrome whose frame the framing keeps clear of.
nonisolated enum ChromePiece: Hashable, Sendable {
    case card, controls, gridPill, attribution, spotlightPill, notice, framingBar, setupCard
}

extension View {
    /// Reports this view's global frame (whole points) under `piece`, and
    /// removes it when the view goes — or while `when` is false (a slot
    /// that stays in the hierarchy with nothing in it).
    func reportFrame(_ piece: ChromePiece, into frames: Binding<[ChromePiece: CGRect]>, when shown: Bool = true) -> some View {
        onGeometryChange(for: CGRect?.self) { proxy in
            guard shown else { return nil }
            let f = proxy.frame(in: .global)
            return CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
        } action: { frame in
            if frames.wrappedValue[piece] != frame { frames.wrappedValue[piece] = frame }
        }
        .onDisappear { frames.wrappedValue[piece] = nil }
    }
}

nonisolated struct ScreenMetrics: Equatable, Sendable {
    var size: CGSize = .zero
    /// The safe-area frame in global coordinates.
    var frame: CGRect = .zero
    var safe = EdgeInsets()
    /// Global y of the screen's bottom edge.
    var bottom: CGFloat = 0
}

private nonisolated struct RestingProbe: Equatable, Sendable {
    var lift: CGFloat
    var resting: Bool
    var empty: Bool
}

/// The map view plus its accessibility state. Its own view, so the 60 Hz /
/// per-idle map state it reads re-renders only this, not RootView.
private struct MapLayer: View {
    let model: AppModel
    var chrome: MapChrome
    var trackingMode: TrackingMode
    var hasSelection: Bool
    var layers: LayerState
    var keyHighlight: String?
    var spotlight: Spotlight?

    var body: some View {
        MapView(model: model, chrome: chrome, trackingMode: trackingMode, hasSelection: hasSelection,
                layers: layers, keyHighlight: keyHighlight, spotlight: spotlight, searchPin: model.search.pin,
                areaFocus: model.areaFocus)
            .ignoresSafeArea()
            .accessibilityLabel("Map")
            // UI tests wait for "idle" (camera settled, tiles loaded) before tapping
            .accessibilityValue(model.map.isIdle ? "idle" : "loading")
            .accessibilityIdentifier("map")
    }
}

#if DEBUG
/// DEBUG instrument: with the launch argument `-traceBodies YES`, logs each
/// body evaluation of the views that call it (category "Render"), to check
/// that panning re-renders the grid pill and not the root:
///   xcrun simctl spawn <udid> log show --last 2m --predicate 'category == "Render"'
enum RenderTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "traceBodies")
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Render")

    static func body(_ name: StaticString) {
        guard enabled else { return }
        logger.notice("body \(name, privacy: .public)")
    }
}
#endif
