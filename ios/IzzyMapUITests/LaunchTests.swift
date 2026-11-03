import XCTest

/// Smoke tests: the app launches into the map with its controls and panel;
/// with the developer's local packs, a tap shows a community card that
/// × closes.
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsMapControlsAndPanel() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["location-button"].exists)
        XCTAssertTrue(app.textFields["search-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plant-id-button"].exists)
        attachScreenshot("launch")

        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: 5))
        attachScreenshot("layers")
    }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")

    /// The app with the main checkout's packs, camera over the central
    /// highlands, no launch fix. Skips where `data/` is absent.
    @MainActor
    private func launchWithPacks() throws -> XCUIApplication {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.dataDir.appending(path: "tasveg.pmtiles").path(percentEncoded: false)),
            "no local TASVEG pack at \(Self.dataDir.path)"
        )
        let app = XCUIApplication()
        // no launch fix: the camera stays where the test puts it
        app.resetAuthorizationStatus(for: .location)
        // statewide over the central highlands (UserDefaults reads <hex> as Data)
        let camera = #"{"latitude":-42.0,"longitude":146.5,"zoom":8,"heading":0}"#
        let hex = camera.utf8.map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["-dataDir", Self.dataDir.path(percentEncoded: false), "-lastCamera", "<\(hex)>"]
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: 15))
        return app
    }

    /// Waits for the map's own "idle" signal (MapLibre: camera settled, all
    /// visible tiles loaded) — no fixed sleeps.
    @MainActor
    private func waitForMapIdle(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        let map = app.descendants(matching: .any)["map"]
        let idle = NSPredicate(format: "value == 'idle'")
        let found = XCTNSPredicateExpectation(predicate: idle, object: map)
        XCTAssertEqual(XCTWaiter().wait(for: [found], timeout: timeout), .completed, "the map never became idle")
    }

    /// Needs the main checkout's `data/` (simulator only; skipped elsewhere).
    @MainActor
    func testTapShowsCommunityCardAndCloseHidesIt() throws {
        let app = try launchWithPacks()
        waitForMapIdle(app)

        // idle = tiles loaded; still retry a couple of times rather than sleep
        let close = app.buttons["card-close"]
        for _ in 0 ..< 3 where !close.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)).tap()
            _ = close.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(close.exists, "tapping the map should show a community card")
        attachScreenshot("card")

        // the layout follows the size class, not the orientation
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the card survives rotation")
        attachScreenshot("card-landscape")
        XCUIDevice.shared.orientation = .portrait

        // Escape (MapCommands) is not exercised here: on the iPadOS 27.2
        // simulator XCUITest's synthesized Escape never reaches the app's
        // commands while ⌘-shortcuts do — check it with a real keyboard.
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "× should close the card")
        attachScreenshot("closed")
    }

    /// A modal open across a sheet ↔ card layout switch (iPhone rotation)
    /// must not leave its state stuck: it closes with its old host and opens
    /// again from the new layout.
    @MainActor
    func testPlantIDSurvivesRotationWithoutGettingStuck() throws {
        let app = XCUIApplication()
        app.launch()
        let plantID = app.buttons["plant-id-button"]
        XCTAssertTrue(plantID.waitForExistence(timeout: 15))
        let placeholder = app.staticTexts["Identify a plant"]

        plantID.tap()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 5), "the old layout's modal closes")
        attachScreenshot("plant-id-rotated-closed")
        XCTAssertTrue(plantID.waitForExistence(timeout: 5))
        plantID.tap()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "and opens again in the new layout")
        attachScreenshot("plant-id-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["search-field"].waitForExistence(timeout: 5), "the panel sheet is back")
        plantID.tap()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        attachScreenshot("plant-id-portrait-again")
    }

    /// The app's own (i) lists the credits of what the map shows.
    @MainActor
    func testCreditsListTheVisibleSources() throws {
        let app = try launchWithPacks()
        waitForMapIdle(app)
        app.buttons["attribution-button"].tap()
        XCTAssertTrue(app.navigationBars["Map Credits"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["TASVEG 5.0 from theLIST"].exists || app.links["TASVEG 5.0 from theLIST"].exists)
        XCTAssertTrue(app.buttons["Topographic Basemap from theLIST"].exists || app.links["Topographic Basemap from theLIST"].exists)
        attachScreenshot("credits")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
