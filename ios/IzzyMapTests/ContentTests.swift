import CoreLocation
import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

@MainActor
struct CardStackTests {
    static let tables: MapTables = {
        var t = MapTables()
        t.communities = (try? BundledData.inBundle()?.communities()) ?? [:]
        return t
    }()

    @Test func pushNeverRepeatsAndANewTapDropsTheStack() {
        let model = AppModel(data: .none, tables: Self.tables)
        let ctx = PlantContext(code: "DOB", latitude: -42.9, longitude: 147.2)
        let route = CardRoute.plant(id: 1, key: "A b", context: ctx, source: "x")
        model.push(route)
        #expect(model.cardPath.isEmpty)  // no card, nothing to push over
        model.selectCommunity(code: "DOB", sourceName: nil, at: CLLocationCoordinate2D(latitude: -42.9, longitude: 147.2))
        if case let .community(c) = model.selection?.feature {
            #expect(c.latitude == -42.9 && c.longitude == 147.2)
        } else {
            Issue.record("no community")
        }
        model.push(.group(key: "G", context: ctx))
        model.push(route)
        model.push(route)  // a double tap
        #expect(model.cardPath.count == 2)
        // Escape: back one level, then the card
        #expect(model.escapeStep == .back)
        model.escape()
        #expect(model.cardPath.count == 1)
        model.escape()
        #expect(model.escapeStep == .closeCard)
        model.push(route)
        model.selectCommunity(code: "DAM", sourceName: nil)
        #expect(model.cardPath.isEmpty)
        model.push(route)
        model.clearSelection()
        #expect(model.cardPath.isEmpty)
    }
}
