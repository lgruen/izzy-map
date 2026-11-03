/// A short, honest message about location, shown as a banner.
nonisolated enum LocationNotice: Equatable, Sendable {
    /// Location access is off for IzzyMap (offers a Settings link).
    case denied
    /// Following, but no position yet. Not an error: Wi-Fi-only iPads have
    /// no GPS, and a fix can take a while outdoors.
    case noFix

    var message: String {
        switch self {
        case .denied: "Location access is off for IzzyMap. You can turn it on in Settings."
        case .noFix: "No location fix — the map still works. Wi-Fi-only iPads have no GPS."
        }
    }

    var symbol: String {
        switch self {
        case .denied: "location.slash"
        case .noFix: "location.magnifyingglass"
        }
    }
}
