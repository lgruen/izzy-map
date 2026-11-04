import IzzyKit
import MapLibre
import SwiftUI

/// Where the chrome sits over the map, so MapLibre can keep its centre,
/// user puck and ornaments in the uncovered area.
nonisolated struct MapChrome: Equatable, Sendable {
    /// The map's content inset (includes the safe area).
    var contentInset: UIEdgeInsets = .zero
    /// Extra lift of the bottom ornaments while the sheet is raised.
    var ornamentLift: CGFloat = 0
    /// Room the grid pill takes under the scale bar.
    var pillHeight: CGFloat = 0
    /// Top of MapLibre's compass, below the floating controls.
    var compassTop: CGFloat = 0
    /// Trailing inset that centres the compass under the controls.
    var controlsCentreFromTrailing: CGFloat = 40
    /// The map area no chrome covers (safe area, the iPad card, the phone's
    /// sheet, the controls, the pills, a notice), as insets from the map's
    /// bounds — measured frames (`MapFraming`). A camera that frames an
    /// extent keeps it inside.
    var framingInsets: UIEdgeInsets = .zero
    /// While framing a detailed area: the dashed frame, in the map view's
    /// coordinates (its box on the ground goes to `MapLiveState.framedBox`).
    var areaFrame: CGRect?
    /// The framed box while its setup shows as the side card (wide
    /// layouts): the map keeps it in view beside the card and reports
    /// where it is (`MapLiveState.draftRect`) for the frame to follow.
    var areaDraft: AreaBox?
}

/// The one MapLibre map view. SwiftUI owns the state (`AppModel`); the
/// coordinator turns map events into model changes and back.
struct MapView: UIViewRepresentable {
    let model: AppModel
    var chrome: MapChrome
    var trackingMode: TrackingMode
    var hasSelection: Bool
    var layers: LayerState
    var keyHighlight: String?
    var spotlight: Spotlight?
    /// The picked search place (Search/SearchPinPresenter.swift).
    var searchPin: SearchModel.Pin?
    /// A detailed area to frame ("Show on map" in Storage).
    var areaFocus: AppModel.AreaFocus?

    func makeCoordinator() -> MapCoordinator { MapCoordinator(model: model) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = OrnamentFreeMapView(frame: .zero, styleJSON: context.coordinator.initialStyleJSON())
        context.coordinator.attach(to: map)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(chrome: chrome, to: map)
        coordinator.apply(tracking: trackingMode, to: map)
        coordinator.apply(layers: layers, to: map)
        if !hasSelection { coordinator.clearSelectionShape() }
        coordinator.apply(keyHighlight: keyHighlight)
        coordinator.apply(spotlight: spotlight, to: map)
        coordinator.searchPins.apply(searchPin, framing: chrome.framingInsets, to: map)
        coordinator.apply(areaFocus: areaFocus, framing: chrome.framingInsets, to: map)
    }
}

/// MLNMapView minus MapLibre's own ornaments in its accessibility
/// container. The map vends its compass, (i) and logo as accessibility
/// elements itself, hidden or not: XCUITest and the accessibility audit
/// found "About this map" — MapLibre's credits sheet, bypassing ours — and
/// "Compass, north" on a map that showed neither (2026-11-04). This keeps
/// what the container vends (annotations such as the search pin, the user
/// location) and drops the (i) and the logo always, the compass while the
/// map faces north (it shows, and works, once the map is rotated).
/// UIAccessibilityContainer overrides: supported UIKit API on a subclass.
final class OrnamentFreeMapView: MLNMapView {
    private func isHiddenOrnament(_ element: Any) -> Bool {
        let object = element as AnyObject
        if object === attributionButton || object === logoView { return true }
        return object === compassView && abs(direction.remainder(dividingBy: 360)) < 0.5
    }

    /// What MapLibre vends, minus the hidden ornaments (only computed for
    /// an accessibility client: VoiceOver, XCUITest).
    private var vended: [Any] {
        (0 ..< super.accessibilityElementCount()).compactMap { super.accessibilityElement(at: $0) }
            .filter { !isHiddenOrnament($0) }
    }

    override func accessibilityElementCount() -> Int { vended.count }

    override func accessibilityElement(at index: Int) -> Any? {
        let all = vended
        return all.indices.contains(index) ? all[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        vended.firstIndex { ($0 as AnyObject) === (element as AnyObject) } ?? NSNotFound
    }
}
