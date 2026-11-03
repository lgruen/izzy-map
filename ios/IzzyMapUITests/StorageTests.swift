import XCTest

/// Storage, from Layers, against the DEBUG fake pack store (`-fakePacks`):
/// the real Background Assets manager has no packs in a test run. Needs no
/// `data/`, so it runs in CI too.
final class StorageTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(packs: String = "vector,topo,relief") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fakePacks", packs, "-fakePackSeconds", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: 15))
        return app
    }

    /// Layers → "Offline maps & storage" (scrolling the sheet / popover as needed).
    @MainActor
    private func openStorage(_ app: XCUIApplication) {
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: 5))
        let link = app.buttons["storage-link"]
        for _ in 0 ..< 8 where !(link.exists && link.isHittable) { drag(app, under: "Layers") }
        link.tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 5))
    }

    /// Drags the list up by ~300 pt under the navigation bar (XCUITest gives
    /// a popover's list an empty frame, so swipe by coordinates).
    @MainActor
    private func drag(_ app: XCUIApplication, under bar: String) {
        let frame = app.navigationBars[bar].frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // stay inside the sheet: on iPad Storage is a form sheet over the
        // Layers popover, and a drag outside it would close them both
        let list = app.descendants(matching: .any).matching(identifier: "storage").firstMatch
        var bottom = app.windows.firstMatch.frame.maxY - 60
        if list.exists, list.frame.height > 100 { bottom = min(bottom, list.frame.maxY - 30) }
        let start = origin.withOffset(CGVector(dx: frame.midX, dy: min(frame.maxY + 360, bottom)))
        let end = origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 40))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 10 where !(element.exists && element.isHittable) { drag(app, under: "Storage") }
    }

    @MainActor
    func testGetAndRemoveAPackFromStorage() {
        let app = launch()
        openStorage(app)
        XCTAssertTrue(app.descendants(matching: .any)["storage-gauge"].waitForExistence(timeout: 5))
        // core packs show as on the device, without a control
        XCTAssertTrue(app.staticTexts["pack-topo-status"].label.hasPrefix("On this"))
        XCTAssertFalse(app.buttons["pack-topo-remove"].exists)

        let get = app.buttons["pack-tasmap-get"]
        reveal(get, in: app)
        XCTAssertTrue(get.isHittable)
        get.tap()
        // one tap: progress at once, then on the device
        XCTAssertTrue(app.buttons["pack-tasmap-progress"].waitForExistence(timeout: 2))
        let remove = app.buttons["pack-tasmap-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pack-tasmap-status"].label.hasPrefix("On this"))

        // Remove asks first, then it's a Get again
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove from'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["pack-tasmap-get"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStoppedDownloadStaysStopped() {
        let app = XCUIApplication()
        // a slow fake download, so Stop lands mid-way
        app.launchArguments = ["-fakePacks", "vector,topo,relief", "-fakePackSeconds", "6"]
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: 15))
        openStorage(app)
        let get = app.buttons["pack-tasmap-get"]
        reveal(get, in: app)
        get.tap()
        let ring = app.buttons["pack-tasmap-progress"]
        XCTAssertTrue(ring.waitForExistence(timeout: 2))
        ring.tap()
        let stop = app.buttons["Stop Download"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(app.buttons["pack-tasmap-get"].waitForExistence(timeout: 5))
        // the stopped download's late steps never bring it back
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: ring)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 7), .timedOut)
        XCTAssertFalse(app.buttons["pack-tasmap-remove"].exists)
    }

    @MainActor
    func testGetAllSeasonsAndTheIncompleteSeasonNote() {
        let app = launch(packs: "vector,topo,relief,season-2023,season-2024")
        openStorage(app)
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Still being flown'")).firstMatch
        for _ in 0 ..< 10 where !note.exists { drag(app, under: "Storage") }
        XCTAssertTrue(note.exists)
        let all = app.buttons["seasons-get-all"]
        reveal(all, in: app)
        all.tap()
        // every missing season downloads; once all are here the row goes away
        XCTAssertTrue(app.buttons["pack-season-2020-progress"].waitForExistence(timeout: 3)
            || app.buttons["pack-season-2020-remove"].exists)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: all)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 12), .completed)
        // (the bottom season: still on screen in the iPad's shorter form sheet)
        XCTAssertTrue(app.buttons["pack-season-2020-remove"].waitForExistence(timeout: 2))
    }
}
