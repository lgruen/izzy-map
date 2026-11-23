import SwiftUI

/// Moving a pin: the one-shot mode's bar at the top ("Tap the new spot",
/// Cancel) — the framing bar's form. Escape cancels too.
struct PinMoveBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.cancelPinMove() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignColor.ink)
            .hoverEffect(.highlight)
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("pin-move-cancel")

            if let pin = model.movingPin.flatMap({ model.pins?.pin($0) }) {
                PinMark(hex: PinColour.hex(forName: pin.effectiveColourName))
            }
            Text("Tap the new spot")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .mapChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-move-bar")
    }
}

/// "Pin deleted · Undo" (or "Project deleted", "Pin moved"), for a few
/// seconds after a delete or a move (the notice banner's form: above the
/// sheet on a phone held upright, in the top slot beside the card, at the
/// foot of the Pins screen while that is up).
struct PinUndoBanner: View {
    let undo: AppModel.PinUndo
    /// Over the map (light chrome, `mapChrome`), or inside the Pins screen
    /// (follows the sheet's appearance).
    var onMap = true
    @Environment(\.colorScheme) private var colorScheme
    let onUndo: () -> Void
    let onDismiss: () -> Void

    static func headline(_ undo: AppModel.PinUndo) -> String {
        if undo.movedFrom != nil { return "Pin moved" }
        return undo.project == nil ? "Pin deleted" : "Project deleted"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: undo.movedFrom == nil ? "trash" : "arrow.up.and.down.and.arrow.left.and.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(DesignColor.secondaryInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.headline(undo))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                if !undo.title.isEmpty {
                    Text(undo.project == nil || undo.pinCount == 0 ? undo.title : "\(undo.title) · \(PinText.count(undo.pinCount))")
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("pin-undo")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(DesignColor.secondaryInk)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, onMap ? .light : colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-undo-banner")
    }
}

/// The pin store couldn't be opened (PinStore.openFailed): pins added now
/// live in memory and go when the app quits — said plainly, and kept up
/// until she dismisses it (once per session). The file itself is left as
/// it was.
struct PinStoreFailedBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.body.weight(.semibold))
                .foregroundStyle(DesignColor.secondaryInk)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(Self.message)
                .font(.subheadline)
                .foregroundStyle(DesignColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(DesignColor.secondaryInk)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(.top, -12)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .mapChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-store-failed")
    }

    static let message = "Pins couldn’t be opened — anything added now won’t be kept after IzzyMap closes."
}
