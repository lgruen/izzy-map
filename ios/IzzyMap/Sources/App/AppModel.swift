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
    /// Where it was tapped (the "recorded near here" list, the mini-maps' ring).
    var latitude: Double?
    var longitude: Double?
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

/// Launch data shared by every window: the packs (observable: archives come
/// and go as packs install) and the bundled tables. Loaded once per process.
nonisolated struct AppData: Sendable {
    let packs: PackStore
    let tables: MapTables
    /// Detailed areas (the style draws their finished layers).
    let areas: AreaStore

    @MainActor init(packs: PackStore, tables: MapTables, areas: AreaStore) {
        self.packs = packs
        self.tables = tables
        self.areas = areas
    }

    /// Tests and previews: fixed archives, no areas.
    @MainActor init(location: DataLocation, tables: MapTables, areas: AreaStore? = nil) {
        self.init(packs: PackStore(fixed: location), tables: tables, areas: areas ?? AreaStore(directory: nil, backgroundTask: false))
    }

    /// The archives readable now.
    @MainActor var location: DataLocation { packs.location }
    /// Readers of the local season packs (for the coverage caption).
    @MainActor var seasonProbes: SeasonProbes { packs.seasonProbes }

    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "App")

    /// Archives located, tables loaded (each table on its own: one missing
    /// file must not take the others down).
    @MainActor static func launch() -> AppData {
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
            tables.outline = load("outline") { try data.tasmaniaOutline() }
        } else {
            logger.fault("bundled data folder missing")
        }
        return AppData(packs: PackStore.launch(), tables: tables, areas: .shared)
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
    /// While framing a detailed area: the frame's box on the ground,
    /// written by the map as it moves (the framing bar's live gauge).
    var framedBox: AreaBox?
    /// The setup card's box on screen (map view coordinates), while it shows.
    var draftRect: CGRect?
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
    /// A framed area's setup: name, layers, detail, size (Next).
    case areaSetup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: "Layers"
        case .plantID: "Identify a Plant"
        case .attribution: "Map Credits"
        case .areaSetup: "Detailed area"
        }
    }
}

