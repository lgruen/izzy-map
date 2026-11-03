import SwiftUI

/// Minimal card for a tapped TASVEG polygon: swatch, code, name.
/// (Milestone 3 adds group, structure, description and plants.)
struct FeatureCard: View {
    let selection: FeatureSelection
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .headline) private var swatchSize = 44

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selection.colorHex.flatMap(Color.init(hex:)) ?? Color(.systemGray4))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                }
                .frame(width: swatchSize, height: swatchSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(selection.code)
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                Text(selection.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vegetation community \(selection.code), \(selection.name)")
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.fill.tertiary, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            // (Escape on a hardware keyboard: MapCommands)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("card-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feature-card")
    }
}
