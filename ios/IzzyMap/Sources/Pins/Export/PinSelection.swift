import SwiftUI

// Choosing pins to export from a project's list (docs/PINS_PLAN.md §5,
// "Select → Export"): Select in the list's header turns the rows into
// checkmark rows; the header then counts them and offers Select all; the
// foot carries the action with the count.

/// The "Pins" header of a project's list, with Select — or, while
/// selecting, the count and Select all / Deselect all.
struct PinsSectionHeader: View {
    let count: Int
    @Binding var selection: Set<UUID>?
    let all: [UUID]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let selection {
                Text(selection.isEmpty ? "Select pins" : "\(selection.count.formatted()) selected")
                    .panelHeader()
                    .monospacedDigit()
                    .accessibilityIdentifier("pins-selected-count")
                Spacer(minLength: 8)
                let everything = selection.count == all.count
                headerButton(everything ? "Deselect all" : "Select all", id: "pins-select-all") {
                    self.selection = everything ? [] : Set(all)
                }
            } else {
                Text("Pins").panelHeader()
                Spacer(minLength: 8)
                if count > 0 {
                    headerButton("Select", id: "pins-select") { selection = [] }
                }
            }
        }
    }

    private func headerButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .textCase(nil)
        .accessibilityIdentifier(id)
    }
}

/// The foot of the list while selecting: "Export 3 pins…" (the ink capsule).
struct ExportSelectionBar: View {
    let count: Int
    let export: () -> Void

    var body: some View {
        ExportCapsule(title: count == 0 ? "Export…" : "Export \(PinText.count(count))…", symbol: "square.and.arrow.up",
                      prominent: true, action: export)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.bar)
            .accessibilityIdentifier("pins-export-selected")
    }
}

/// A pin row's checkmark while selecting (trailing, as in every
/// checkmark row of the app).
struct SelectionMark: View {
    let on: Bool

    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(on ? DesignColor.ink : DesignColor.secondaryInk)
            .accessibilityHidden(true)
    }
}
