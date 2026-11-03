import Foundation
import Testing
@testable import IzzyMap

/// The Layers-sheet thumbnail queue: `MLNMapSnapshotter.cancel()` never
/// calls its completion handler, so a tile withdrawn mid-render used to leak
/// its continuation and stall the one worker — every later tile stayed a
/// placeholder. Real snapshots of a background-only style (no tiles, fast).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ThumbnailQueueTests {
    private static func style(_ colour: String) -> String {
        #"{"version":8,"sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"\#(colour)"}}]}"#
    }

    /// Waits until `key` is the running render, yielding the main actor
    /// between looks (a snapshot finishes on the main queue, many turns
    /// later — a sleep could step over a fast one).
    private func untilRendering(_ thumbs: LayerThumbnails, _ key: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while thumbs.renderingKey != key, !thumbs.hasImage(key), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(thumbs.renderingKey == key, "rendered before it could be withdrawn")
    }

    @Test func withdrawingMidRenderLeavesTheQueueWorking() async throws {
        let thumbs = LayerThumbnails()
        let a = Task { await thumbs.loadForTesting(key: "a-\(UUID())", styleJSON: Self.style("#ff0000")) }
        let first = UUID().uuidString
        let withdrawn = Task { await thumbs.loadForTesting(key: first, styleJSON: Self.style("#00ff00")) }
        await a.value
        try await untilRendering(thumbs, first)
        withdrawn.cancel()
        // the withdrawn waiter is resumed (no leaked continuation)
        await withdrawn.value
        // … and the worker moves on: another key renders
        let next = "b-\(UUID())"
        await thumbs.loadForTesting(key: next, styleJSON: Self.style("#0000ff"))
        #expect(thumbs.hasImage(next))
    }

    @Test func aKeyAskedForAgainWhileItsCancelLandsStillRenders() async throws {
        let thumbs = LayerThumbnails()
        let key = "c-\(UUID())"
        let withdrawn = Task { await thumbs.loadForTesting(key: key, styleJSON: Self.style("#ff00ff")) }
        try await untilRendering(thumbs, key)
        withdrawn.cancel()
        await withdrawn.value
        // the tile comes back (scrolled into view again) before the worker
        // saw the cancelled render end: re-queued, not answered empty
        await thumbs.loadForTesting(key: key, styleJSON: Self.style("#ff00ff"))
        #expect(thumbs.hasImage(key))
    }
}
