import Foundation

/// A camera as persisted between launches.
nonisolated struct SavedCamera: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var zoom: Double
    var heading: Double = 0
}

/// Where the map may look, and where it opens.
nonisolated enum CameraPolicy {
    /// Tasmania incl. the Bass Strait islands, with room to pan (as the web app).
    static let minLongitude = 140.0, maxLongitude = 152.0
    static let minLatitude = -46.5, maxLatitude = -37.5
    static let minZoom = 5.0, maxZoom = 19.0
    /// Statewide view when there is neither a fix nor a saved camera.
    static let home = SavedCamera(latitude: -42.2, longitude: 146.6, zoom: 7)
    /// Zoom to open at on a GPS fix when no closer saved camera exists.
    static let fixZoom = 13.0

    static func contains(latitude: Double, longitude: Double) -> Bool {
        (minLatitude...maxLatitude).contains(latitude) && (minLongitude...maxLongitude).contains(longitude)
    }

    /// The camera to open with before any fix arrives: the saved one if it is
    /// sane and inside the bounds, else statewide.
    static func initial(saved: SavedCamera?) -> SavedCamera {
        guard let saved, saved.zoom.isFinite, saved.heading.isFinite,
              contains(latitude: saved.latitude, longitude: saved.longitude)
        else { return home }
        var camera = saved
        camera.zoom = min(max(saved.zoom, minZoom), maxZoom)
        return camera
    }
}

/// The last camera, kept in UserDefaults (a few bytes of user state).
struct CameraStore {
    var defaults: UserDefaults = .standard
    static let key = "lastCamera"

    func load() -> SavedCamera? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SavedCamera.self, from: $0) }
    }

    func save(_ camera: SavedCamera) {
        if let data = try? JSONEncoder().encode(camera) { defaults.set(data, forKey: Self.key) }
    }
}
