import Foundation
import Testing
@testable import IzzyMap

/// The pack table (mirrors pipeline/asset_packs.json; build_packs.py checks
/// the other direction) and the store's non-Background-Assets modes.
@MainActor
struct PackTests {
    @Test func everyArchiveIsInExactlyOnePack() {
        for archive in Archive.allCases {
            #expect(Pack.allCases.filter { $0.archives.contains(archive) }.count == 1, "\(archive)")
            #expect(archive.pack.archives.contains(archive))
        }
    }

    @Test func idsAndPoliciesMatchThePlan() {
        #expect(Pack.vector.archives == [.tasveg, .geology, .pre1750])
        #expect(Pack.vector.policy == .essential)
        #expect([Pack.topo, .relief, .plantid].allSatisfy { $0.policy == .prefetch })
        #expect([Pack.aerial, .tasmap].allSatisfy { $0.policy == .onDemand })
        // one season pack per season, id "season-YYYY" like the style source
        for season in Season.all {
            #expect(season.archive.pack.rawValue == season.sourceID)
            #expect(season.archive.pack.policy == .onDemand)
        }
        #expect(Pack.allCases.filter(\.isRemovable).count == 9)
    }

    @Test func fileNamesAreUniqueInTheSharedNamespace() {
        let names = Archive.allCases.map(\.fileName)
        #expect(Set(names).count == names.count)
    }

    @Test func aFixedStoreReportsWhatItHolds() {
        let store = PackStore(fixed: StyleBuilderTests.location([.tasveg, .geology, .pre1750, .season2021]))
        #expect(store.mode == .fixed)
        #expect(store.state(.vector) == .installed)
        #expect(store.state(.season2021) == .installed)
        #expect(store.state(.topo) == .notInstalled)
        // plant ID has no map archives: never "installed" from a directory
        #expect(store.state(.plantid) == .notInstalled)
        // fetch/remove are Background Assets only
        store.fetch(.aerial)
        #expect(store.state(.aerial) == .notInstalled)
    }

    @Test func aPartialVectorPackIsNotInstalled() {
        let store = PackStore(fixed: StyleBuilderTests.location([.tasveg]))
        #expect(store.state(.vector) == .notInstalled)
        #expect(store.location.url(for: .tasveg) != nil)
    }

    @Test func modelsReadTheStoresArchives() {
        let model = AppModel(data: StyleBuilderTests.location([.topo]), tables: StyleBuilderTests.tables)
        #expect(model.data.url(for: .topo) != nil)
        #expect(model.data.url(for: .tasveg) == nil)
    }
}
