import SwiftUI

/// Regular width: the panel as a floating card on the leading side. The
/// map, controls and card all stay live together.
///
/// The card is one Liquid Glass slab — the system glass treatment, as on
/// the compact sheet — with the content straight on it in non-vibrant label
/// colours and no inner glass or material groups (docs/DESIGN.md §2).
/// DEBUG `-sheetStyle plate`: a thin glass rim around a near-opaque plate.
struct FloatingPanel: View {
    @Bindable var model: AppModel
    /// Tallest the card may grow before its content scrolls.
    var maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    private static let radius: CGFloat = 28
    /// Width of the glass rim around the DEBUG plate.
    private static let rim: CGFloat = 4

    var body: some View {
        switch PanelSurface.current {
        case .system:
            scroller(inset: 16 + Self.rim, maxHeight: maxHeight)
                .clipShape(.rect(cornerRadius: Self.radius))
                .containerShape(.rect(cornerRadius: Self.radius))
                .glassEffect(.regular, in: .rect(cornerRadius: Self.radius))
        case .plate:
            scroller(inset: 16, maxHeight: maxHeight - 2 * Self.rim)
                .background { PanelPlate() }
                .clipShape(ConcentricRectangle())
                .padding(Self.rim)
                .containerShape(.rect(cornerRadius: Self.radius))
                .glassEffect(.regular, in: .rect(cornerRadius: Self.radius))
        }
    }

    private func scroller(inset: CGFloat, maxHeight: CGFloat) -> some View {
        ScrollView {
            PanelContent(model: model)
                .padding(inset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}
