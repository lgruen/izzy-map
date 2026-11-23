import Foundation
import SwiftData

// The pin records (docs/PINS_PLAN.md §3). Written to CloudKit's rules from
// the first build, although this one keeps the store local: every stored
// property has a default or is optional, no unique constraints, every
// relationship optional with an explicit inverse, deletes nullify (CloudKit
// can't enforce deny or cascade), enums stored as strings. The property
// NAMES become a permanent cloud schema once deployed — a CloudKit schema
// only grows: never rename or remove one. Photos come with milestone 2.

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
}
