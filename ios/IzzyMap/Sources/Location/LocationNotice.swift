/// A short, honest message about location, shown as a banner.
nonisolated enum LocationNotice: Equatable, Sendable {
    /// Location access is off for IzzyMap (offers a Settings link).
    case denied
    /// Following, but no position yet. Not an error: Wi-Fi-only iPads have
    /// no GPS, and a fix can take a while outdoors.
    case noFix
    /// The pin button without a usable fix: never a guess at the map
    /// centre — the other way to place a pin instead.
    case noFixForPin
    /// The pin button while iOS is still asking for permission, or the
    /// first fix since it was given hasn't come yet: wait — or long-press.
    case waitingForPin
    /// The pin button with location access off: the other way to place a
    /// pin first, then Settings.
    case deniedForPin
    /// "Move to my location" without a usable fix (none yet, or iOS still
    /// asking): the other way to move it — never the long-press, which
    /// would place a second pin.
    case noFixForMove
    /// "Move to my location" with location access off.
    case deniedForMove

    /// (SwiftUI text: “long-press” carries a non-breaking hyphen, U+2011,
    /// so it never breaks across lines.)
    var message: String {
        switch self {
        case .denied: "Location access is off for IzzyMap. You can turn it on in Settings."
        case .noFix: "No location fix — the map still works. Wi-Fi-only iPads have no GPS."
        case .noFixForPin: "No location yet — long\u{2011}press the map to place a pin there."
        case .waitingForPin: "Waiting for a location fix — or long\u{2011}press the map to place a pin."
        case .deniedForPin: "Location access is off for IzzyMap — long\u{2011}press the map to place a pin, or turn it on in Settings."
        case .noFixForMove: "No location yet — use Move on map instead."
        case .deniedForMove: "Location access is off for IzzyMap — use Move on map, or turn it on in Settings."
        }
    }

    var symbol: String {
        switch self {
        case .denied, .deniedForPin, .deniedForMove: "location.slash"
        case .noFix, .noFixForPin, .waitingForPin, .noFixForMove: "location.magnifyingglass"
        }
    }

    /// Raised by the pin button or "Move to my location" (a fix arriving
    /// makes it moot).
    var isPinNotice: Bool { [.noFixForPin, .waitingForPin, .deniedForPin, .noFixForMove, .deniedForMove].contains(self) }

    /// The banner offers "Open Settings".
    var offersSettings: Bool { self == .denied || self == .deniedForPin || self == .deniedForMove }
}
