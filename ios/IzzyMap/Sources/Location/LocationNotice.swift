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

    var message: String {
        switch self {
        case .denied: "Location access is off for IzzyMap. You can turn it on in Settings."
        case .noFix: "No location fix — the map still works. Wi-Fi-only iPads have no GPS."
        case .noFixForPin: "No location yet — long-press the map to place a pin there."
        }
    }

    var symbol: String {
        switch self {
        case .denied: "location.slash"
        case .noFix, .noFixForPin: "location.magnifyingglass"
        }
    }
}
