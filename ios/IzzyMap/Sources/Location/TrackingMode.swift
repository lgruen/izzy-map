/// The Location button's three states, cycled by tapping (as in Maps).
nonisolated enum TrackingMode: CaseIterable, Sendable {
    case off, follow, followWithHeading

    var next: TrackingMode {
        switch self {
        case .off: .follow
        case .follow: .followWithHeading
        case .followWithHeading: .off
        }
    }

    var symbol: String {
        switch self {
        case .off: "location"
        case .follow: "location.fill"
        case .followWithHeading: "location.north.line.fill"
        }
    }

    /// VoiceOver value of the Location button.
    var spokenState: String {
        switch self {
        case .off: "Not following"
        case .follow: "Following your location"
        case .followWithHeading: "Following your location and heading"
        }
    }
}
