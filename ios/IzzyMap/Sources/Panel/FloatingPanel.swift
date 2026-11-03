import SwiftUI

/// Regular width: the panel as a floating glass card on the leading side.
/// The map, controls and card all stay live together.
struct FloatingPanel: View {
    @Bindable var model: AppModel
    /// Tallest the card may grow before its content scrolls.
    var maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            PanelContent(model: model)
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}
