import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

/// First launch (docs/DESIGN.md §3 "States"): the "Maps arriving" chip, the
/// one-time welcome, and the calm coastline while topo isn't here offline.
@MainActor
struct FirstLaunchTests {
    private func states(_ pairs: [Pack: PackState]) -> [Pack: PackState] {
        var s = Dictionary(uniqueKeysWithValues: Pack.allCases.map { ($0, PackState.notInstalled) })
        for (k, v) in pairs { s[k] = v }
        return s
    }

    private let sizes: [Pack: Int] = [.vector: 400, .topo: 2000, .relief: 1300, .plantid: 700]

    @Test func nothingToSayWhenTheCorePacksAreHere() {
        let all = states([.vector: .installed, .topo: .installed, .relief: .installed, .plantid: .installed])
        #expect(CoreArrival.of(states: all, sizes: sizes, resolved: true, canFetch: true, online: true) == nil)
        // on-demand packs never raise the chip
        var more = all
        more[.aerial] = .downloading(0.3)
        #expect(CoreArrival.of(states: more, sizes: sizes, resolved: true, canFetch: true, online: true) == nil)
    }

    @Test func nothingToSayBeforeThePacksAreKnownOrWithoutAFetcher() {
        let none = states([:])
        #expect(CoreArrival.of(states: none, sizes: sizes, resolved: false, canFetch: true, online: true) == nil)
        #expect(CoreArrival.of(states: none, sizes: sizes, resolved: true, canFetch: false, online: true) == nil)
    }

    /// The fraction is bytes-weighted over all core packs; installed ones
    /// count whole (vector 400 + half of topo's 2000 of 4400 = 31 %).
    @Test func arrivingIsWeightedByBytes() throws {
        let s = states([.vector: .installed, .topo: .downloading(0.5)])
        let a = try #require(CoreArrival.of(states: s, sizes: sizes, resolved: true, canFetch: true, online: true))
        guard case let .arriving(f) = a.phase else { Issue.record("\(a.phase)"); return }
        #expect(abs(f - 1400.0 / 4400) < 1e-9)
        #expect(a.text == "Maps arriving · 31\u{00A0}%")
        #expect(a.missing == [.topo, .relief, .plantid])
        #expect(a.spoken.hasPrefix("The topographic map, relief shading"))
    }

    @Test func waitingAndFailedSayWhatToDo() throws {
        let paused = states([.vector: .installed, .topo: .paused])
        let offline = try #require(CoreArrival.of(states: paused, sizes: sizes, resolved: true, canFetch: true, online: false))
        #expect(offline.phase == .waiting(offline: true))
        #expect(offline.text == "Maps arrive when online")
        let byIOS = try #require(CoreArrival.of(states: paused, sizes: sizes, resolved: true, canFetch: true, online: true))
        #expect(byIOS.phase == .waiting(offline: false))
        let failed = try #require(CoreArrival.of(states: states([.vector: .installed, .topo: .failed("x")]),
                                                 sizes: sizes, resolved: true, canFetch: true, online: true))
        #expect(failed.phase == .failed)
        #expect(failed.text.hasSuffix("Retry"))
        // only the plant ID model missing: it says so, not "Maps"
        let model = try #require(CoreArrival.of(states: states([.vector: .installed, .topo: .installed, .relief: .installed,
                                                                .plantid: .downloading(0.5)]),
                                                sizes: sizes, resolved: true, canFetch: true, online: true))
        #expect(model.text.hasPrefix("Plant ID arriving"))
        // something still moving wins over a failure elsewhere
        let mixed = states([.vector: .installed, .topo: .failed("x"), .relief: .downloading(nil)])
        #expect(CoreArrival.of(states: mixed, sizes: sizes, resolved: true, canFetch: true, online: true)?.phase
            == .arriving(400.0 / 4400))
    }

    /// Seen once: OK, opening Layers or Identify, or a map tap dismiss it
    /// and it stays dismissed for every later window and launch.
    @Test func theWelcomeShowsOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "izzy-welcome-\(UUID().uuidString)"))
        let store = WelcomeStore(defaults: defaults)
        let tables = StyleBuilderTests.bundled
        let model = AppModel(data: StyleBuilderTests.both, tables: tables, welcome: store)
        #expect(model.showsWelcome)
        model.present(.layers)
        #expect(!model.showsWelcome && store.seen)
        #expect(!AppModel(data: StyleBuilderTests.both, tables: tables, welcome: store).showsWelcome)

        let fresh = WelcomeStore(defaults: try #require(UserDefaults(suiteName: "izzy-welcome-\(UUID().uuidString)")))
        let tapped = AppModel(data: StyleBuilderTests.both, tables: tables, welcome: fresh)
        tapped.selectCommunity(code: "DOB", sourceName: nil)
        #expect(!tapped.showsWelcome && fresh.seen)
    }

    /// Offline without the topo pack: a grey coast hairline to z9 under
    /// everything; never when topo is local or can stream.
    @Test func theCoastStandsInForTopoOffline() throws {
        var tables = StyleBuilderTests.bundled
        tables.outline = try #require(try BundledData.inBundle()?.tasmaniaOutline())
        let vectorOnly = StyleBuilderTests.location([.tasveg])
        let offline = StyleBuilder.style(state: .default, data: vectorOnly, tables: tables, online: false)
        let ids = (offline["layers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(ids.prefix(2) == ["bg", "coast"])
        let coast = try #require((offline["layers"] as? [[String: Any]])?.first { $0["id"] as? String == "coast" })
        #expect(coast["maxzoom"] as? Double == 9.5)
        for (data, online) in [(vectorOnly, true), (StyleBuilderTests.both, false)] {
            let s = StyleBuilder.style(state: .default, data: data, tables: tables, online: online)
            #expect(!((s["layers"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == "coast" }))
        }
    }
}
