import SwiftUI

/// The panel's navigation stack (bottom sheet and floating card alike):
/// the root is the search header and the tapped feature's card; group
/// lists and plant sheets push over it. Back restores the card exactly
/// where it was (the root stays alive underneath); a new tap or a close
/// drops the stack (`AppModel.cardPath`). Content sits straight on the
/// container's glass: no navigation background.
struct PanelStack<Root: View>: View {
    @Bindable var model: AppModel
    @ViewBuilder var root: Root
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $model.cardPath) {
            root
                .toolbar(.hidden, for: .navigationBar)
                // the pushed views' back button reads "DOB"
                .navigationTitle(model.selection?.communityCode ?? "Card")
                .containerBackground(.clear, for: .navigation)
                .navigationDestination(for: CardRoute.self) { route in
                    destination(route)
                        .toolbar(.visible, for: .navigationBar)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .environment(\.cardNamespace, zoom)
    }

    @ViewBuilder private func destination(_ route: CardRoute) -> some View {
        switch route {
        case let .group(key, context):
            GroupList(model: model, key: key, context: context)
                .navigationTitle(PlantLibrary.shared.catalog?.group(key)?.common ?? "Group")
        case let .plant(id, key, context, source):
            PlantSheet(model: model, plantID: id, key: key, context: context, source: source)
                .navigationTitle("")
        }
    }
}
