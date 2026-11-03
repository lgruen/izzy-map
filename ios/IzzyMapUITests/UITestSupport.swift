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
///   Waits stay condition-based; only their ceilings grow.
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

/// `seconds`, scaled for a slow runner (`UI_TIMEOUT_SCALE`, default 1).
func patience(_ seconds: TimeInterval) -> TimeInterval {
    seconds * uiTimeoutScale
}

private let uiTimeoutScale: Double = {
    let raw = ProcessInfo.processInfo.environment["UI_TIMEOUT_SCALE"].flatMap(Double.init) ?? 1
    return max(1, raw)
}()
