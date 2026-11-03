import SwiftUI

/// Placeholder Layers sheet (iPhone) / popover (iPad). Milestone 2 adds
/// bases, overlays with strength, relief, trees and the legend; for now it
/// says which archives are on this device.
struct LayersSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Base map") {
                    ArchiveRow(title: "Topographic", detail: "theLIST basemap", present: model.data.url(for: .topo) != nil)
                }
                Section("Overlay") {
                    ArchiveRow(title: "Vegetation", detail: "TASVEG 5.0 communities", present: model.data.url(for: .tasveg) != nil)
                }
                Section {
                    Text("More base maps, overlays and the legend arrive in the next version.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

private struct ArchiveRow: View {
    let title: String
    let detail: String
    let present: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Label(present ? "On this device" : "Not on this device",
                  systemImage: present ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .foregroundStyle(present ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
