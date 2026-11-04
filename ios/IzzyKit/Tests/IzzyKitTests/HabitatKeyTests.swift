import Foundation
import Testing
@testable import IzzyKit

/// The habitat key boxes re-derived from the bundled data (HabitatKey's doc
/// comment): a UN re-classing, a records rebuild or a TASVEG colour change
/// that stops supporting a row fails here, not on her plant sheet.
struct HabitatKeyTests {
    /// Every class UN uses has a row (a new class would get a hatched box
    /// under its own name — say so here first).
    @Test func everyBundledHabitatHasARow() throws {
        let plants = try TestData.data.plants().plants
        let used = Set(plants.flatMap(\.habitats))
        #expect(used.count == 11)
        for h in used { #expect(HabitatKey.knows(h), "new UN habitat class \(h)") }
        #expect(Set(HabitatKey.entries.map(\.habitat)) == used)
    }

    /// Each colour is the official fill of a community of that group.
    @Test func coloursAreOfficialFillsOfTheGroup() throws {
        let table = try TestData.data.communities()
        for e in HabitatKey.entries {
            guard let code = e.code else {
                #expect(e.group == nil && e.hex == nil && e.isHatched)
                continue
            }
            let c = try #require(table[code], "\(code) not in TASVEG")
            #expect(c.group == e.group, "\(code) is \(c.group), not \(e.group ?? "-")")
            #expect(c.color.lowercased() == e.hex, "\(code)'s fill is \(c.color)")
        }
        // an unknown class: hatched, never a guessed colour
        #expect(HabitatKey.entry("Moonscape").isHatched)
    }

    /// The group choice is what the records say: the mapped group is in the
    /// class's top two by lift, at ≥ 1.4 (clearly over-represented);
    /// Riparian, with no namesake group, has no group standing out (< 1.5).
    @Test func groupsFollowTheRecords() throws {
        let data = TestData.data
        let plants = try data.plants().plants
        let records = try data.records()
        let table = try data.communities()
        var habitats: [String: Set<String>] = [:]
        for p in plants { if let s = p.species { habitats[s, default: []].formUnion(p.habitats) } }
        var byClass: [String: [String: Double]] = [:]   // class → group → sites
        var all: [String: Double] = [:]
        for (code, rows) in records.communities {
            guard let group = table[code]?.group else { continue }
            for r in rows {
                guard let hs = habitats[records.species[r.species]], !hs.isEmpty else { continue }
                all[group, default: 0] += Double(r.sites)
                for h in hs { byClass[h, default: [:]][group, default: 0] += Double(r.sites) }
            }
        }
        let total = all.values.reduce(0, +)
        for e in HabitatKey.entries {
            let groups = try #require(byClass[e.habitat])
            let n = groups.values.reduce(0, +)
            let lifts = groups.map { g, v in (g, (v / n) / ((all[g] ?? 1) / total)) }.sorted { $0.1 > $1.1 }
            if let group = e.group {
                let rank = try #require(lifts.firstIndex { $0.0 == group }, "\(e.habitat): no records in \(group)")
                #expect(rank < 2, "\(e.habitat): \(group) ranks \(rank + 1)")
                #expect(lifts[rank].1 >= 1.4, "\(e.habitat): lift \(lifts[rank].1)")
            } else {
                #expect(lifts[0].1 < 1.5, "\(e.habitat) now has a group: \(lifts[0])")
            }
        }
    }
}
