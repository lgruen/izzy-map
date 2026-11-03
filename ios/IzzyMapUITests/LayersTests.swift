import XCTest

/// The Layers sheet and the key, with the main checkout's packs (skipped
/// where `data/` is absent). `testScreenshotTour` writes PNGs for design
/// review when the runner has SHOT_DIR (`TEST_RUNNER_SHOT_DIR=… xcodebuild test`).
final class LayersTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")

    /// UserDefaults reads `<hex>` launch arguments as Data.
    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    @MainActor
    private func launch(layers: String = "{}", latitude: Double = -42.88, longitude: Double = 147.29,
                        zoom: Double = 12.5) throws -> XCUIApplication {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.dataDir.appending(path: "tasveg.pmtiles").path(percentEncoded: false)),
            "no local packs at \(Self.dataDir.path)"
        )
        let camera = #"{"latitude":\#(latitude),"longitude":\#(longitude),"zoom":\#(zoom),"heading":0}"#
        let app = offlineApp(["-dataDir", Self.dataDir.path(percentEncoded: false),
                              "-lastCamera", Self.hex(camera), "-layerState", Self.hex(layers)])
        app.resetAuthorizationStatus(for: .location)
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        return app
    }

    @MainActor
    private func waitForMapIdle(_ app: XCUIApplication, timeout: TimeInterval = patience(20)) {
        let map = app.descendants(matching: .any)["map"]
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [found], timeout: timeout)
    }

    @MainActor
    private func openLayers(_ app: XCUIApplication) {
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: patience(5)))
    }

    /// Scrolls the sheet until `element` can be tapped.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 where !(element.exists && element.isHittable) { scrollLayers(app) }
    }

    /// Drags the Layers list up by ~300 pt (a sheet on iPhone, a popover on
    /// iPad — XCUITest reports the popover's list with an empty visible frame,
    /// so swipe by coordinates under its navigation bar).
    @MainActor
    private func scrollLayers(_ app: XCUIApplication) {
        let bar = app.navigationBars["Layers"].frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let bottom = app.windows.firstMatch.frame.maxY - 60
        let start = origin.withOffset(CGVector(dx: bar.midX, dy: min(bar.maxY + 360, bottom)))
        let end = origin.withOffset(CGVector(dx: bar.midX, dy: bar.maxY + 40))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    func testLayersSwitchBaseAndOverlay() throws {
        let app = try launch()
        openLayers(app)
        let topo = app.buttons["base-topo"], aerial = app.buttons["base-aerial"]
        XCTAssertTrue(topo.waitForExistence(timeout: patience(5)))
        XCTAssertTrue(topo.isSelected)
        aerial.tap()
        XCTAssertTrue(aerial.isSelected)
        XCTAssertFalse(topo.isSelected)

        let geology = app.buttons["overlay-geology"]
        reveal(geology, in: app)
        geology.tap()
        XCTAssertTrue(geology.isSelected)
        XCTAssertFalse(app.buttons["overlay-vegetation"].isSelected)
        // pre-1750 has no Outlines
        app.buttons["overlay-pre1750"].tap()
        XCTAssertFalse(app.buttons["strength-outlines"].exists)

        // the state survives a relaunch (without a -layerState argument)
        app.terminate()
        let again = offlineApp(["-dataDir", Self.dataDir.path(percentEncoded: false)])
        again.launch()
        openLayers(again)
        XCTAssertTrue(again.buttons["base-aerial"].waitForExistence(timeout: patience(5)))
        XCTAssertTrue(again.buttons["base-aerial"].isSelected)
        reveal(again.buttons["overlay-pre1750"], in: again)
        XCTAssertTrue(again.buttons["overlay-pre1750"].isSelected)
    }

    @MainActor
    func testLegendOpensFromLayers() throws {
        let app = try launch()
        openLayers(app)
        let link = app.buttons["legend-link"]
        reveal(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars["Vegetation key"].waitForExistence(timeout: patience(5)))
        XCTAssertTrue(app.staticTexts["Dry eucalypt forest and woodland"].waitForExistence(timeout: patience(5)))
        XCTAssertTrue(app.buttons["strength-full"].exists, "the key has its own strength control")
        attach("legend")
    }

    // MARK: Screenshot tour (design review)

    @MainActor
    func testScreenshotTour() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_SHOT_DIR to write the screenshot tour")
        }
        let prefix = ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? "shot"
        func save(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(filePath: dir).appending(path: "\(prefix)-\(name).png"))
        }

        // 1. default: topo + vegetation, Mount Field / Russell Falls area
        var app = try launch(latitude: -42.69, longitude: 146.66, zoom: 13.2)
        waitForMapIdle(app)
        save("map-topo-veg")
        // tap a polygon: the card + selection line
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).tap()
        _ = app.buttons["card-close"].waitForExistence(timeout: patience(5))
        waitForMapIdle(app, timeout: patience(5))
        save("card-veg")
        app.buttons["card-close"].tap()

        // 2. the Layers sheet and the key
        openLayers(app)
        sleep(3)  // thumbnails render
        save("layers")
        scrollLayers(app)
        sleep(2)
        save("layers-scrolled")
        let link = app.buttons["legend-link"]
        reveal(link, in: app)
        link.tap()
        _ = app.navigationBars["Vegetation key"].waitForExistence(timeout: patience(5))
        sleep(1)
        save("legend-veg")
        app.terminate()

        // 3. aerial + vegetation light, z14 (boundaries in paper white)
        app = try launch(layers: #"{"base":"aerial","strength":"light"}"#, latitude: -42.885, longitude: 147.255, zoom: 14.2)
        waitForMapIdle(app)
        save("map-aerial-light")
        app.terminate()

        // 4. topo + vegetation outlines (edge band)
        app = try launch(layers: #"{"strength":"outlines"}"#, latitude: -42.885, longitude: 147.255, zoom: 14.2)
        waitForMapIdle(app)
        save("map-topo-outlines")
        app.terminate()

        // 5. seasons + caption
        app = try launch(layers: #"{"base":"seasons","overlay":"none","season":4}"#, latitude: -42.88, longitude: 147.33, zoom: 14)
        waitForMapIdle(app)
        openLayers(app)
        sleep(3)
        save("layers-seasons")
        app.terminate()

        // 6. geology card + key
        app = try launch(layers: #"{"overlay":"geology"}"#, latitude: -42.2, longitude: 146.6, zoom: 9)
        waitForMapIdle(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).tap()
        _ = app.buttons["card-close"].waitForExistence(timeout: patience(5))
        save("card-geology")
        app.buttons["card-close"].tap()
        openLayers(app)
        reveal(app.buttons["legend-link"], in: app)
        app.buttons["legend-link"].tap()
        sleep(1)
        save("legend-geology")
        app.terminate()

        // 7. pre-1750 card
        app = try launch(layers: #"{"overlay":"pre1750"}"#, latitude: -42.2, longitude: 146.6, zoom: 9)
        waitForMapIdle(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).tap()
        _ = app.buttons["card-close"].waitForExistence(timeout: patience(5))
        save("card-pre1750")
        app.terminate()

        // 8. Hobart trees: clusters, then a tree card
        app = try launch(layers: #"{"trees":true,"overlay":"none"}"#, latitude: -42.8835, longitude: 147.3265, zoom: 14.2)
        waitForMapIdle(app)
        save("map-trees")
        app.terminate()
        // register tree D5, centred (the map centre sits above the sheet on a phone)
        app = try launch(layers: #"{"trees":true,"overlay":"none"}"#, latitude: -42.875571, longitude: 147.331568, zoom: 17)
        waitForMapIdle(app)
        for dy in stride(from: 0.40, through: 0.52, by: 0.02) where !app.buttons["card-close"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
            _ = app.buttons["card-close"].waitForExistence(timeout: patience(1.5))
        }
        save("card-tree")
        app.terminate()

        // 9. relief over topo + vegetation
        app = try launch(layers: #"{"relief":true}"#, latitude: -42.9, longitude: 147.24, zoom: 12)
        waitForMapIdle(app)
        save("map-relief")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
