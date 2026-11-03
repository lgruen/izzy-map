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
        // default layers (topo + vegetation), whatever an earlier test left
        let layers = "{}".utf8.map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["-dataDir", Self.dataDir.path(percentEncoded: false), "-lastCamera", "<\(hex)>",
                               "-layerState", "<\(layers)>"]
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
        // a full-screen iPad stays regular width (card layout) both ways up:
        // rotating it switches no layout, so nothing closes
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "rotation switches layouts on a phone only")
        // a phone held upright, whatever an earlier (failed) test left
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        let plantID = app.buttons["plant-id-button"]
        let placeholder = app.staticTexts["Identify a plant"]
        // every wait is on a state, with room for a slow CI simulator
        let patience: TimeInterval = 20
        XCTAssertTrue(waitUntil(patience) { window.frame.height > window.frame.width }, "portrait")
        XCTAssertTrue(waitUntil(patience) { plantID.isHittable }, "the plant ID button")

        plantID.tap()
        // fully up (hittable), not mid-presentation, before the rotation
        XCTAssertTrue(waitUntil(patience) { placeholder.exists && placeholder.isHittable }, "plant ID opens")
        try turnLandscape(window, patience)
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: patience), "the old layout's modal closes")
        attachScreenshot("plant-id-rotated-closed")
        XCTAssertTrue(waitUntil(patience) { plantID.isHittable }, "the button in the card layout")
        plantID.tap()
        XCTAssertTrue(waitUntil(patience) { placeholder.exists && placeholder.isHittable }, "and opens again in the new layout")
        attachScreenshot("plant-id-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil(patience) { window.frame.height > window.frame.width }, "portrait again")
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: patience), "the card layout's modal closes")
        XCTAssertTrue(app.textFields["search-field"].waitForExistence(timeout: patience), "the panel sheet is back")
        XCTAssertTrue(waitUntil(patience) { plantID.isHittable }, "the button in the sheet layout")
        plantID.tap()
        XCTAssertTrue(waitUntil(patience) { placeholder.exists && placeholder.isHittable }, "and opens in the sheet layout")
        attachScreenshot("plant-id-portrait-again")
    }

    /// Rotating while the modal is still animating in must not strand it
    /// over the new layout (UIKit drops a dismissal during a transition).
    @MainActor
    func testRotatingWhileAModalOpensNeverStrandsIt() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "rotation switches layouts on a phone only")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        let plantID = app.buttons["plant-id-button"]
        XCTAssertTrue(waitUntil(20) { window.frame.height > window.frame.width && plantID.isHittable })
        plantID.tap()
        try turnLandscape(window, 20)
        XCTAssertTrue(app.staticTexts["Identify a plant"].waitForNonExistence(timeout: 20), "no stranded modal")
        attachScreenshot("rotated-mid-presentation")
    }

    /// Turns the device landscape and waits for the window to follow. A
    /// simulator that never turns (CI once picked the foldable "iPhone Duo",
    /// whose window stayed 466 × 678) is the environment, not the app: skip.
    /// The app's side — landscape in the iPhone's supported orientations —
    /// is pinned by the unit test `OrientationTests`, and the modal reset on
    /// the layout switch by `WindowModelTests.aLayoutSwitchResetsTheModal`.
    @MainActor
    private func turnLandscape(_ window: XCUIElement, _ timeout: TimeInterval) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        guard waitUntil(timeout, { window.frame.width > window.frame.height }) else {
            throw XCTSkip("simulator did not rotate (window \(window.frame.size) after \(Int(timeout)) s)")
        }
    }

    /// Polls `condition` (UI state, never a fixed sleep) until it holds or
    /// `timeout` passes.
    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
