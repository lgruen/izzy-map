import IzzyKit
import SwiftUI

/// Readout of the map centre's position, bottom leading: MGA55 grid
/// reference, a tap switches to latitude/longitude (IzzyKit's `GridReadout`
/// is the one formatter). Observes only `MapLiveState`, so a pan re-renders
/// this pill and not the root.
struct GridPill: View {
    let map: MapLiveState
    @State private var readout: GridReadout = .mga

    var body: some View {
        #if DEBUG
        let _ = RenderTrace.body("GridPill")
        #endif
        if let centre = map.centre {
            Button {
                readout = readout.toggled
            } label: {
                Text(readout.text(latitude: centre.latitude, longitude: centre.longitude))
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(readout.spokenText(latitude: centre.latitude, longitude: centre.longitude))
            .accessibilityHint("Switches between grid reference and latitude and longitude")
            .accessibilityIdentifier("grid-pill")
        }
    }
}
