import CoreLocation
import Foundation
import IzzyKit
import Observation
import os

/// A tapped TASVEG polygon, with the facts its tile carries.
nonisolated struct CommunitySelection: Equatable, Sendable {
    /// TASVEG community code, e.g. "DOB".
    let code: String
    /// Name without the "(DOB) " prefix.
    let name: String
    /// Official fill colour, "#rrggbb", when the code is in the table.
    let colorHex: String?
    var group: String?
    var structure: String?
    var notableTrees: String?
    var weeds: String?
}

/// A tapped significant tree (a point) or a tree group (an area).
nonisolated struct TreeSelection: Equatable, Sendable {
    /// Register reference, e.g. "D5".
    let ref: String
    /// Position-accuracy code.
    let accuracy: String
    let isArea: Bool
    /// Index into `TreesData.points` / `.areas`.
    let index: Int
}

/// What the tapped map feature is, for the panel's card.
nonisolated enum SelectedFeature: Equatable, Sendable {
    case community(CommunitySelection)
    /// A geology unit, by SYMB.
    case geology(String)
    /// A pre-1750 class, by MVS number.
    case pre1750(String)
    case tree(TreeSelection)
}

nonisolated struct FeatureSelection: Equatable, Identifiable, Sendable {
    let id = UUID()
    let feature: SelectedFeature

    /// A tree card belongs to the trees layer, every other card to the overlay.
    var isTree: Bool {
        if case .tree = feature { return true }
        return false
    }

    /// The TASVEG code, for a community card.
    var communityCode: String? {
        if case let .community(c) = feature { return c.code }
        return nil
    }
}

/// Immutable launch data shared by every window: located archives and the
/// bundled tables. Loaded once per process.
nonisolated struct AppData: Sendable {
    let location: DataLocation
    let tables: MapTables
    /// Readers of the local season packs (for the coverage caption).
    let seasonProbes: SeasonProbes

    init(location: DataLocation, tables: MapTables) {
        self.location = location
        self.tables = tables
        self.seasonProbes = SeasonProbes(location: location)
    }

    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "App")

    /// Archives located, tables loaded (each table on its own: one missing
    /// file must not take the others down).
    static func launch() -> AppData {
        var tables = MapTables()
        if let data = BundledData.inBundle() {
            func load<T>(_ name: String, _ body: () throws -> T) -> T? {
                do { return try body() } catch {
                    logger.fault("\(name, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            tables.communities = load("communities") { try data.communities() } ?? [:]
            tables.geology = load("geology") { try data.geologyUnits() } ?? [:]
            tables.pre1750 = load("pre1750") { try data.pre1750Units() } ?? [:]
            tables.trees = load("trees") { try data.trees() }
        } else {
            logger.fault("bundled data folder missing")
        }
        return AppData(location: DataLocator.locate(), tables: tables)
    }
}

/// Map state that changes while the camera moves (up to 60 Hz). Kept out of
/// `AppModel` so only the views that show it (the grid pill, the credits
/// sheet, the map's accessibility value) re-render on a pan — not the root.
@Observable
final class MapLiveState {
    /// Map centre (of the uncovered map area), for the grid pill.
    var centre: CLLocationCoordinate2D?
    /// The map has settled: no camera transition, all visible tiles loaded
    /// (MapLibre's "did become idle"). Exposed to UI tests.
    var isIdle = false
    /// Style sources with a visible layer at the current zoom (credits sheet).
    var visibleSources: Set<String> = []
    /// Map zoom, written when the camera settles (season caption).
    var zoom: Double = 0
}

/// Which container holds the panel: the compact bottom sheet or the
/// regular-width floating card (RootView decides, by size class).
nonisolated enum PanelLayout: Sendable { case sheet, card }

/// A modal shown over the map, stamped with the layout it was opened in.
/// The sheet layout hosts modals on the panel sheet (the topmost presented
/// controller); the card layout on the root. When the layout switches, the
/// old host goes away with its modal — the new host never adopts a request
/// from the other layout, and `layoutChanged` clears it.
nonisolated struct ModalRequest: Identifiable, Equatable, Sendable {
    let presentation: Presentation
    let layout: PanelLayout
    var id: String { presentation.id }
}

/// What can be shown modally. One owner (the window's model) for all of them.
nonisolated enum Presentation: String, Identifiable, Sendable {
    case layers, plantID, attribution
    var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: "Layers"
        case .plantID: "Identify a Plant"
        case .attribution: "Map Credits"
        }
    }
}

/// What Escape closes next: a modal, then the card, then a key row's
/// highlight, then nothing.
nonisolated enum EscapeStep: Equatable, Sendable {
    case dismiss(Presentation)
    case closeCard
    case clearHighlight

    var title: String {
        switch self {
        case let .dismiss(presentation): "Close \(presentation.title)"
        case .closeCard: "Close Card"
        case .clearHighlight: "Clear Highlight"
        }
    }
}

