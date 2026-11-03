import XCTest

/// Detailed areas: Layers → "Download an area…" → the frame on the map →
/// Next → the setup sheet → Download → the row in Storage, with the DEBUG
/// fake tile transport (`-fakeAreaTransport`): offline-safe, needs no
/// `data/`, so it runs in CI too.
final class AreaTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    @MainActor
    private func launch(zoom: Double) -> XCUIApplication {
        // Hobart's CBD
        let camera = #"{"latitude":-42.882,"longitude":147.327,"zoom":\#(zoom),"heading":0}"#
        let app = offlineApp(["-fakePacks", "vector,topo,relief", "-fakeAreaTransport", "ok", "-fakeAreaDelay", "20",
                              "-resetAreas", "YES", "-noAreaBackgroundTask", "YES",
                              "-lastCamera", Self.hex(camera), "-layerState", Self.hex("{}")])
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        return app
    }

    /// Layers → "Download an area…" (scrolling the sheet / popover as needed).
    @MainActor
    private func startFraming(_ app: XCUIApplication) {
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: patience(5)))
        let entry = app.buttons["layers-download-area"]
        let bar = app.navigationBars["Layers"].frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0 ..< 8 where !(entry.exists && entry.isHittable) {
            let bottom = app.windows.firstMatch.frame.maxY - 60
            origin.withOffset(CGVector(dx: bar.midX, dy: min(bar.maxY + 360, bottom)))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: bar.midX, dy: bar.maxY + 40)))
        }
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["framing-bar"].waitForExistence(timeout: patience(5)))
    }

    @MainActor
    func testFrameSetUpAndDownloadAnArea() {
        let app = launch(zoom: 14.5)
        startFraming(app)
        // the modal went; the frame's live size and the gauge are up
        XCTAssertFalse(app.navigationBars["Layers"].exists)
        XCTAssertTrue(app.staticTexts["Move the map to fit the box"].exists)
        let size = app.staticTexts["framing-size"]
        XCTAssertTrue(size.waitForExistence(timeout: patience(5)))
        // "0.5–0.8 MB · 570 × 740 m": a range, then the ground size
        XCTAssertTrue(size.label.contains("MB · ") || size.label.contains("GB · "), size.label)
        XCTAssertTrue(size.label.hasSuffix("km") || size.label.hasSuffix("m"), size.label)
        XCTAssertTrue(app.descendants(matching: .any)["framing-gauge"].exists)

        let next = app.buttons["framing-next"]
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let setup = app.descendants(matching: .any)["area-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: patience(5)))
        // the defaults: the base map shown (topo) at Fine, named "Area 1"
        XCTAssertEqual(app.textFields["area-name"].value as? String, "Area 1")
        XCTAssertTrue(app.buttons["area-layer-topo"].isSelected)
        XCTAssertFalse(app.buttons["area-layer-aerial"].isSelected)
        XCTAssertTrue(app.buttons["area-detail-17"].isSelected)
        // the detail plates carry their sizes
        XCTAssertTrue(app.buttons["area-detail-18"].label.contains("MB"), app.buttons["area-detail-18"].label)
        // Back returns to the frame, Next comes back to the sheet
        app.buttons["area-back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["framing-bar"].waitForExistence(timeout: patience(5)))
        app.buttons["framing-next"].tap()
        XCTAssertTrue(setup.waitForExistence(timeout: patience(5)))
        // a second layer, less detail
        app.buttons["area-layer-aerial"].tap()
        app.buttons["area-detail-16"].tap()
        XCTAssertTrue(app.buttons["area-detail-16"].isSelected)
        let download = app.buttons["area-download"]
        // the total rides in the button: "Download · ~1 MB"
        XCTAssertTrue(download.label.hasPrefix("Download · ~"), download.label)
        let total = app.staticTexts["area-total"]
        for _ in 0 ..< 4 where !(total.exists && total.isHittable) { setup.swipeUp() }
        XCTAssertTrue(total.label.contains("MB"), total.label)
        XCTAssertTrue(download.isEnabled)
        download.tap()

        // framing ends; Storage shows the new area arriving, then on the device
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: patience(8)))
        XCTAssertFalse(app.descendants(matching: .any)["framing-bar"].exists)
        let status = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'area-' AND identifier ENDSWITH '-status'")).firstMatch
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'area-row-'")).firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "storage").firstMatch
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            let frame = list.exists && list.frame.height > 100 ? list.frame : app.windows.firstMatch.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 40))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 340)))
        }
        XCTAssertTrue(status.waitForExistence(timeout: patience(5)))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'On this'"), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: patience(30)), .completed, status.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Topographic map, Aerial photos'")).firstMatch.exists)
        // "Show on map" takes her to it
        let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'area-' AND identifier ENDSWITH '-show'")).firstMatch
        XCTAssertTrue(show.exists)
        show.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Storage"])
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: patience(10)), .completed)
    }

    /// Too large: the bar says so, the gauge hatches, Next stays off;
    /// Cancel ends framing.
    @MainActor
    func testTooLargeFramesCantGoNext() {
        // statewide-ish: ~150 km across at map zoom 7.5
        let app = launch(zoom: 7.5)
        startFraming(app)
        let size = app.staticTexts["framing-size"]
        XCTAssertTrue(size.waitForExistence(timeout: patience(5)))
        XCTAssertEqual(size.label, "Too big — zoom in")
        XCTAssertEqual(app.descendants(matching: .any)["framing-gauge"].value as? String, "over the limit")
        XCTAssertFalse(app.buttons["framing-next"].isEnabled)
        app.buttons["framing-cancel"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.descendants(matching: .any)["framing-bar"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: patience(5)), .completed)
    }
}
