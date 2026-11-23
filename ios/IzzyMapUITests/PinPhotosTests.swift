import XCTest

/// A pin's photos (docs/PINS_PLAN.md §3, §5): drawn photos fed through the
/// REAL import pipeline (`-pinPhotoStub N` stands in for the system picker,
/// which runs in another process; a simulator has no camera, so the add
/// button opens the library at once): two thumbnails, the viewer pages
/// between them, a caption typed there and a deleted photo both survive a
/// relaunch (`-pinsStore`).
final class PinPhotosTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var storePath = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pinphotos-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appending(path: "Pins.store").path(percentEncoded: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    private static let spot = CGVector(dx: 0.45, dy: 0.4)

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        func hex(_ s: String) -> String { "<" + s.utf8.map { String(format: "%02x", $0) }.joined() + ">" }
        let camera = #"{"latitude":-42.88,"longitude":147.32,"zoom":14,"heading":0}"#
        let app = offlineApp(["-pinsStore", storePath, "-pinPhotoStub", "2", "-lastCamera", hex(camera), "-layerState", hex("{}")] + extra)
        app.resetAuthorizationStatus(for: .location)
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        let map = app.descendants(matching: .any)["map"].firstMatch
        XCTAssertTrue(eventually(patience(20)) { map.value as? String == "idle" }, "map idle")
        return app
    }

    @MainActor private func card(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["pin-card"].firstMatch }
    @MainActor private func viewer(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["photo-viewer"].firstMatch }
    @MainActor private func thumb(_ app: XCUIApplication, _ i: Int) -> XCUIElement { app.buttons["pin-photo-\(i)"] }
    /// One resolution, not `exists` then `label`: the page count goes away
    /// when a delete leaves one photo, and an element that vanishes between
    /// the two queries makes `.label` FAIL the test (CI, 2026-11-23) instead
    /// of reading as "gone". `snapshot()` throws instead (SearchTests' way).
    @MainActor private func pageLabel(_ app: XCUIApplication) -> String? {
        (try? app.staticTexts["photo-viewer-page"].snapshot())?.label
    }

    @MainActor
    func testAddTwoPhotosPageCaptionDeleteAndRelaunch() {
        var app = launch()
        app.coordinate(withNormalizedOffset: Self.spot).press(forDuration: 0.8)
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)), "a long-press opens the new pin's card")
        XCTAssertFalse(thumb(app, 0).exists, "a new pin has no photos")

        // a new pin: just the add button, beside the chip
        let add = app.buttons["pin-photo-add"]
        XCTAssertTrue(add.waitForExistence(timeout: patience(3)))
        add.tap()
        // with a camera (iOS 27 simulators may report the Mac's) the button
        // is a menu: Take Photo / Choose from Library
        let library = app.buttons["Choose from Library"]
        if library.waitForExistence(timeout: patience(2)) { library.tap() }
        XCTAssertTrue(thumb(app, 1).waitForExistence(timeout: patience(15)), "two thumbnails")
        XCTAssertTrue(thumb(app, 0).exists)
        XCTAssertFalse(thumb(app, 2).exists)
        XCTAssertTrue(eventually(patience(5)) { !app.descendants(matching: .any)["pin-photo-progress"].exists }, "the batch finished")

        // the viewer pages across this pin's photos
        thumb(app, 0).tap()
        XCTAssertTrue(viewer(app).waitForExistence(timeout: patience(5)))
        XCTAssertTrue(eventually(patience(3)) { self.pageLabel(app) == "1 of 2" })
        viewer(app).swipeLeft()
        XCTAssertTrue(eventually(patience(3)) { self.pageLabel(app) == "2 of 2" }, "paged to the second")

        // a caption on the second photo (Return is Done)
        let caption = app.textFields["pin-photo-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: patience(3)))
        caption.tap()
        app.typeText("Seed heads\n")
        XCTAssertTrue(eventually(patience(3)) { (caption.value as? String) == "Seed heads" })

        // back to the first and delete it (asked first)
        viewer(app).swipeRight()
        XCTAssertTrue(eventually(patience(3)) { self.pageLabel(app) == "1 of 2" })
        app.buttons["pin-photo-delete"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Photo' AND identifier != 'pin-photo-delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: patience(3)), "Delete asks first")
        confirm.tap()
        XCTAssertTrue(eventually(patience(3)) { self.pageLabel(app) == nil }, "one photo left (no page count)")
        XCTAssertTrue(eventually(patience(3)) { (caption.value as? String) == "Seed heads" }, "the captioned one stays")
        app.buttons["photo-viewer-close"].tap()
        XCTAssertTrue(eventually(patience(3)) { !self.viewer(app).exists })
        XCTAssertTrue(thumb(app, 0).exists)
        XCTAssertFalse(thumb(app, 1).exists)

        // relaunch: the pin keeps one photo, with its caption
        app.terminate()
        app = launch()
        app.coordinate(withNormalizedOffset: Self.spot).tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)), "a tap on the pin selects it")
        XCTAssertTrue(thumb(app, 0).waitForExistence(timeout: patience(3)))
        XCTAssertFalse(thumb(app, 1).exists)
        thumb(app, 0).tap()
        XCTAssertTrue(viewer(app).waitForExistence(timeout: patience(5)))
        XCTAssertEqual(app.textFields["pin-photo-caption"].value as? String, "Seed heads")
    }
}
