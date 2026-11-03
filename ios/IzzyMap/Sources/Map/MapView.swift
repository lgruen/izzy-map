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
        let map = MLNMapView(frame: .zero, styleJSON: context.coordinator.initialStyleJSON())
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
