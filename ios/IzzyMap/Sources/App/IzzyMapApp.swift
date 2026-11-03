import SwiftUI

@main
struct IzzyMapApp: App {
    /// Loaded once for the process; immutable, shared by every window.
    @State private var shared: AppData
    @State private var idleTimer = IdleTimerCoordinator()
    /// Layers-sheet thumbnails, shared by every window (one render queue).
    @State private var thumbnails = LayerThumbnails()

    init() {
        MapLogging.install()
        _shared = State(initialValue: AppData.launch())
    }

    var body: some Scene {
        WindowGroup {
            WindowRoot(shared: shared, idleTimer: idleTimer)
                // no accent hue: the app tint is ink (docs/DESIGN.md §2)
                .tint(.primary)
                .environment(thumbnails)
        }
        // Commands are app-wide; they act on the focused window's model.
        .commands { MapCommands() }
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
            .onChange(of: model.layers) { _, state in
                LayerStore().save(state)
                sceneLayers = try? JSONEncoder().encode(state)
            }
            .focusedSceneValue(\.appModel, model)
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
}
