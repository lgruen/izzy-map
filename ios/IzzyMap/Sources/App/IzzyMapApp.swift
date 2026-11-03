import SwiftUI

@main
struct IzzyMapApp: App {
    /// Loaded once for the process; immutable, shared by every window.
    @State private var shared: AppData
    @State private var idleTimer = IdleTimerCoordinator()

    init() {
        MapLogging.install()
        _shared = State(initialValue: AppData.launch())
    }

    var body: some Scene {
        WindowGroup {
            WindowRoot(shared: shared, idleTimer: idleTimer)
        }
        // Commands are app-wide; they act on the focused window's model.
        .commands { MapCommands() }
    }
}

/// One window: its own model (camera, selection, tracking, modals), so two
/// iPad windows can show two different areas side by side.
struct WindowRoot: View {
    let idleTimer: IdleTimerCoordinator
    @State private var model: AppModel
    @State private var windowID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    init(shared: AppData, idleTimer: IdleTimerCoordinator) {
        self.idleTimer = idleTimer
        _model = State(initialValue: AppModel(shared: shared))
    }

    var body: some View {
        RootView(model: model)
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
