import SwiftUI
import UIKit

/// A location message as a glass banner near the top.
struct NoticeBanner: View {
    let notice: LocationNotice
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(DesignColor.secondaryInk)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if notice == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.glassProminent)
                        .accessibilityHint("Opens IzzyMap's settings")
                }
            }
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
        .accessibilityIdentifier("location-notice")
    }
}
