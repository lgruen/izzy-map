import SwiftUI

@main
struct PlantIDTestApp: App {
    @StateObject private var runner = Runner()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(runner: runner)
                .onChange(of: phase) { _, p in runner.phaseChanged(background: p != .active) }
        }
    }
}