/// Time for the location rules, injectable so tests drive it.
struct LocationClock {
    var now: @MainActor () -> ContinuousClock.Instant
    var sleep: @MainActor (Duration) async throws -> Void

    static let live = LocationClock(now: { .now }, sleep: { try await Task.sleep(for: $0) })
}

/// One window's state, shared by its map, controls and panel. Every window
/// (iPad multi-window) has its own: two windows can show two areas.
@Observable
final class AppModel {
    let shared: AppData
    let map = MapLiveState()
    private let clock: LocationClock

    var data: DataLocation { shared.location }
    var tables: MapTables { shared.tables }
    var communities: CommunityTable { shared.tables.communities }

    // MARK: Layers

    /// What the map shows. Changing the overlay dismisses an overlay card (a
    /// vegetation answer over a geology map would lie) but never a tree
    /// card; toggling trees dismisses only a tree card.
    var layers: LayerState {
        didSet {
            guard layers != oldValue else { return }
            if layers.overlay != oldValue.overlay {
                keyHighlight = nil
                if let selection, !selection.isTree { clearSelection() }
            }
            if layers.trees != oldValue.trees, selection?.isTree == true { clearSelection() }
        }
    }

    /// A key row tapped in the legend: its community's polygons get the
    /// dashed "same community" line. Cleared by a selection, an overlay
    /// change, a tap on an empty spot of the map, Escape, or a second tap on
    /// the same row (`toggleKeyHighlight`).
    var keyHighlight: String?

    /// A key row's tap: highlight that community, or clear it when it is
    /// already the highlighted one. Returns whether it is now highlighted.
    @discardableResult
    func toggleKeyHighlight(_ code: String) -> Bool {
        keyHighlight = keyHighlight == code ? nil : code
        return keyHighlight != nil
    }

    /// The style for the current layers, as the map should load it (live
    /// LIST sources only while there is a network path).
    func styleJSON(selection style: SelectionStyle) -> String {
        StyleBuilder.json(state: layers, data: data, tables: tables, selection: style,
                          online: Connectivity.shared.online)
    }

    /// The selection as the style draws it (feature id from the map tap).
    func selectionStyle(featureID: UInt64?) -> SelectionStyle {
        SelectionStyle(featureID: selection == nil ? nil : featureID,
                       community: selection?.communityCode ?? keyHighlight)
    }

    // MARK: Map

    /// Requested user tracking; the map writes back when a pan ends it.
    var trackingMode: TrackingMode = .off
    var selection: FeatureSelection?
    var authorization: CLAuthorizationStatus = .notDetermined

    // MARK: Panel and modals

    var searchText = ""
    /// The modal on screen (at most one).
    var modal: ModalRequest?
    /// Set by RootView from the size classes.
    private(set) var panelLayout: PanelLayout = .sheet

    // MARK: Location messages

    private(set) var notice: LocationNotice?
    /// Tracking asked for while the permission prompt is up; it starts once
    /// the answer is yes (the map drops tracking until then).
    @ObservationIgnored private var trackingAwaitingPermission: TrackingMode?
    @ObservationIgnored private var noFixShown = false
    @ObservationIgnored private var lastFix: ContinuousClock.Instant?
    @ObservationIgnored private var noFixWatch: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    /// How long following may go without a position before saying so.
    static let noFixDelay: Duration = .seconds(10)
    /// A fix older than this no longer counts as "the map shows where you are".
    static let fixStaleAfter: Duration = .seconds(60)
    /// How long a location message stays up.
    static let noticeDuration: Duration = .seconds(10)

    init(shared: AppData, layers: LayerState = .default, clock: LocationClock = .live) {
        self.shared = shared
        self.layers = layers
        self.clock = clock
    }

    convenience init(data: DataLocation, tables: MapTables, layers: LayerState = .default, clock: LocationClock = .live) {
        self.init(shared: AppData(location: data, tables: tables), layers: layers, clock: clock)
    }

    // MARK: Selection

    func select(_ feature: SelectedFeature) {
        keyHighlight = nil
        selection = FeatureSelection(feature: feature)
    }

