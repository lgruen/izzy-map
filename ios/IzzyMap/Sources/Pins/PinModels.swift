import Foundation
import SwiftData

// The pin records (docs/PINS_PLAN.md §3). Written to CloudKit's rules from
// the first build, although this one keeps the store local: every stored
// property has a default or is optional, no unique constraints, every
// relationship optional with exactly one explicit inverse, no Deny delete
// rule (the one rule Core Data + CloudKit forbids; cascade is allowed),
// enums stored as strings. A project nullifies its pins (deleting one for
// good deletes the pins that went with it by hand); a pin cascades to its
// photos and a photo to its original, so an original is never orphaned.
// The property NAMES become a permanent cloud schema once deployed — a CloudKit schema
// only grows: never rename or remove one. Photos (slice 3) were added as
// new entities and one new optional relationship: a lightweight migration
// opens a slice-2 store as it is (`PinMigrationTests`).

/// A work site: its pins share its colour unless they choose their own.
@Model
nonisolated final class PinProject {
    var id: UUID = UUID()
    var name: String = ""
    /// A `PinColour` NAME (unknown names draw grey).
    var colour: String = PinColour.standard.rawValue
    var note: String = ""
    var createdAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    /// Archived projects' pins leave the map.
    var archivedAt: Date?
    /// Soft delete: restorable for 30 days, then purged (with its pins).
    var deletedAt: Date?
    @Relationship(deleteRule: .nullify, inverse: \SavedPin.project)
    var pins: [SavedPin]? = []

    init(name: String, colour: String, note: String = "", now: Date) {
        id = UUID()
        self.name = name
        self.colour = colour
        self.note = note
        createdAt = now
        modifiedAt = now
    }
}

/// A saved point on the map.
@Model
nonisolated final class SavedPin {
    var id: UUID = UUID()
    /// nil = "Unfiled".
    var project: PinProject?
    /// WGS84 degrees.
    var lat: Double = 0
    var lon: Double = 0
    var title: String = ""
    var note: String = ""
    /// A `PinColour` NAME overriding the project's; nil = the project's.
    var colour: String?
    var createdAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    /// Soft delete: off the map, restorable for 30 days, then purged.
    var deletedAt: Date?
    /// `Placement` raw value: "gps" or "map".
    var placedBy: String = Placement.map.rawValue
    /// Horizontal accuracy of the GPS fix, metres (gps only).
    var accuracy: Double?
    /// Altitude above sea level, metres, when the fix had a vertical one.
    var altitude: Double?
    /// Its photos (any order; `sort` orders them). They have no soft delete
    /// of their own: they leave and come back with the pin, and go (with
    /// their originals, by cascade) when the pin is deleted for good.
    @Relationship(deleteRule: .cascade, inverse: \PinPhoto.pin)
    var photos: [PinPhoto]? = []

    init(lat: Double, lon: Double, placedBy: Placement, accuracy: Double? = nil, altitude: Double? = nil,
         project: PinProject?, now: Date) {
        id = UUID()
        self.lat = lat
        self.lon = lon
        self.placedBy = placedBy.rawValue
        self.accuracy = accuracy
        self.altitude = altitude
        self.project = project
        createdAt = now
        modifiedAt = now
    }

    nonisolated enum Placement: String, Sendable {
        /// At the device's location (accuracy and altitude recorded).
        case gps
        /// By hand: a long-press on the map, or moved there.
        case map
    }

    var placement: Placement { Placement(rawValue: placedBy) ?? .map }

    /// The colour name to draw: its own, else its project's, else the standard.
    var effectiveColourName: String {
        colour ?? project?.colour ?? PinColour.standard.rawValue
    }

    /// Drawn on the map: not deleted, and not in a deleted or archived project.
    var isOnMap: Bool {
        guard deletedAt == nil else { return false }
        guard let project else { return true }
        return project.deletedAt == nil && project.archivedAt == nil
    }

    /// Its photos, newest first (the order of the card's strip and the viewer).
    var sortedPhotos: [PinPhoto] {
        (photos ?? []).sorted { ($0.sort, $0.createdAt) > ($1.sort, $1.createdAt) }
    }
}

/// A photo of a pin (docs/PINS_PLAN.md §3). The row holds what lists and
/// the card's strip need — a small JPEG and the facts — so they never read
/// a full image; the full image is a `PinPhotoOriginal` of its own, read
/// only when the photo is opened (external-storage attributes have been
/// reported loading with their owner).
@Model
nonisolated final class PinPhoto {
    var id: UUID = UUID()
    var pin: SavedPin?
    /// JPEG, about 400 px on its short side, uncropped (the strip crops it
    /// square; the viewer shows it at the photo's own aspect until the
    /// original is decoded). Stored inline.
    var thumbnail: Data?
    var caption: String = ""
    /// Order within the pin: a new photo gets one more than the highest.
    var sort: Int = 0
    /// When the photo was taken (its EXIF capture date), else when it was added.
    var createdAt: Date = Date.distantPast
    /// The original's pixel size, upright.
    var width: Int = 0
    var height: Int = 0
    /// The original's size in bytes.
    var bytes: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \PinPhotoOriginal.photo)
    var original: PinPhotoOriginal?

    init(thumbnail: Data, caption: String = "", sort: Int, createdAt: Date, width: Int, height: Int, bytes: Int) {
        id = UUID()
        self.thumbnail = thumbnail
        self.caption = caption
        self.sort = sort
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// A photo's full image: HEIC from the camera, the library's own HEIC or
/// JPEG bytes, else HEIC (`PinPhotoPipeline`). Kept beside the store
/// (`.externalStorage`).
@Model
nonisolated final class PinPhotoOriginal {
    var photo: PinPhoto?
    @Attribute(.externalStorage) var data: Data?

    init(data: Data) {
        self.data = data
    }
}
