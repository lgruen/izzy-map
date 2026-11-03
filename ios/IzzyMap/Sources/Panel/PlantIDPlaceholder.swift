import SwiftUI

/// Stand-in until plant identification lands (milestone 6).
struct PlantIDPlaceholder: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Identify a plant", systemImage: "camera.macro")
            } description: {
                Text("Take or pick a photo of a plant and IzzyMap will suggest what it is. Coming in a later version.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
