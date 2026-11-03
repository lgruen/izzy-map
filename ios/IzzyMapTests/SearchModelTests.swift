import Foundation
import IzzyKit
import Testing
@testable import IzzyMap

/// The search panel's view model over the real bundled index (the test host
/// is the app, so `Data/search/` is in its bundle).
@MainActor
struct SearchModelTests {
    static let hobart = GeoPoint(longitude: 147.33, latitude: -42.88)
    static let launceston = GeoPoint(longitude: 147.14, latitude: -41.44)

    /// A model whose index is ready (loaded once per process).
    private func model(near: GeoPoint? = hobart) async throws -> SearchModel {
        let index = try await SearchIndexStore.shared.get()
        let m = SearchModel(store: SearchIndexStore(index: index))
        m.near = { near }
        return m
    }

    @Test func resultsFollowEveryKeystroke() async throws {
        let m = try await model()
        m.begin()
        #expect(m.status == .ready)
        m.query = "s"
        #expect(m.results.isEmpty) // one letter answers nothing
        m.query = "salamanca"
        #expect(m.results.first?.name.hasPrefix("Salamanca") == true)
        #expect(m.results.contains { $0.name == "Salamanca Place" })
        m.query = "7 mile beach"
        #expect(m.results.first?.name == "Seven Mile Beach")
    }

    @Test func returnPicksTheFirstRowOfTheCurrentText() async throws {
        let m = try await model()
        var picks = 0
        m.onPick = { picks += 1 }
        m.begin()
        m.query = "salamanca"
        m.query = "7 mile beach"
        m.submit()
        #expect(m.pin?.result.name == "Seven Mile Beach")
        #expect(m.pin?.flight == 1)
        #expect(!m.isActive)
        #expect(picks == 1)
        #expect(m.query == "7 mile beach") // kept for reopening
    }

    @Test func arrowsMoveTheHighlightAndReturnPicksIt() async throws {
        let m = try await model()
        m.begin()
        m.query = "salamanca"
        let second = m.results[1]
        m.moveHighlight(1)
        #expect(m.highlighted == 0)
        m.moveHighlight(1)
        #expect(m.highlighted == 1)
        m.moveHighlight(-5)
        #expect(m.highlighted == 0) // clamped at the top
        m.moveHighlight(1)
        m.submit()
        #expect(m.pin?.result.id == second.id)
    }

    @Test func typingResetsTheHighlight() async throws {
        let m = try await model()
        m.begin()
        m.query = "salamanca"
        m.moveHighlight(1)
        m.moveHighlight(1)
        m.query = "salamanca p"
        #expect(m.highlighted == nil)
    }

    @Test func reopeningRestoresTheQueryWithFreshDistances() async throws {
        var centre = Self.hobart
        let m = try await model()
        m.near = { centre }
        m.begin()
        m.query = "elizabeth street"
        m.submit()
        let fromHobart = try #require(m.results.first)
        centre = Self.launceston
        m.begin()
        #expect(m.isActive)
        #expect(m.query == "elizabeth street")
        let fromLaunceston = try #require(m.results.first)
        // equal names rank by distance: the nearest Elizabeth Street changes
        #expect(fromHobart.meta != fromLaunceston.meta)
        #expect((fromLaunceston.distanceKm ?? 99) < 5)
    }

    @Test func chipReflyBumpsTheFlightAndClearRemovesThePin() async throws {
        let m = try await model()
        m.begin()
        m.query = "salamanca"
        m.submit()
        m.refly()
        #expect(m.pin?.flight == 2)
        m.clearPin()
        #expect(m.pin == nil)
        m.refly() // nothing to fly to
        #expect(m.pin == nil)
    }

    @Test func recentsAreUniqueNewestFirstAndCapped() async throws {
        let m = try await model()
        for q in ["salamanca", "7 mile beach", "salamanca"] {
            m.begin()
            m.query = q
            m.submit()
        }
        #expect(m.recents.map(\.name).prefix(2) == ["Salamanca Square", "Seven Mile Beach"])
        #expect(m.recents.count == 2)
        for q in ["hobart", "launceston", "devonport", "burnie", "strahan", "swansea", "bicheno", "stanley", "queenstown"] {
            m.begin()
            m.query = q
            m.submit()
        }
        #expect(m.recents.count == SearchModel.recentLimit)
        // an empty field lists them, with distances from the centre now
        m.begin()
        m.query = ""
        #expect(m.visibleRows.count == SearchModel.recentLimit)
        #expect(m.visibleRows.allSatisfy { $0.distanceKm != nil })
    }

    @Test func returnBeforeTheIndexPicksOnceItIsReady() async throws {
        let index = try await SearchIndexStore.shared.get()
        let slow = SearchIndexStore {
            try await Task.sleep(for: .milliseconds(100))
            return index
        }
        let m = SearchModel(store: slow)
        m.begin()
        #expect(m.status == .loading)
        m.query = "7 mile beach"
        m.submit()
        #expect(m.pin == nil)
        for _ in 0 ..< 100 where m.pin == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(m.pin?.result.name == "Seven Mile Beach")
    }

