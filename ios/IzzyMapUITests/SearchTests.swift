import XCTest

/// Place search end to end: results as you type, Return picks, pin + chip,
/// × clears, reopening restores the query. Needs no packs: the index is
/// bundled (the packs only make the screenshots readable).
final class SearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")

    /// Over Hobart, no launch fix, default layers.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        let camera = #"{"latitude":-42.88,"longitude":147.33,"zoom":13,"heading":0}"#
        let hex = camera.utf8.map { String(format: "%02x", $0) }.joined()
        let layers = "{}".utf8.map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["-dataDir", Self.dataDir.path(percentEncoded: false), "-lastCamera", "<\(hex)>",
                               "-layerState", "<\(layers)>"]
        app.launch()
        XCTAssertTrue(app.textFields["search-field"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func firstResult(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "search-result").firstMatch
    }

    /// Waits until the first row's label contains `text`.
    @MainActor
    private func waitForFirst(_ app: XCUIApplication, containing text: String) {
        let first = firstResult(app)
        let match = NSPredicate(format: "label CONTAINS %@", text)
        let found = XCTNSPredicateExpectation(predicate: match, object: first)
        XCTAssertEqual(XCTWaiter().wait(for: [found], timeout: 10), .completed,
                       "first result should contain “\(text)”, is “\(first.exists ? first.label : "none")”")
    }

    @MainActor
    func testTypePickClearAndRestore() {
        let app = launch()
        let field = app.textFields["search-field"]
        field.tap()
        XCTAssertTrue(app.buttons["search-cancel"].waitForExistence(timeout: 5), "searching shows Cancel")

        field.typeText("salamanca")
        // the engine ranks the square first (docs: "Salamanca" → the
        // square, not a farm); the street is right behind it
        waitForFirst(app, containing: "Salamanca Square")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'search-result' AND label CONTAINS 'Salamanca Place'"))
            .firstMatch.exists)
        XCTAssertTrue(firstResult(app).label.contains("away"), "rows read their distance from the map centre")
        attachScreenshot("salamanca")

        app.buttons["search-clear-text"].tap()
        field.typeText("7 mile beach")
        waitForFirst(app, containing: "Seven Mile Beach")

        // Return picks the first row of the CURRENT text
        field.typeText("\n")
        let chip = app.buttons["search-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "a pick shows the place in the header")
        XCTAssertTrue(chip.label.hasPrefix("Seven Mile Beach"), chip.label)
        XCTAssertFalse(app.buttons["search-cancel"].exists, "a pick ends searching")
        let pin = app.descendants(matching: .any)["search-pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "a pick drops a pin")
        attachScreenshot("picked")

        // the chip flies there again (no state change to see but the pin stays)
        chip.tap()
        XCTAssertTrue(pin.exists)
        XCTAssertFalse(app.buttons["search-cancel"].waitForExistence(timeout: 1), "the chip re-flies, it doesn't open search")

        // reopening restores the query and its results
        field.tap()
        XCTAssertTrue(app.buttons["search-cancel"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "7 mile beach")
        waitForFirst(app, containing: "Seven Mile Beach")
        app.buttons["search-cancel"].tap()

        // × clears the place and its pin
        XCTAssertTrue(app.buttons["search-chip-clear"].waitForExistence(timeout: 5))
        app.buttons["search-chip-clear"].tap()
        XCTAssertFalse(chip.waitForExistence(timeout: 2))
        XCTAssertFalse(pin.exists, "the pin goes with the chip")
    }

    @MainActor
    func testEmptyFieldListsRecentPicksAndNoMatchSaysSo() {
        let app = launch()
        let field = app.textFields["search-field"]
        field.tap()
        field.typeText("salamanca")
        waitForFirst(app, containing: "Salamanca")
        firstResult(app).tap()
        XCTAssertTrue(app.buttons["search-chip"].waitForExistence(timeout: 5))

        field.tap()
        app.buttons["search-clear-text"].tap()
        waitForFirst(app, containing: "Salamanca") // the recent pick
        XCTAssertTrue(app.staticTexts["Recent"].exists)

        field.typeText("qzxqzx")
        XCTAssertTrue(app.descendants(matching: .any)["search-no-results"].waitForExistence(timeout: 5))
    }

    /// iPad: ⌘F opens search, ↓ ↓ highlight the second row, Return picks
    /// it. Escape isn't driven here: XCUITest's synthesized Escape doesn't
    /// reach the app on the simulator (see DocumentTests); the field →
    /// results → pin order is SearchEscapeTests, a real keyboard stays manual.
    @MainActor
    func testHardwareKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "hardware keyboard paths run on the iPad")
        let app = launch()
        // the simulator drops a key command or two right after launch
        // (while it switches to its hardware keyboard): retry ⌘F
        let cancel = app.buttons["search-cancel"]
        for _ in 0 ..< 3 where !cancel.exists {
            app.typeKey("f", modifierFlags: .command)
            _ = cancel.waitForExistence(timeout: 2)
        }
        let field = app.textFields["search-field"]
        XCTAssertTrue(cancel.exists, "⌘F opens search")
        field.typeText("salamanca")
        waitForFirst(app, containing: "Salamanca")
        let second = app.buttons.matching(identifier: "search-result").element(boundBy: 1).label
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        let selected = app.buttons.matching(NSPredicate(format: "identifier == 'search-result' AND selected == true")).firstMatch
        XCTAssertEqual(selected.label, second, "↓ ↓ highlights the second row")
        // Return (typed into the field: the simulator's software keyboard
        // doesn't pass a test's hardware Return to onSubmit)
        field.typeText("\n")
        let chip = app.buttons["search-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        let name = String(chip.label.split(separator: ",").first ?? "")
        XCTAssertTrue(second.contains(", \(name),"), "picked “\(chip.label)”, second row was “\(second)”")

    }

    /// Screenshot tour for design review: `TEST_RUNNER_SEARCH_SHOTS_DIR=<dir>`
    /// (and the simulator's appearance set beforehand); skipped otherwise.
    @MainActor
    func testScreenshotTour() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = env["SEARCH_SHOTS_DIR"] ?? ""
        try XCTSkipIf(dir.isEmpty, "set TEST_RUNNER_SEARCH_SHOTS_DIR to take the tour")
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch()
        let prefix = "\(pad ? "ipad" : "iphone")-\(env["SEARCH_SHOTS_STYLE"] ?? "light")"
        func shot(_ name: String) {
            sleep(2)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: URL(filePath: dir).appending(path: "\(prefix)-\(name).png"))
        }
        shot("rest")
        let field = app.textFields["search-field"]
        field.tap()
        field.typeText("elizabeth st")
        waitForFirst(app, containing: "Elizabeth Street")
        if pad { app.typeKey(.downArrow, modifierFlags: []) }
        shot("results")
        field.typeText("\n")
        XCTAssertTrue(app.buttons["search-chip"].waitForExistence(timeout: 5))
        shot("picked")
        field.tap()
        app.buttons["search-clear-text"].tap()
        shot("recents")
        field.typeText("mt welington")
        shot("nomatch")
    }
}