/// What Escape closes next: a modal, then the card, then a key row's
/// highlight, then nothing.
nonisolated enum EscapeStep: Equatable, Sendable {
    /// The full-screen document reader (over everything, so first).
    case closeDocument
    case dismiss(Presentation)
    /// One level back inside the modal (Storage → Layers, Key → Layers,
    /// plant sheet → suggestions).
    case modalBack
    /// Framing a detailed area: Cancel.
    case cancelFraming
    /// One view back in the card's stack (plant sheet → group list → card).
    case back
    case closeCard
    case clearHighlight
    /// Search: the field's focus, then the result list, then the pin.
    case leaveSearchField
    case closeSearch
    case clearSearchPin

    var title: String {
        switch self {
        case .closeDocument: "Close Document"
        case let .dismiss(presentation): "Close \(presentation.title)"
        case .modalBack: "Back"
        case .cancelFraming: "Cancel Framing"
        case .back: "Back"
        case .closeCard: "Close Card"
        case .clearHighlight: "Clear Highlight"
        case .leaveSearchField: "Leave Search Field"
        case .closeSearch: "Close Search"
        case .clearSearchPin: "Clear Search Pin"
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
    /// The window's documents: fetches, the reader, failures (Escape's first step).
    let documents = DocumentOpener()
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
    var keyHighlight: String? {
        // clearing the highlight (Escape, a second key-row tap, an overlay
        // change) leaves "Show on map" the way it came
        didSet { if let spotlight, keyHighlight != spotlight.code { exitSpotlight() } }
    }

    /// "Show on map": one community soloed statewide or patch by patch
    /// (Map/Spotlight.swift). Its exit pill sits on the map.
    var spotlight: Spotlight?
    /// Set when the spotlight goes: whether the camera flies back to where
    /// it was (an exit) or stays (she tapped the map and is exploring).
    @ObservationIgnored var spotlightRestoresCamera = false

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
                          online: Connectivity.shared.online, areas: shared.areas.styleSources)
    }

    /// The selection as the style draws it (feature id from the map tap).
    func selectionStyle(featureID: UInt64?) -> SelectionStyle {
        SelectionStyle(featureID: selection == nil ? nil : featureID,
                       community: selection?.communityCode ?? keyHighlight)
    }

    // MARK: Map

    /// Requested user tracking; the map writes back when a pan ends it.
    var trackingMode: TrackingMode = .off
    var selection: FeatureSelection? {
        // a new tap or a close drops the whole stack
        didSet { if selection?.id != oldValue?.id { cardPath = [] } }
    }
    /// Views pushed over the card (group list, plant sheet), oldest first.
    var cardPath: [CardRoute] = []

    /// Pushes a view over the card — never the same one twice in a row (a
    /// double tap lands on the row again before the push shows).
    func push(_ route: CardRoute) {
        guard selection != nil, cardPath.last != route else { return }
        cardPath.append(route)
    }

    var authorization: CLAuthorizationStatus = .notDetermined

    // MARK: Panel and modals

    /// Place search: query, results, the picked place's pin (Search/).
    let search = SearchModel()
    /// The modal on screen (at most one).
    var modal: ModalRequest? {
        didSet { if modal != oldValue { modalDepth = 0 } }
    }
    /// Levels pushed inside the open modal's own navigation (Layers ▸ Key /
    /// Storage, Identify ▸ plant sheet, Credits ▸ Acknowledgements): the
    /// modal reports it (`ModalEscape`), so Escape pops one level before it
    /// closes the modal.
    var modalDepth = 0
    /// Bumped by Escape while `modalDepth > 0`: the modal pops one level.
    private(set) var modalPopRequest = 0
    /// Set by RootView from the size classes.
    private(set) var panelLayout: PanelLayout = .sheet

    // MARK: First launch

    /// The one-time welcome over the map (App/FirstLaunch.swift): until she
    /// taps OK, opens Layers or Identify, or taps a feature.
    private(set) var showsWelcome: Bool
    @ObservationIgnored private let welcome: WelcomeStore

    func dismissWelcome() {
        guard showsWelcome else { return }
        showsWelcome = false
        welcome.markSeen()
    }

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

    init(shared: AppData, layers: LayerState = .default, clock: LocationClock = .live, welcome: WelcomeStore = WelcomeStore()) {
        self.shared = shared
        self.layers = layers
        self.clock = clock
        self.welcome = welcome
        showsWelcome = !welcome.seen
        search.near = { [map] in map.centre.map { GeoPoint(longitude: $0.longitude, latitude: $0.latitude) } }
        // a picked place is a new view: the card and a soloed community go
        search.onPick = { [weak self] in
            self?.endSpotlight()
            self?.clearSelection()
        }
    }

    convenience init(data: DataLocation, tables: MapTables, layers: LayerState = .default, clock: LocationClock = .live,
                     welcome: WelcomeStore = WelcomeStore()) {
        self.init(shared: AppData(location: data, tables: tables), layers: layers, clock: clock, welcome: welcome)
    }

    // MARK: Selection

    func select(_ feature: SelectedFeature) {
        // she found the core gesture: the welcome has done its job
        dismissWelcome()
        endSpotlight()
        // a map tap while the results are up (iPad, the phone's medium
        // detent) shows its card
        if search.isActive { search.end() }
        keyHighlight = nil
        selection = FeatureSelection(feature: feature)
    }

    /// A TASVEG polygon: names from the table (the tile's VEGCODE_D is the
    /// fallback for a code the table lacks), facts from the tile.
    func selectCommunity(code: String, sourceName: String?, attributes: [String: String] = [:],
                         at coordinate: CLLocationCoordinate2D? = nil) {
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
            weeds: fact("WEED_TYP_D"),
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )))
    }

    func clearSelection() { selection = nil }

    // MARK: Modals and Escape

    func present(_ presentation: Presentation) {
        if presentation == .layers || presentation == .plantID { dismissWelcome() }
        if presentation == .plantID, modal?.presentation != .plantID { PlantIDOpenTiming.begin() }
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
        if documents.isReading { return .closeDocument }
        if let modal { return modalDepth > 0 ? .modalBack : .dismiss(modal.presentation) }
        if isFraming { return .cancelFraming }
        if search.fieldFocused { return .leaveSearchField }
        if search.isActive { return .closeSearch }
        if selection != nil, !cardPath.isEmpty { return .back }
        if selection != nil { return .closeCard }
        if keyHighlight != nil { return .clearHighlight }
        if search.pin != nil { return .clearSearchPin }
        return nil
    }

    /// Escape: back one level.
    func escape() {
        switch escapeStep {
        case .closeDocument: documents.closeReader()
        case .modalBack: modalPopRequest += 1
        case .dismiss: modal = nil
        case .cancelFraming: cancelFraming()
        case .back: cardPath.removeLast()
        case .closeCard: clearSelection()
        case .clearHighlight: keyHighlight = nil
        case .leaveSearchField: search.fieldFocused = false
        case .closeSearch: search.end()
        case .clearSearchPin: search.clearPin()
        case nil: break
        }
    }

    // MARK: Detailed areas

    /// Framing an area on the map: a dashed frame over the uncovered map and
    /// a glass bar with the live size (AreaFraming.swift). Taps on the map
    /// don't select anything meanwhile.
    private(set) var isFraming = false
    /// The framed box handed to the setup sheet by Next.
    private(set) var areaDraft: AreaBox?
    /// Layers opens with Storage pushed (after Download: the new row; the
    /// "Maps arriving" chip: the maps), scrolled to `storageOpenTarget`.
    var opensStorage = false
    @ObservationIgnored var storageOpenTarget: String?

    /// Storage over the map, from anywhere (the chip, Download).
    func openStorage(at target: String?) {
        storageOpenTarget = target
        opensStorage = true
        present(.layers)
    }
    /// "Show on map" for a detailed area: the map frames it (each request
    /// a new serial, so the same area can be asked for twice).
    private(set) var areaFocus: AreaFocus?

    nonisolated struct AreaFocus: Equatable, Sendable {
        let box: AreaBox
        let serial: Int
    }

    func showArea(_ box: AreaBox) {
        modal = nil
        if isFraming { cancelFraming() }
        if trackingMode != .off { trackingMode = .off }
        areaFocus = AreaFocus(box: box, serial: (areaFocus?.serial ?? 0) + 1)
    }

    /// "Download an area…" (Storage, Layers): the modal goes, the map frames.
    func startFraming() {
        modal = nil
        endSpotlight()
        if search.isActive { search.end() }
        clearSelection()
        keyHighlight = nil
        areaDraft = nil
        // the frame is the box that downloads: north up, the map still
        // (following would drag it away; the map turns north as it opens)
        if trackingMode != .off { trackingMode = .off }
        isFraming = true
    }

    func cancelFraming() {
        isFraming = false
        areaDraft = nil
        map.framedBox = nil
        map.draftRect = nil
        if modal?.presentation == .areaSetup { modal = nil }
    }

    /// Next: the setup sheet for the box in the frame (if it fits).
    func framingNext() {
        guard isFraming, let box = map.framedBox, AreaPlan.fitsFraming(box) else { return }
        areaDraft = box
        present(.areaSetup)
    }

    /// Download tapped: framing ends and Storage shows the new row.
    func areaStarted() {
        isFraming = false
        areaDraft = nil
        map.framedBox = nil
        map.draftRect = nil
        openStorage(at: StorageTarget.areas)
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

    #if DEBUG
    /// Screenshots: `-debugNotice denied|noFix` shows that message at launch.
    func debugShowNotice() {
        switch UserDefaults.standard.string(forKey: "debugNotice") {
        case "denied": show(.denied)
        case "noFix": show(.noFix)
        default: break
        }
    }
    #endif

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
