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

    var message: String {
        switch self {
        case .denied: "Location access is off for IzzyMap. You can turn it on in Settings."
        case .noFix: "No location fix — the map still works. Wi-Fi-only iPads have no GPS."
        case .noFixForPin: "No location yet — long-press the map to place a pin there."
        case .waitingForPin: "Waiting for a location fix — or long-press the map to place a pin."
        case .deniedForPin: "Location access is off for IzzyMap — long-press the map to place a pin, or turn it on in Settings."
        }
    }

    var symbol: String {
        switch self {
        case .denied, .deniedForPin: "location.slash"
        case .noFix, .noFixForPin, .waitingForPin: "location.magnifyingglass"
        }
    }

    /// Raised by the pin button (its fix arriving makes it moot).
    var isPinNotice: Bool { self == .noFixForPin || self == .waitingForPin || self == .deniedForPin }

    /// The banner offers "Open Settings".
    var offersSettings: Bool { self == .denied || self == .deniedForPin }
}
