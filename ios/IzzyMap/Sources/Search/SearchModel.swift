import Foundation
import IzzyKit
import Observation
import os

/// The place index, built once per process off the main thread (the first
/// focus of any window's search field) and shared by every window. A
/// failure is not cached unless it is a version mismatch: that build can
/// never read the file, so retrying would only redo the work.
@MainActor
final class SearchIndexStore {
    static let shared = SearchIndexStore(load: loadBundled)

    /// The app bundle's `Data/search/` files (SearchIndex.load hops off the main actor).
    nonisolated static func loadBundled() async throws -> SearchIndex {
        guard let data = BundledData.inBundle() else {
            throw DataError.malformed(file: SearchIndex.File.gazetteer, reason: "bundled data folder missing")
        }
        return try await SearchIndex.load(from: data)
    }

    private let load: @Sendable () async throws -> SearchIndex
    private(set) var index: SearchIndex?
    private var inflight: Task<SearchIndex, any Error>?
    private var permanent: (any Error)?
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Search")

    init(load: @escaping @Sendable () async throws -> SearchIndex) {
        self.load = load
    }

    /// Tests: an index already built.
    init(index: SearchIndex) {
        self.load = { index }
        self.index = index
    }

    func get() async throws -> SearchIndex {
        if let index { return index }
        if let permanent { throw permanent }
        let task = inflight ?? Task { try await load() }
        inflight = task
        do {
            let built = try await task.value
            index = built
            inflight = nil
            return built
        } catch {
            inflight = nil
            Self.logger.error("search index unreadable: \(String(describing: error), privacy: .public)")
            if Self.isPermanent(error) { permanent = error }
            throw error
        }
    }

    nonisolated static func isPermanent(_ error: any Error) -> Bool {
        if case DataError.unsupportedVersion = error { return true }
        return false
    }
}

/// One window's search: the query, its results, the keyboard highlight, the
/// picked place (pin + header chip) and the recent picks. The engine answers
/// in well under a millisecond, so every keystroke searches synchronously:
/// the list always belongs to the text in the field, and Return acts on
/// exactly that text.
@MainActor @Observable
final class SearchModel {
    /// The picked place. `flight` counts camera flights to it: a re-tap of
    /// the chip bumps it and the map flies again.
    struct Pin: Equatable {
        let result: SearchResult
        var flight: Int
    }

    enum Status: Equatable {
        /// The index has not been asked for yet.
        case idle
        case loading
        case ready
        /// Shown in place of results ("Update the app to search").
        case failed(String)
    }

    /// Recent picks kept per window.
    static let recentLimit = 8

    /// Search mode: the results (or recents) replace the card; the phone's
    /// sheet stands at its large detent, the iPad card grows.
    private(set) var isActive = false
    /// Mirrors the field's focus (the header writes it).
    var fieldFocused = false
    /// Bumped to ask the header to focus the field (⌘F, a tap on the chip's
    /// background).
    private(set) var focusRequest = 0

