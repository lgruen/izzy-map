import XCTest

/// Design-review screenshots of the panel chrome (cards, Layers, key, scale
/// bar) over the most colourful map areas. Skipped unless the runner has
/// SHOT_DIR (`TEST_RUNNER_SHOT_DIR=… TEST_RUNNER_SHOT_PREFIX=iphone-dark
/// xcodebuild test -only-testing:IzzyMapUITests/ChromeTourTests`) and the
/// main checkout's packs are present.
final class ChromeTourTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")

    private var dir: String!
    private var prefix = "shot"

    private func prepare() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_SHOT_DIR to write the chrome tour")
        }
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.dataDir.appending(path: "tasveg.pmtiles").path(percentEncoded: false)),
            "no local packs"
        )
        self.dir = dir
        prefix = ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? "shot"
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(filePath: dir).appending(path: "\(prefix)-\(name).png"))
    }

    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    @MainActor
    private func launch(layers: String, latitude: Double, longitude: Double, zoom: Double) -> XCUIApplication {
        let camera = #"{"latitude":\#(latitude),"longitude":\#(longitude),"zoom":\#(zoom),"heading":0}"#
        let app = offlineApp(["-dataDir", Self.dataDir.path(percentEncoded: false),
                              "-lastCamera", Self.hex(camera), "-layerState", Self.hex(layers)])
        app.launch()
        _ = app.buttons["layers-button"].waitForExistence(timeout: patience(15))
        waitForIdle(app)
        return app
    }

    @MainActor
    private func waitForIdle(_ app: XCUIApplication, timeout: TimeInterval = patience(20)) {
        let map = app.descendants(matching: .any)["map"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [idle], timeout: timeout)
    }

    @MainActor
    private func tapCard(_ app: XCUIApplication, dys: [Double] = [0.32, 0.36, 0.28, 0.4]) {
        for dy in dys where !app.buttons["card-close"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: dy)).tap()
            _ = app.buttons["card-close"].waitForExistence(timeout: patience(2))
        }
        sleep(1)
    }

    /// Geology: map (scale + search over yellow), card, Layers at medium and
    /// large (iPad: popover), the geology key.
    @MainActor
    func testTourGeology() throws {
        try prepare()
        let app = launch(layers: #"{"overlay":"geology"}"#, latitude: -42.2, longitude: 146.6, zoom: 9)
        save("map-geology-z9")
        tapCard(app)
        save("card-geology")
        if app.buttons["card-close"].exists { app.buttons["card-close"].tap() }
        app.buttons["layers-button"].tap()
        _ = app.navigationBars["Layers"].waitForExistence(timeout: patience(5))
        sleep(3)
        save("layers-medium")
        // large detent (phone sheet): drag the navigation bar up
        let bar = app.navigationBars["Layers"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        sleep(2)
        save("layers-large")
        let link = app.buttons["legend-link"]
        for _ in 0 ..< 6 where !(link.exists && link.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        link.tap()
        _ = app.navigationBars["Geology key"].waitForExistence(timeout: patience(5))
        sleep(1)
        save("legend-geology")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        sleep(1)
        save("legend-geology-scrolled")
    }

    /// Vegetation and pre-1750 cards, the vegetation key, seasons.
    @MainActor
    func testTourCards() throws {
        try prepare()
        var app = launch(layers: "{}", latitude: -42.69, longitude: 146.66, zoom: 13.2)
        tapCard(app)
        save("card-veg")
        if app.buttons["card-close"].exists { app.buttons["card-close"].tap() }
        app.buttons["layers-button"].tap()
        let link = app.buttons["legend-link"]
        _ = app.navigationBars["Layers"].waitForExistence(timeout: patience(5))
        for _ in 0 ..< 6 where !(link.exists && link.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        link.tap()
        sleep(1)
        save("legend-veg")
        app.terminate()

        app = launch(layers: #"{"overlay":"pre1750"}"#, latitude: -42.2, longitude: 146.6, zoom: 9)
        tapCard(app)
        save("card-pre1750")
        app.terminate()

        app = launch(layers: #"{"base":"seasons","overlay":"none","season":4}"#, latitude: -42.88, longitude: 147.33, zoom: 14)
        app.buttons["layers-button"].tap()
        _ = app.navigationBars["Layers"].waitForExistence(timeout: patience(5))
        sleep(3)
        save("layers-seasons")
        app.terminate()
    }

    /// Tree card; the scale bar at z8 and z15.
    @MainActor
    func testTourTreeAndScale() throws {
        try prepare()
        var app = launch(layers: #"{"trees":true,"overlay":"none"}"#, latitude: -42.875571, longitude: 147.331568, zoom: 17)
        for dy in stride(from: 0.40, through: 0.52, by: 0.02) where !app.buttons["card-close"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
            _ = app.buttons["card-close"].waitForExistence(timeout: patience(1.5))
        }
        sleep(1)
        save("card-tree")
        app.terminate()

        app = launch(layers: "{}", latitude: -42.0, longitude: 146.6, zoom: 8)
        save("scale-z8")
        app.terminate()
        app = launch(layers: "{}", latitude: -42.885, longitude: 147.255, zoom: 15)
        save("scale-z15")
    }
}
