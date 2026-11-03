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

    @State private var screen = ScreenMetrics()
    /// Global y of the compact sheet's top edge.
    @State private var sheetTop: CGFloat?
    @State private var sheetResting = true
    /// Sheet height at its smallest detent with no card: the map's bottom inset.
    @State private var restingLift: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0
    @State private var pillHeight: CGFloat = 0

    /// Bottom sheet vs floating card.
    private var usesSheet: Bool { widthClass != .regular && heightClass != .compact }
    private var layout: PanelLayout { usesSheet ? .sheet : .card }
    private static let margin: CGFloat = 16
    /// The floating card's width (card layout).
    private var cardWidth: CGFloat { min(380, max(300, screen.size.width * 0.42)) }

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.body("RootView")
        #endif
        ZStack {
            MapLayer(
                model: model,
                chrome: chrome,
                trackingMode: model.trackingMode,
                hasSelection: model.selection != nil
            )

            if !usesSheet {
                FloatingPanel(model: model, maxHeight: max(120, screen.size.height - pillHeight - 4 * Self.margin))
                    .frame(width: cardWidth)
                    .padding([.leading, .top], Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            MapControls(model: model, layersAsPopover: !usesSheet)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .padding([.trailing, .top], Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            GridPill(map: model.map)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                .padding(.leading, Self.margin)
                .padding(.bottom, bottomOrnamentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            AttributionButton { model.present(.attribution) }
                // its 44 pt hit area overhangs the 32 pt glyph: keep the glyph
                // on the pill's margins
                .padding(.trailing, Self.margin - 6)
                .padding(.bottom, bottomOrnamentInset - 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.dismissNotice() }
                    .frame(maxWidth: 440)
                    // phone sheet: leading, clear of the controls; card layout:
                    // centred in the map area between the card and the controls
                    .padding(.leading, usesSheet ? Self.margin : 2 * Self.margin + cardWidth)
                    .padding(.trailing, MapControls.buttonSize + 2 * Self.margin)
                    .padding(.top, Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: usesSheet ? .topLeading : .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.notice)
        // card layout: modals hang off the root (the sheet layout's are on the panel sheet)
        .modifier(ModalHost(model: model, layout: .card))
        .onChange(of: layout, initial: true) { _, new in model.layoutChanged(to: new) }
        .onGeometryChange(for: ScreenMetrics.self) { proxy in
            ScreenMetrics(
                size: proxy.size,
                safe: proxy.safeAreaInsets,
                bottom: proxy.frame(in: .global).maxY + proxy.safeAreaInsets.bottom
            )
        } action: { screen = $0 }
        .sheet(isPresented: .constant(usesSheet)) {
            CompactPanelSheet(model: model) { sheetTop = $0 } onRestingChange: { sheetResting = $0 }
        }
        // Remember the header-only sheet height once the sheet settles there.
        .task(id: RestingProbe(lift: sheetLift, resting: sheetResting, empty: model.selection == nil)) {
            guard usesSheet, sheetResting, model.selection == nil, sheetLift > 0 else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { restingLift = sheetLift }
        }
    }

    /// Bottom padding of the pill and the (i) control.
    private var bottomOrnamentInset: CGFloat { bottomBase - screen.safe.bottom + ornamentLift + 8 }

    /// Distance of the compact sheet's top edge above the screen bottom.
    private var sheetLift: CGFloat {
        guard usesSheet, let sheetTop else { return 0 }
        return max(0, screen.bottom - sheetTop)
    }

    /// Bottom edge of the uncovered map, from the screen bottom.
    private var bottomBase: CGFloat {
        usesSheet ? max(restingLift, screen.safe.bottom) : screen.safe.bottom + 8
    }

    /// How far the bottom ornaments ride up with a raised sheet (up to medium).
    private var ornamentLift: CGFloat {
        guard usesSheet else { return 0 }
        let cap = max(0, (screen.size.height + screen.safe.top + screen.safe.bottom) / 2 - bottomBase)
        return min(max(0, sheetLift - bottomBase), cap)
    }

    private var chrome: MapChrome {
        MapChrome(
            contentInset: UIEdgeInsets(top: screen.safe.top, left: screen.safe.leading,
                                       bottom: bottomBase, right: screen.safe.trailing),
            ornamentLift: ornamentLift,
            pillHeight: pillHeight,
            compassTop: Self.margin + controlsHeight + 12,
            controlsCentreFromTrailing: Self.margin + MapControls.buttonSize / 2
        )
    }
}

nonisolated struct ScreenMetrics: Equatable, Sendable {
    var size: CGSize = .zero
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

    var body: some View {
        MapView(model: model, chrome: chrome, trackingMode: trackingMode, hasSelection: hasSelection)
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