    /// A TASVEG polygon: names from the table (the tile's VEGCODE_D is the
    /// fallback for a code the table lacks), facts from the tile.
    func selectCommunity(code: String, sourceName: String?, attributes: [String: String] = [:]) {
        let community = communities[code]
        let name = community?.name ?? sourceName ?? code
        func fact(_ key: String) -> String? {
            guard let v = attributes[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty, v != "null" else { return nil }
            return v
        }
        select(.community(CommunitySelection(
            code: code,
            name: Community.stripCodePrefix(name),
            colorHex: community?.color,
            group: community?.group ?? fact("VEG_GROUP"),
            structure: fact("FOREST_STR"),
            notableTrees: fact("NOTABLE_TD"),
            weeds: fact("WEED_TYP_D")
        )))
    }

    func clearSelection() { selection = nil }

    // MARK: Modals and Escape

    func present(_ presentation: Presentation) {
        modal = ModalRequest(presentation: presentation, layout: panelLayout)
    }

    func dismissModal() { modal = nil }

    /// The sheet ↔ card layout changed. A modal belongs to the container that
    /// hosted it, which is gone: reset (the user reopens it in the new layout).
    func layoutChanged(to layout: PanelLayout) {
        guard layout != panelLayout else { return }
        panelLayout = layout
        modal = nil
    }

    /// Whether `presentation` is up in `layout` (hosts ask this).
    func isPresenting(_ presentation: Presentation, in layout: PanelLayout) -> Bool {
        modal?.presentation == presentation && modal?.layout == layout
    }

    /// The next thing Escape closes, nil when there is nothing to close.
    var escapeStep: EscapeStep? {
        if let modal { return .dismiss(modal.presentation) }
        if selection != nil { return .closeCard }
        if keyHighlight != nil { return .clearHighlight }
        return nil
    }

    /// Escape: back one level.
    func escape() {
        switch escapeStep {
        case .dismiss: modal = nil
        case .closeCard: clearSelection()
        case .clearHighlight: keyHighlight = nil
        case nil: break
        }
    }

    // MARK: Location

    var isLocationDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Location button: off → follow → follow with heading → off.
    func cycleTracking() {
        if isLocationDenied {
            trackingMode = .off
            show(.denied)
            return
        }
        let wasOff = trackingMode == .off
        trackingMode = trackingMode.next
        trackingAwaitingPermission = authorization == .notDetermined && trackingMode != .off ? trackingMode : nil
        if trackingMode == .off {
            noFixWatch?.cancel()
        } else if wasOff {
            watchForFix()
        }
    }

    /// The map changed tracking itself (a pan ends following).
    func mapChangedTracking(to mode: TrackingMode) {
        guard mode != trackingMode else { return }
        if mode == .off, authorization != .notDetermined { trackingAwaitingPermission = nil }
        trackingMode = mode
        if mode == .off { noFixWatch?.cancel() }
    }

    func locationUpdated() {
        lastFix = clock.now()
        noFixWatch?.cancel()
        if notice == .noFix { dismissNotice() }
    }

    /// MapLibre reported a location failure. MapLibre Native 7.0.0 forwards
    /// only `kCLErrorDenied` (`MLNMapView.mm`, locationManager:didFailWithError:)
    /// and has already switched tracking and the puck off; a temporary "no
    /// fix" never reaches us — `watchForFix` covers that.
    func locationDenied() {
        authorization = .denied
        trackingMode = .off
        noFixWatch?.cancel()
        show(.denied)
    }

    func authorizationChanged(to status: CLAuthorizationStatus) {
        authorization = status
        let pending = trackingAwaitingPermission
        if status != .notDetermined { trackingAwaitingPermission = nil }
        if isLocationDenied {
            if trackingMode != .off || pending != nil {
                trackingMode = .off
                noFixWatch?.cancel()
                show(.denied)
            }
        } else if status != .notDetermined, let pending, trackingMode == .off {
            trackingMode = pending
            watchForFix()
        }
    }

    func dismissNotice() {
        noticeTimer?.cancel()
        notice = nil
    }

    /// Following started: if no position arrives within `noFixDelay`, say so
    /// once — unless the map still shows a recent fix (the puck from before
    /// following, younger than `fixStaleAfter`); then check again when that
    /// fix goes stale. Any new fix ends the watch.
    private func watchForFix() {
        noFixWatch?.cancel()
        noFixWatch = Task { [weak self, clock] in
            var wait = Self.noFixDelay
            while true {
                do { try await clock.sleep(wait) } catch { return }
                guard !Task.isCancelled, let self, self.trackingMode != .off else { return }
                if let lastFix = self.lastFix {
                    let age = lastFix.duration(to: clock.now())
                    if age < Self.fixStaleAfter {
                        wait = Self.fixStaleAfter - age
                        continue
                    }
                }
                self.showNoFixOnce()
                return
            }
        }
    }

    /// One "no fix" message per session.
    private func showNoFixOnce() {
        guard !noFixShown else { return }
        noFixShown = true
        show(.noFix)
    }

    private func show(_ notice: LocationNotice) {
        self.notice = notice
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self, clock] in
            do { try await clock.sleep(Self.noticeDuration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
