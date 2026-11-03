import Foundation

/// The plant data indexed for a TASVEG card's three lists (B named, C1 often recorded, C2 nearby).
public struct PlantCatalog: Sendable {
    /// One list entry: a species key and the UN profile shown for it.
    public struct Entry: Sendable, Hashable {
        public var key: String
        /// The profile to show (for a group: the member lending its thumbnail).
        public var plant: Plant
        /// Recorded sites (C1/C2 lists).
        public var sites: Int?
        /// Set when this B entry is a broad-sense group.
        public var group: Group?
    }
    /// A broad-sense name F2F uses for what UN splits into several species.
    public struct Group: Sendable, Hashable {
        public var key: String
        public var common: String?
        /// Species in the group, profiled or not.
        public var size: Int
        /// Members with a UN profile.
        public var members: [Entry]
    }
    /// C1 for one community.
    public struct Often: Sendable, Hashable {
        public var entries: [Entry]
        /// Few records: a plain tally by sites, not an indicator ranking ("few records").
        public var isTally: Bool
        /// Total recorded sites in the community, if known.
        public var sites: Int?
    }
    /// C2 around a point.
    public struct Nearby: Sendable, Hashable {
        /// Profiled species, most sites first (ties A–Z).
        public var entries: [Entry]
        /// Species key → summed sites, every species incl. those without a profile.
        public var sites: [String: Int]
        /// Σ sites over the window.
        public var total: Int
        /// Σ sites over the entries shown.
        public var shownTotal: Int
    }

    public let plants: [Plant]
    public let records: RecordsFile
    public let grid: NearbyGrid
    let named: [String: [String]]
    let groups: [String: PlantsFile.Group]
    /// species key → the profile to show
    let profile: [String: Plant]

    public init(plants file: PlantsFile, records: RecordsFile, grid: NearbyGrid) {
        plants = file.plants
        self.records = records
        self.grid = grid
        named = file.communities
        groups = file.groups ?? [:]
        var byKey: [String: [Plant]] = [:]
        for p in file.plants { if let s = p.species { byKey[s, default: []].append(p) } }
        // one with photos (the species' own record first), else the
        // species' own record, else the first
        profile = byKey.mapValues { (list: [Plant]) -> Plant in
            let key = list[0].species!
            let withPhotos = list.filter { !$0.photos.isEmpty }
            return withPhotos.first { $0.name == key } ?? withPhotos.first
                ?? list.first { $0.name == key } ?? list[0]
        }
    }

    /// The profile shown for a species key (nil: no UN profile — such keys are skipped in lists).
    public func plant(for key: String) -> Plant? { profile[key] }

    private func entry(_ key: String, sites: Int? = nil) -> Entry? {
        profile[key].map { Entry(key: key, plant: $0, sites: sites, group: nil) }
    }
    private func speciesKey(_ i: Int) -> String? {
        records.species.indices.contains(i) ? records.species[i] : nil
    }

    /// B: species named in the community's F2F account, in order of mention.
    public func named(_ code: String) -> [Entry] {
        (named[code] ?? []).compactMap { k in
            guard let g = groups[k] else { return entry(k) }
            let members = g.species.compactMap { entry($0) }
            guard let face = members.first(where: { !$0.plant.photos.isEmpty }) ?? members.first else { return nil }
            return Entry(key: k, plant: face.plant, sites: nil,
                         group: Group(key: k, common: g.common, size: g.species.count, members: members))
        }
    }

    /// C1: species ALA records put inside this community, best first.
    public func often(_ code: String) -> Often {
        let rows = records.communities[code] ?? []
        return Often(
            entries: rows.compactMap { r in speciesKey(r.species).flatMap { entry($0, sites: r.sites) } },
            isTally: !rows.isEmpty && rows.allSatisfy { $0.score == nil },
            sites: records.sites?[code])
    }

    /// Species key → recorded sites inside this community: every C1 species,
    /// plus group members' full counts (the C1 list is capped at 40).
    public func communitySites(_ code: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in records.communities[code] ?? [] { if let k = speciesKey(r.species) { out[k] = r.sites } }
        for r in records.members?[code] ?? [] { if let k = speciesKey(r.species) { out[k] = r.sites } }
        return out
    }

    /// C2: the point's 0.01° cell + 8 neighbours, summed per species.
    public func nearby(latitude: Double, longitude: Double) -> Nearby {
        let raw = grid.sitesAround(latitude: latitude, longitude: longitude, grid: records.grid)
        var sites: [String: Int] = [:]
        var total = 0
        for (i, n) in raw {
            guard let k = speciesKey(i) else { continue }
            sites[k] = n
            total += n
        }
        let en = Locale(identifier: "en")
        let entries = sites.sorted {
            $0.value != $1.value ? $0.value > $1.value
                : $0.key.compare($1.key, locale: en) == .orderedAscending
        }.compactMap { entry($0.key, sites: $0.value) }
        return Nearby(entries: entries, sites: sites, total: total,
                      shownTotal: entries.reduce(0) { $0 + ($1.sites ?? 0) })
    }
}
