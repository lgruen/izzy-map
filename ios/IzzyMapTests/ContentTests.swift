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

@MainActor
struct ModalEscapeTests {
    /// Escape inside a modal pops one of its levels (Storage → Layers),
    /// then closes it; a new modal starts at its root.
    @Test func escapePopsInsideTheModalBeforeClosingIt() {
        let model = AppModel(data: .none, tables: CardStackTests.tables)
        model.present(.layers)
        #expect(model.escapeStep == .dismiss(.layers))
        model.modalDepth = 2  // Key, then Storage (the sheet reports it)
        #expect(model.escapeStep == .modalBack)
        #expect(model.escapeStep?.title == "Back")
        let before = model.modalPopRequest
        model.escape()
        #expect(model.modalPopRequest == before + 1)  // the sheet pops
        #expect(model.modal != nil)
        model.modalDepth = 0
        model.escape()
        #expect(model.modal == nil)
        model.modalDepth = 1
        model.present(.plantID)
        #expect(model.modalDepth == 0)
        #expect(model.escapeStep == .dismiss(.plantID))
    }
}
