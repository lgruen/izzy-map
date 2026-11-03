import SwiftUI

/// Hardware-keyboard commands (iPad menu bar, ⌘-hold overlay), acting on the
/// focused window's model.
///
/// Escape walks back one level, in ONE place (`AppModel.escapeStep`):
/// document reader → Layers / plant ID / credits → pushed view → card →
/// key highlight → nothing. The reader comes first because it covers
/// everything: while it is up the command closes it (titled "Close
/// Document"), never the card underneath. With nothing to close the
/// command is disabled, so Escape stays free for the system (e.g. a text
/// field or a popover's own dismissal).
// TODO(M7): ⌘F search, ⌘L locate, ⌘1–4 bases; Escape through the sheet stack.
struct MapCommands: Commands {
    @FocusedValue(\.appModel) private var model

    var body: some Commands {
        CommandMenu("Map") {
            let step = model?.escapeStep
            Button(step?.title ?? "Back") { model?.escape() }
                .keyboardShortcut(.cancelAction)
                .disabled(step == nil)
        }
    }
}
