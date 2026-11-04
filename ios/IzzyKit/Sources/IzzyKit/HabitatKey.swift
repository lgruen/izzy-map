import Foundation

/// The plant sheet's habitat key boxes (docs/DESIGN.md "Habitat key boxes",
/// decided by the user 2026-11-04): each of the Understorey Network's 11
/// habitat classes gets a key box in the colour the map gives the matching
/// TASVEG community group, so "Wet Eucalypt Forest" on a plant reads as the
/// teal she sees on the map.
///
/// Derived from the bundled data (2026-11-04; `HabitatKeyTests` re-derives
/// it and fails if the data stops supporting a row):
/// - **Group:** for every class, the ALA site records of the plants carrying
///   it (records.json C1, inside each TASVEG code) summed per VEG_GROUP and
///   compared with the same sum over every plant that has a habitat — the
///   group's *lift*. A class maps to the group its name and ecology point to
///   (Heath → "Scrub, heathland…", Coastal → "…coastal complexes", Alpine →
///   "Highland treeless") when the records confirm it: that group is in the
///   class's top two at lift ≥ 1.4 (clearly over-represented). Lifts: Alpine 5.3 Highland treeless · Aquatic 33
///   Saltmarsh and wetland (freshwater aquatic herbland; n is small) ·
///   Coastal 1.7 · Dry eucalypt 1.49 (the weakest; the F2F named lists give
///   1.8) · Grassland 3.6 · Heath 2.1 (Moorland
///   2.8 first: buttongrass shares heath species) · Rainforest 3.4 ·
///   Saltmarsh 33 · Sedgeland and Wetland 6.9 (Moorland, sedgeland 5.0
///   second) · Wet eucalypt 1.7.
/// - **Colour:** the official fill of one named community of that group —
///   the code with the highest lift for the class when it is a namesake
///   (DAM, GTL, RMT, WRE, SSC coastal scrub, ASS, ASF, AHF), else the
///   group's largest fill by area (SHW wet heathland for Heath; Highland
///   treeless has one fill). Full strength, like the card's swatch: it names
///   a unit, it doesn't match a blended map.
/// - **Riparian has no TASVEG group:** no group is named for it and none
///   stands out — its best lift is 1.46, Modified land (streamsides cut
///   across every group, and get cleared) — so its box is hatched
///   ink, the printed-key sign for "no fill of its own".
///
/// The three wet classes (Aquatic, Saltmarsh, Sedgeland and Wetland) share
/// one blue because TASVEG draws them in one: honest, and the labels differ.
public enum HabitatKey {
    public struct Entry: Sendable, Hashable {
        /// The UN habitat class, verbatim ("Wet Eucalypt Forest").
        public let habitat: String
        /// The TASVEG VEG_GROUP it maps to; nil = no group fits (hatched box).
        public let group: String?
        /// The community whose official fill the box takes.
        public let code: String?
        /// That fill, "#rrggbb" (nil with `group`).
        public let hex: String?

        public var isHatched: Bool { hex == nil }

        /// VoiceOver: what the box says without its colour.
        public var spoken: String {
            guard let group else { return "\(habitat), no TASVEG group of its own" }
            return "\(habitat), coloured as the map's \(group.lowercased())"
        }
    }

    public static let entries: [Entry] = [
        Entry(habitat: "Alpine and Sub-alpine Vegetation", group: "Highland treeless vegetation", code: "HHE", hex: "#fe98fe"),
        Entry(habitat: "Aquatic", group: "Saltmarsh and wetland", code: "AHF", hex: "#65cbfe"),
        Entry(habitat: "Coastal Vegetation", group: "Scrub, heathland and coastal complexes", code: "SSC", hex: "#cb6532"),
        Entry(habitat: "Dry Eucalypt Forest", group: "Dry eucalypt forest and woodland", code: "DAM", hex: "#98fe00"),
        Entry(habitat: "Grassland", group: "Native grassland", code: "GTL", hex: "#e7ff00"),
        Entry(habitat: "Heath", group: "Scrub, heathland and coastal complexes", code: "SHW", hex: "#fe9898"),
        Entry(habitat: "Rainforest", group: "Rainforest and related scrub", code: "RMT", hex: "#0065cb"),
        Entry(habitat: "Riparian", group: nil, code: nil, hex: nil),
        Entry(habitat: "Saltmarsh", group: "Saltmarsh and wetland", code: "ASS", hex: "#65cbfe"),
        Entry(habitat: "Sedgeland and Wetland", group: "Saltmarsh and wetland", code: "ASF", hex: "#65cbfe"),
        Entry(habitat: "Wet Eucalypt Forest", group: "Wet eucalypt forest and woodland", code: "WRE", hex: "#00cbcb"),
    ]

    private static let byHabitat = Dictionary(uniqueKeysWithValues: entries.map { ($0.habitat, $0) })

    /// The key box for a habitat class; an unknown class (UN added one) gets
    /// a hatched box under its own name rather than a guessed colour.
    public static func entry(_ habitat: String) -> Entry {
        byHabitat[habitat] ?? Entry(habitat: habitat, group: nil, code: nil, hex: nil)
    }

    /// Whether the table knows this class (the tests' tripwire for new UN classes).
    public static func knows(_ habitat: String) -> Bool { byHabitat[habitat] != nil }
}
