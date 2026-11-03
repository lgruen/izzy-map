import SwiftUI

@main
struct IzzyMapApp: App {
    /// Loaded once for the process; immutable, shared by every window.
    @State private var shared: AppData
    @State private var idleTimer = IdleTimerCoordinator()
    /// Layers-sheet thumbnails, shared by every window (one render queue).
    @State private var thumbnails: LayerThumbnails
    /// Thumbnails re-render when a pack is installed or removed (the style
    /// follows by itself: it reads the observable `PackStore.location`).
    @State private var packsSubscription: Connectivity.Subscription

    /// The unit tests run inside the app (IzzyMapTests' test host), which
    /// the scheme launches with the Run action's `-dataDir`: a full map
    /// parsing real tiles. XCTest ends the host with `exit()`, whose static
    /// destructors free MapLibre's expression registry while its tile
    /// workers still evaluate fill colours with it — the EXC_BAD_ACCESS in
    /// `CompoundExpression::evaluate` / `__cxa_pure_virtual` in
    /// `Coercion::evaluate` of 2026-11-03 (every report: main thread in
    /// `exit` ← `_XCTestMain`). So the host window has no map. UI tests
    /// launch the app as its own process, without this variable.
    #if DEBUG
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #else
    static let isUnitTestHost = false
    #endif

    init() {
        MapLogging.install()
        let shared = AppData.launch()
        let thumbnails = LayerThumbnails()
        _shared = State(initialValue: shared)
        _thumbnails = State(initialValue: thumbnails)
        _packsSubscription = State(initialValue: shared.packs.observe { [weak thumbnails] in thumbnails?.packsChanged() })
        // the one-tap extras: sweep staged leftovers, then reconnect to the
        // background session (a previous launch's finished files report as
        // orphans). The session may thus exist before the scene's
        // background-task handler below runs — `handleEvents` copes.
        ExtrasDownloads.shared.launch { SessionTransport.shared.connect() }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isUnitTestHost {
                // IzzyMapTests make their own maps; the host shows none
                Color.clear
            } else {
                WindowRoot(shared: shared, idleTimer: idleTimer)
                    // no accent hue: the app tint is ink (docs/DESIGN.md §2)
                    .tint(.primary)
                    .environment(thumbnails)
            }
        }
        // Commands are app-wide; they act on the focused window's model.
        .commands { MapCommands() }
        // the one-tap extras' background downloads: a wake for their events
        // hands over to the transport; once every event is in, the engine
        // applies them and starts the next window before the system's
        // handler is called (milestone 3)
        .backgroundTask(.urlSession(SessionTransport.identifier)) {
            await SessionTransport.shared.handleEvents()
            await ExtrasDownloads.shared.settle()
        }
    }
}

/// One window. Its layers are restored with the scene; the layer store
/// keeps the last change too (a force-quit discards scene restoration
/// data). The restored state is decided HERE, before the window's model
/// and map exist, so the map is created with it — never with the store's
/// state and then restyled (a wrong-style flash).
struct WindowRoot: View {
    let shared: AppData
    let idleTimer: IdleTimerCoordinator
    @SceneStorage("layerState") private var sceneLayers: Data?

    var body: some View {
        WindowContent(shared: shared, idleTimer: idleTimer, initialLayers: initialLayers, sceneLayers: $sceneLayers)
    }

    /// A `-layerState` launch argument (DEBUG screenshots, UI tests) wins;
    /// then the scene's own state; then the last state of any window.
    private var initialLayers: LayerState {
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[LayerStore.key]
        if argument == nil, let sceneLayers, let restored = try? JSONDecoder().decode(LayerState.self, from: sceneLayers) {
            return restored
        }
        return LayerStore().load()
    }
}

/// One window's content: its own model (camera, selection, tracking,
/// modals), so two iPad windows can show two different areas side by side.
private struct WindowContent: View {
    let idleTimer: IdleTimerCoordinator
    @Binding var sceneLayers: Data?
    @State private var model: AppModel
    @State private var windowID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    /// `initialLayers` is read once: `@State` keeps the first model.
    init(shared: AppData, idleTimer: IdleTimerCoordinator, initialLayers: LayerState, sceneLayers: Binding<Data?>) {
        self.idleTimer = idleTimer
        _sceneLayers = sceneLayers
        _model = State(initialValue: AppModel(shared: shared, layers: initialLayers))
    }

    var body: some View {
        RootView(model: model)
            // documents belong to the window: buttons find the opener here
            .environment(model.documents)
            // a document fetch lasts as long as its card is selected
            .onChange(of: model.selection?.id) { model.documents.selectionChanged() }
            .onChange(of: model.layers) { _, state in
                LayerStore().save(state)
                sceneLayers = try? JSONEncoder().encode(state)
            }
            .focusedSceneValue(\.appModel, model)
            // the Escape command's title and enabled state: a value, so the
            // menu re-evaluates when it changes (Commands don't observe the
            // model's own properties — a pin dropped after the menu last
            // rendered left Escape disabled)
            .focusedSceneValue(\.escapeStep, model.escapeStep)
            // Keep the screen on only while this window follows and is in
            // the foreground; the coordinator ORs all windows.
            .onChange(of: keepsAwake, initial: true) { _, on in
                idleTimer.update(window: windowID, keepsAwake: on)
            }
            .onDisappear { idleTimer.remove(window: windowID) }
    }

    private var keepsAwake: Bool {
        IdleTimerCoordinator.keepsAwake(following: model.trackingMode != .off, foreground: scenePhase != .background)
    }
}

extension FocusedValues {
    /// The focused window's model, for the menu-bar commands.
    @Entry var appModel: AppModel?
    /// What Escape closes next in the focused window (nil: nothing).
    @Entry var escapeStep: EscapeStep?
}
