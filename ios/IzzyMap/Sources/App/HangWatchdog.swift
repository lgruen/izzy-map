#if DEBUG
import Foundation
import Synchronization

/// UI tests: `-hangWatchdog S` ends the app when the main thread hasn't
/// run a block for S seconds, so a main-thread hang fails the test at
/// once (the app is gone) instead of stalling every query until XCTest's
/// own timeouts — and the crash report holds the main thread's stack.
nonisolated enum HangWatchdog {
    static func startIfAsked() {
        let limit = UserDefaults.standard.double(forKey: "hangWatchdog")
        guard limit > 0 else { return }
        let thread = Thread {
            let beat = Beat()
            while true {
                let before = beat.count.load(ordering: .relaxed)
                DispatchQueue.main.async { beat.count.add(1, ordering: .relaxed) }
                Thread.sleep(forTimeInterval: limit)
                if beat.count.load(ordering: .relaxed) == before {
                    NSLog("HANG main thread unresponsive for %.0f s", limit)
                    abort()
                }
            }
        }
        thread.name = "HangWatchdog"
        thread.start()
    }

    private final class Beat: Sendable {
        let count = Atomic<UInt64>(0)
    }
}
#endif
