import SwiftUI

/// Hardware-keyboard commands (iPad menu bar, ⌘-hold overlay), acting on the
/// focused window's model.
///
/// Escape walks back one level, in ONE place (`AppModel.escapeStep`):
/// document reader → a level inside the modal (Storage → Layers, Key →
/// Layers, plant sheet → suggestions; `ModalEscape`) → Layers / plant ID /
/// credits → pushed view → card → key highlight → nothing. The reader
/// comes first because it covers everything: while it is up the command
/// closes it (titled "Close Document"), never the card underneath. With
/// nothing to close the command is disabled, so Escape stays free for the
/// system (e.g. a text field or a popover's own dismissal).
///
/// ⌘L is the Location button (locate → follow with heading → stop);
/// ⌘1–4 pick the base map, in the Layers sheet's order.
struct MapCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.escapeStep) private var escapeStep

    var body: some Commands {
        CommandMenu("Map") {
            Button("Search Places") { model?.search.focus() }
                .keyboardShortcut("f")
                .disabled(model == nil)
            Button(locationTitle) { model?.cycleTracking() }
                .keyboardShortcut("l")
                .disabled(model == nil)
            Section("Base Map") {
                ForEach(Array(BaseMap.allCases.enumerated()), id: \.element) { i, base in
                    Button(base.title) { model?.layers.base = base }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                        .disabled(model == nil)
                }
            }
            let step = escapeStep
            Button(step?.title ?? "Back") { model?.escape() }
                .keyboardShortcut(.cancelAction)
                .disabled(step == nil)
        }
    }

    /// What ⌘L does next (the Location button's cycle).
    private var locationTitle: String {
        switch model?.trackingMode ?? .off {
        case .off: "Show My Location"
        case .follow: "Follow With Heading"
        case .followWithHeading: "Stop Following"
        }
    }
}

/// A modal's own navigation, reported to the model so Escape pops ONE level
/// inside it before closing it (`EscapeStep.modalBack`): `depth` is how
/// many levels sit above the modal's root, `pop` goes back one.
struct ModalEscape: ViewModifier {
    let model: AppModel
    let depth: Int
    let pop: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: depth, initial: true) { _, new in
                if model.modal != nil, model.modalDepth != new { model.modalDepth = new }
            }
            .onChange(of: model.modalPopRequest) {
                if depth > 0 { pop() }
            }
    }
}

extension View {
    func modalEscape(_ model: AppModel, depth: Int, pop: @escaping () -> Void) -> some View {
        modifier(ModalEscape(model: model, depth: depth, pop: pop))
    }
}
