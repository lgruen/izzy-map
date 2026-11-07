import Foundation
import Testing
import UIKit
@testable import IzzyMap

/// The reference-photo decode lane: a stuck decode times out and moves the
/// lane to a fresh queue; three stuck at once answer nil at once; a stuck
/// decode that returns frees its place (the lane used to give up for the
/// whole session — every photo a name plate until relaunch).
struct RefPhotoLaneTests {
    nonisolated final class Gate: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        func block() { sem.wait() }
        func signal() { sem.signal() }
        /// Whether it was signalled within `seconds` (a semaphore wait isn't allowed in async code).
        func signalled(within seconds: Double) -> Bool { sem.wait(timeout: .now() + seconds) == .success }
    }

    @Test func stuckDecodesRecover() async throws {
        let lane = RefPhotoDecoder.Lane(timeout: 0.2)
        let gate = Gate()
        let image = UIImage()
        for n in 1...RefPhotoDecoder.Lane.maxStuck {
            let got = await lane.run(file: "stuck\(n)") { gate.block(); return image }
            #expect(got == nil)
            #expect(lane.stuckNow == n)
        }
        // full: answers at once, the work never runs
        let ran = Gate()
        let refused = await lane.run(file: "refused") { ran.signal(); return image }
        #expect(refused == nil)
        #expect(!ran.signalled(within: 0.3))
        // the stuck decodes return: the lane works again
        for _ in 1...RefPhotoDecoder.Lane.maxStuck { gate.signal() }
        let deadline = Date.now.addingTimeInterval(3)
        while lane.stuckNow > 0, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(lane.stuckNow == 0)
        let ok = await lane.run(file: "ok") { image }
        #expect(ok === image)
    }

    @Test func lateButNotStuckIsNotCounted() async throws {
        let lane = RefPhotoDecoder.Lane(timeout: 0.2)
        let got = await lane.run(file: "quick") { UIImage() }
        #expect(got != nil)
        #expect(lane.stuckNow == 0)
    }
}
