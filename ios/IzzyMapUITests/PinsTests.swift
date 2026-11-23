import XCTest

/// Pins (docs/PINS_PLAN.md): a real long-press drops a pin and opens its
/// card; the title typed there survives a relaunch (`-pinsStore`); a tap on
/// the pin selects it again over whatever lies under it; Delete offers
/// Undo. No packs needed — the pins draw on the bare style.
final class PinsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var storePath = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pins-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appending(path: "Pins.store").path(percentEncoded: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    /// Where the tests press: open map, clear of the controls and the sheet.
    private static let spot = CGVector(dx: 0.45, dy: 0.4)

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        func hex(_ s: String) -> String { "<" + s.utf8.map { String(format: "%02x", $0) }.joined() + ">" }
        let camera = #"{"latitude":-42.88,"longitude":147.32,"zoom":14,"heading":0}"#
        let app = offlineApp(["-pinsStore", storePath, "-lastCamera", hex(camera), "-layerState", hex("{}")] + extra)
        // no launch fix: the camera stays where the test puts it
        app.resetAuthorizationStatus(for: .location)
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        let map = app.descendants(matching: .any)["map"].firstMatch
        XCTAssertTrue(eventually(patience(20)) { map.value as? String == "idle" }, "map idle")
        return app
    }

    @MainActor private func card(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["pin-card"].firstMatch }
    @MainActor private func title(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["pin-title"].firstMatch }

    @MainActor
    func testLongPressCreatesAPinWhoseTitlePersistsAndATapReselectsIt() {
        var app = launch()
        XCTAssertFalse(card(app).exists)
        app.coordinate(withNormalizedOffset: Self.spot).press(forDuration: 0.8)
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)), "a long-press opens the new pin's card")
        // (the facts row reads as one element: "<date>, On the map")
        XCTAssertTrue(app.staticTexts["pin-source"].firstMatch.label.hasSuffix("On the map"))
        // the title field is ready: typing goes straight into it
        XCTAssertTrue(eventually(patience(5)) { self.title(app).hasFocus }, "title focused")
        app.typeText("Seep below the track")
        XCTAssertTrue(eventually(patience(3)) { (self.title(app).value as? String) == "Seep below the track" })
        // closing the card saves the typing
        app.buttons["card-close"].tap()
        XCTAssertTrue(eventually(patience(3)) { !self.card(app).exists })

        app.terminate()
        app = launch()
        XCTAssertFalse(card(app).exists)
        app.coordinate(withNormalizedOffset: Self.spot).tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)), "a tap on the pin selects it")
        XCTAssertEqual(title(app).value as? String, "Seep below the track")
        // a long-press ON the pin selects it, never stacks a second one
        // (a new pin's card would open empty, its title focused)
        app.buttons["card-close"].tap()
        XCTAssertTrue(eventually(patience(3)) { !self.card(app).exists })
        app.coordinate(withNormalizedOffset: Self.spot).press(forDuration: 0.8)
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)))
        XCTAssertEqual(title(app).value as? String, "Seep below the track")
        XCTAssertFalse(title(app).hasFocus)
        // an empty tap elsewhere closes it again
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(eventually(patience(3)) { !self.card(app).exists })
    }

    /// `-debugLongPress` (screenshots, scripted runs) takes the same path.
    @MainActor
    func testDeleteOffersUndo() {
        let app = launch(["-debugLongPress", "\(Self.spot.dx),\(Self.spot.dy)"])
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(8)))
        XCTAssertTrue(eventually(patience(5)) { self.title(app).hasFocus })
        app.typeText("Gate")
        let delete = app.buttons["pin-delete"]
        // the keyboard and the large sheet: Delete may sit below the fold
        for _ in 0 ..< 3 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(eventually(patience(3)) { !self.card(app).exists }, "the card closes")
        let undo = app.buttons["pin-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: patience(3)))
        undo.tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)), "Undo brings the pin and its card back")
        XCTAssertEqual(title(app).value as? String, "Gate")
        XCTAssertFalse(app.buttons["pin-undo"].exists)
    }

    /// Typing a title, then the search field: search stays up (the sheet
    /// must not drop back to its glance, which would end the search).
    @MainActor
    func testSearchFromATitleFieldStaysOpen() {
        let app = launch(["-debugLongPress", "\(Self.spot.dx),\(Self.spot.dy)"])
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(8)))
        XCTAssertTrue(eventually(patience(5)) { self.title(app).hasFocus })
        app.textFields["search-field"].tap()
        XCTAssertTrue(app.buttons["search-cancel"].waitForExistence(timeout: patience(3)))
        sleep(2)
        XCTAssertTrue(app.buttons["search-cancel"].exists, "search closed itself")
    }

    /// The pin button without a fix says so and places nothing.
    @MainActor
    func testPinButtonWithoutAFixSaysHowToPlaceOne() {
        let app = launch()
        app.buttons["pin-button"].tap()
        // first use asks for location; whatever the answer, there is no fix yet
        let notice = app.descendants(matching: .any)["location-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: patience(5)))
        // undecided (the usual state here): "No location yet — long-press …";
        // a simulator left with location denied says that instead — either
        // way an honest notice, never a pin at a guessed spot
        let honest = NSPredicate(format: "label CONTAINS 'long-press' OR label CONTAINS 'Location access is off'")
        XCTAssertTrue(notice.staticTexts.containing(honest).firstMatch.exists)
        XCTAssertFalse(card(app).exists)
        // answer iOS's prompt: left up, it outlives the app and covers the
        // next test's screen
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if dontAllow.waitForExistence(timeout: patience(3)) { dontAllow.tap() }
    }
}

private extension XCUIElement {
    /// The field has the keyboard (software or hardware).
    @MainActor var hasFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