    /// The text in the field. Kept after a pick: reopening search restores it.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            highlighted = nil
            // a damaged install: each keystroke tries again
            if index == nil, isActive { ensureIndex() }
            refresh()
        }
    }
    private(set) var results: [SearchResult] = []
    /// Row picked by ↑/↓; nil = none (Return then takes the first).
    private(set) var highlighted: Int?
    private(set) var pin: Pin?
    private(set) var recents: [SearchResult] = []
    private(set) var status: Status = .idle
    /// Place and street counts, once loaded (the empty state's line).
    private(set) var counts: (places: Int, streets: Int)?

    /// The map centre, for distances (read at each search: reopening
    /// recomputes them for wherever the map is now).
    @ObservationIgnored var near: @MainActor () -> GeoPoint? = { nil }
    /// A result was picked (the window closes its card).
    @ObservationIgnored var onPick: @MainActor () -> Void = {}

    @ObservationIgnored private let store: SearchIndexStore
    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Return arrived before the index: pick once it is ready.
    @ObservationIgnored private var submitWhenReady = false

    init(store: SearchIndexStore = .shared) {
        self.store = store
        if let ready = store.index { adopt(ready) }
        #if DEBUG
        // screenshots: `-debugSearch "elizabeth st"` opens search with that query
        if store === SearchIndexStore.shared, let q = UserDefaults.standard.string(forKey: "debugSearch") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.begin()
                self?.query = q
            }
        }
        #endif
    }

    // MARK: mode

    /// The field got focus (or ⌘F): search mode, the last query and its
    /// results back (distances from the current centre).
    func begin() {
        if !isActive { isActive = true }
        ensureIndex()
        refresh()
    }

    /// ⌘F: search mode and the field focused.
    func focus() {
        begin()
        focusRequest += 1
    }

    /// Cancel / Escape / a pick: back to the map. The query stays.
    func end() {
        isActive = false
        fieldFocused = false
        highlighted = nil
        submitWhenReady = false
    }

    func clearQuery() { query = "" }

    // MARK: keyboard

    /// ↑/↓ over the visible rows (results, or recents for an empty field).
    func moveHighlight(_ delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { highlighted = nil; return }
        guard let current = highlighted else {
            highlighted = delta > 0 ? 0 : rows.count - 1
            return
        }
        highlighted = min(max(current + delta, 0), rows.count - 1)
    }

    /// Return: the highlighted row, else the first — searched afresh on the
    /// field's current text, never on a stale list.
    func submit() {
        guard index != nil else {
            submitWhenReady = !query.isEmpty
            ensureIndex()
            return
        }
        refresh()
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let i = highlighted.map { min(max($0, 0), rows.count - 1) } ?? 0
        pick(rows[i])
    }

    /// What the list shows: results for a query, recents for an empty field.
    var visibleRows: [SearchResult] { query.isEmpty ? recentRows : results }

    /// Recent picks with distances from the current centre.
    var recentRows: [SearchResult] {
        let centre = near()
        return recents.map { r in
            var r = r
            r.distanceKm = centre.map {
                SearchText.km(lat1: $0.latitude, lon1: $0.longitude, lat2: r.coordinate.latitude, lon2: r.coordinate.longitude)
            }
            return r
        }
    }

    /// Whether the query is long enough to answer (two letters).
    var queryIsSearchable: Bool { SearchText.normalise(query).utf8.count >= 2 }

    // MARK: picking

    func pick(_ result: SearchResult) {
        pin = Pin(result: result, flight: (pin?.flight ?? 0) + 1)
        recents.removeAll { $0.id == result.id || ($0.name == result.name && $0.meta == result.meta) }
        recents.insert(result, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        end()
        onPick()
    }

    /// The chip: fly to the place again.
    func refly() {
        guard var p = pin else { return }
        p.flight += 1
        pin = p
    }

    func clearPin() { pin = nil }

    // MARK: index

    private func ensureIndex() {
        guard index == nil, loading == nil else { return }
        if case .failed = status, !retryable { return }
        status = .loading
        loading = Task { [weak self, store] in
            do {
                let built = try await store.get()
                self?.adopt(built)
            } catch {
                self?.status = .failed(SearchIndex.failureMessage(for: error))
                self?.retryable = !SearchIndexStore.isPermanent(error)
                // a Return typed during the failed load must not pick a
                // result from a later, successful load (finding 13)
                self?.submitWhenReady = false
            }
            guard let self else { return }
            self.loading = nil
            self.refresh()
            if self.submitWhenReady, self.index != nil {
                self.submitWhenReady = false
                if self.isActive { self.submit() }
            }
        }
    }

    @ObservationIgnored private var retryable = true

    private func adopt(_ built: SearchIndex) {
        index = built
        counts = (built.placeCount, built.streetCount)
        status = .ready
    }

    private func refresh() {
        guard let index else {
            results = []
            return
        }
        results = index.search(query: query, near: near())
        if let h = highlighted, h >= visibleRows.count { highlighted = nil }
    }
}
