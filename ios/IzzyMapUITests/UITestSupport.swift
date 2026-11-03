import XCTest

/// How every UI test launches the app, and how long it waits.
///
/// - **Offline, always.** `-simulateOffline YES` leaves the live LIST
///   sources out of the style and fails every http(s) request of the app
///   (MapLibre, the extras sessions, `URLSession.shared`); a `-stubNetwork`
///   stub still answers first. CI runs in the US, far from LIST: a test
///   that waits on a live tile waits on the internet.
/// - **Network guard.** `-networkLog <file>`: the app writes each request it
///   stopped to that file, and the test fails at tear-down if there was any
///   — so "offline" stays true as the app grows new requests.
/// - **Patience.** `patience(_:)` scales a timeout by `UI_TIMEOUT_SCALE`
///   (CI sets `TEST_RUNNER_UI_TIMEOUT_SCALE`; 1 locally): the shared CI
///   simulators are several times slower, especially at XCUITest snapshots.
///   Waits stay condition-based; only their ceilings grow. `eventually`
///   and `appears(within:)` also survive a single snapshot slower than the
///   whole timeout.
extension XCTestCase {
    @MainActor
    func offlineApp(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let log = FileManager.default.temporaryDirectory
            .appending(path: "izzymap-network-\(UUID().uuidString).log")
        app.launchArguments = arguments + ["-simulateOffline", "YES", "-networkLog", log.path(percentEncoded: false)]
        addTeardownBlock {
            let tried = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: log)
            let urls = tried.split(separator: "\n")
            XCTAssertTrue(urls.isEmpty, "UI tests must not use the network; the app tried \(urls.count): "
                + urls.prefix(5).joined(separator: ", "))
        }
        return app
    }
}

/// Polls `condition` (every ¼ s) until it holds or `timeout` passes, and —
/// unlike `XCTWaiter` or `waitForExistence` — lets one evaluation outlast
/// the timeout: its answer still counts. On a freshly booted CI simulator
/// a single XCUITest snapshot with the keyboard up took 20–43 s (run
/// 41639043412; 1–3 s on a fresh local simulator, 0.1 s on a warm one),
/// and the waiter reported a time-out while the snapshot it was taking
/// already showed the right answer. Pass a `patience(_:)` timeout.
@MainActor
func eventually(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date.now >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.25)
    }
}

extension XCUIElement {
    /// Whether the element shows up within `timeout` (`eventually`: a
    /// snapshot slower than the timeout still answers).
    @MainActor
    func appears(within timeout: TimeInterval) -> Bool {
        eventually(timeout) { exists }
    }
}

/// `seconds`, scaled for a slow runner (`UI_TIMEOUT_SCALE`, default 1).
func patience(_ seconds: TimeInterval) -> TimeInterval {
    seconds * uiTimeoutScale
}

private let uiTimeoutScale: Double = {
    let raw = ProcessInfo.processInfo.environment["UI_TIMEOUT_SCALE"].flatMap(Double.init) ?? 1
    return max(1, raw)
}()