    @Test func aVersionMismatchSaysUpdateTheAppAndIsNotRetried() async throws {
        let calls = Counter()
        let broken = SearchIndexStore {
            await calls.bump()
            throw DataError.unsupportedVersion(file: "gazetteer.json", found: 2, supported: 1)
        }
        let m = SearchModel(store: broken)
        m.begin()
        for _ in 0 ..< 100 where m.status == .loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.status == .failed("Update the app to search"))
        m.query = "hobart"
        m.query = "hobarts"
        try await Task.sleep(for: .milliseconds(50))
        #expect(await calls.value == 1)
    }

    @Test func aDamagedInstallRetriesOnTheNextKeystroke() async throws {
        let calls = Counter()
        let broken = SearchIndexStore {
            await calls.bump()
            throw DataError.malformed(file: "gazetteer.json", reason: "test")
        }
        let m = SearchModel(store: broken)
        m.begin()
        for _ in 0 ..< 100 where m.status == .loading { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed = m.status else { Issue.record("expected a failure"); return }
        m.query = "ho"
        for _ in 0 ..< 100 where m.status == .loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await calls.value == 2)
    }

    /// Finding 13: Return pressed while the load fails must not pick a
    /// result later, when a keystroke's retry succeeds.
    @Test func aReturnDuringAFailedLoadIsForgotten() async throws {
        let calls = Counter()
        let index = try await SearchIndexStore.shared.get()
        let flaky = SearchIndexStore {
            await calls.bump()
            if await calls.value == 1 { throw DataError.malformed(file: "gazetteer.json", reason: "test") }
            return index
        }
        let m = SearchModel(store: flaky)
        m.begin()
        m.query = "hobart"
        m.submit()  // before the index: remembered
        for _ in 0 ..< 100 where m.status == .loading { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed = m.status else { Issue.record("expected a failure"); return }
        m.query = "hobarts"  // retries, succeeds
        for _ in 0 ..< 100 where m.status != .ready { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.status == .ready)
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.pin == nil)
        #expect(m.isActive)
    }

    @Test func spokenRowReadsKindNamePlaceDistance() {
        let r = SearchResult(id: "e1", name: "Salamanca Place", type: "Road", group: "Transport",
                             meta: "Road · Battery Point, Hobart", coordinate: Self.hobart, distanceKm: 0.3)
        #expect(SearchResultRow.spoken(r) == "Road, Salamanca Place, Battery Point, Hobart, 300 m away")
    }

    /// The row prints the place alone (the glyph says the kind) — unless
    /// two rows would then read the same.
    @Test func rowsPrintThePlaceAndSpellTheKindOnlyForTwins() {
        func r(_ id: String, _ meta: String) -> SearchResult {
            SearchResult(id: id, name: "Kempton", type: "", group: "", meta: meta, coordinate: Self.hobart, distanceKm: nil)
        }
        #expect(SearchResultRow.place(r("a", "Road · North Hobart, Hobart")) == "North Hobart, Hobart")
        #expect(SearchResultRow.place(r("a", "Mountain")) == "Mountain")
        let list = [r("a", "Locality · Southern Midlands"), r("b", "Town · Southern Midlands"), r("c", "Hill · Kempton, Southern Midlands")]
        #expect(SearchResultRow.twins(list) == ["a", "b"])
    }

    @Test func flightsTakeLongerForFartherPlacesButNeverOver1point2s() {
        #expect(SearchPinPresenter.flightDuration(km: 0) == 0.4)
        #expect(SearchPinPresenter.flightDuration(km: 1) < SearchPinPresenter.flightDuration(km: 100))
        #expect(SearchPinPresenter.flightDuration(km: 400) == 1.2)
    }
}

/// The search steps in AppModel's Escape chain: field → results → card → pin.
@MainActor
struct SearchEscapeTests {
    @Test func escapeWalksFieldThenResultsThenPin() async throws {
        let model = AppModel(data: .none, tables: StyleBuilderTests.tables)
        let index = try await SearchIndexStore.shared.get()
        _ = index
        model.search.begin()
        model.search.fieldFocused = true
        #expect(model.escapeStep == .leaveSearchField)
        model.escape()
        #expect(model.escapeStep == .closeSearch)
        model.escape()
        #expect(!model.search.isActive)
        #expect(model.escapeStep == nil)

        let place = SearchResult(id: "e1", name: "Hobart", type: "Town", group: "Cultural", meta: "Town · Hobart",
                                 coordinate: SearchModelTests.hobart)
        model.selectCommunity(code: "DOB", sourceName: nil)
        model.search.pick(place)
        #expect(model.selection == nil) // a pick closes the card
        model.selectCommunity(code: "DOB", sourceName: nil)
        #expect(model.escapeStep == .closeCard) // the card before the pin
        model.escape()
        #expect(model.escapeStep == .clearSearchPin)
        model.escape()
        #expect(model.search.pin == nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
