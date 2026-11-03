import XCTest

/// The document reader over a card (milestone 3 review, findings 5 and
/// 11): Escape closes the reader and only the reader; a sheet ↔ card
/// layout switch keeps it open. F2F chapters come from the `-stubNetwork
/// documents` stub (a generated 12-page PDF). Needs the main checkout's
/// packs (a TASVEG polygon to tap).
final class DocumentTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")

    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.dataDir.appending(path: "tasveg.pmtiles").path(percentEncoded: false)),
            "no local packs")
        XCUIDevice.shared.orientation = .portrait
        let camera = #"{"latitude":-42.905,"longitude":147.245,"zoom":14,"heading":0}"#
        let app = offlineApp(["-dataDir", Self.dataDir.path(percentEncoded: false),
                              "-lastCamera", Self.hex(camera), "-layerState", Self.hex("{}"),
                              "-stubNetwork", "documents"])
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        let map = app.descendants(matching: .any)["map"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [idle], timeout: patience(20))
        return app
    }

    /// Taps the map until a community card with an F2F description shows,
    /// then opens the reader.
    @MainActor
    private func openReader(_ app: XCUIApplication) -> XCUIElement {
        let read = app.buttons["read-description"]
        for dy in [0.3, 0.34, 0.26, 0.38, 0.22] where !read.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: dy)).tap()
            _ = read.waitForExistence(timeout: patience(4))
        }
        XCTAssertTrue(read.exists, "no community card with a description")
        for _ in 0 ..< 4 where !read.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        read.tap()
        let reader = app.descendants(matching: .any)["pdf-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: patience(15)))
        XCTAssertTrue(app.staticTexts["reader-page"].waitForExistence(timeout: patience(5)))
        return reader
    }

    /// While the reader is up, the window's Escape step is the reader's
    /// (the Map menu's Escape command reads "Close Document"), so Escape
    /// can never close the card underneath. XCUITest's synthesized Escape
    /// doesn't reach the app on the simulator (see LaunchTests), so the
    /// step is read from the reader's DEBUG accessibility value; a real
    /// keyboard check stays manual.
    @MainActor
    func testEscapeClosesTheReaderNotTheCard() throws {
        let app = try launch()
        let reader = openReader(app)
        XCTAssertEqual(reader.value as? String, "Close Document")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !reader.waitForNonExistence(timeout: patience(2)) { app.buttons["reader-close"].tap() }
        XCTAssertTrue(reader.waitForNonExistence(timeout: patience(5)))
        XCTAssertTrue(app.buttons["card-close"].waitForExistence(timeout: patience(5)), "the card under the reader stays")
    }

    /// iPhone rotation switches sheet ↔ card layout: the reader is
    /// presented again by the new layout, at the page it was on.
    @MainActor
    func testTheReaderSurvivesALayoutSwitch() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "rotation switches layouts on a phone only")
        let app = try launch()
        let reader = openReader(app)
        let page = app.staticTexts["reader-page"]
        let before = page.label
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertTrue(reader.waitForExistence(timeout: patience(10)), "the reader is still up after the switch")
        XCTAssertTrue(page.waitForExistence(timeout: patience(5)))
        XCTAssertEqual(page.label, before)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(reader.waitForExistence(timeout: patience(10)), "and after switching back")
        app.buttons["reader-close"].tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: patience(5)))
        XCTAssertTrue(app.buttons["card-close"].waitForExistence(timeout: patience(5)))
    }
}
