import XCTest

/// A soil card's report (the sheet's PDF from NRE's data library): its
/// size shows before the first tap, the tap fetches just that file — here
/// from the `-stubNetwork documents` stub, a generated 12-page PDF — and
/// afterwards it opens with no network at all. Soils ship in the app, so
/// this runs without packs (CI too).
final class SoilReportTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    /// The label point of a large Pss1 polygon on the Ellendale sheet
    /// (SoilsTests): a tap near the uncovered map's centre lands inside it.
    @MainActor
    private func launch(stub: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let camera = #"{"latitude":-42.625165,"longitude":146.821139,"zoom":12,"heading":0}"#
        var arguments = ["-lastCamera", Self.hex(camera), "-layerState", Self.hex(#"{"overlay":"soils"}"#)]
        if stub { arguments += ["-stubNetwork", "documents"] }
        let app = offlineApp(arguments)
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        let map = app.descendants(matching: .any)["map"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [idle], timeout: patience(20))
        return app
    }

    /// Taps the Pss1 polygon and scrolls the card until its report button
    /// can be tapped.
    @MainActor
    private func reportButton(_ app: XCUIApplication) -> XCUIElement {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        // the card first; its report button sits below the glance, so the
        // sheet goes up before it can show
        let card = app.descendants(matching: .any)["feature-card"].firstMatch
        XCTAssertTrue(card.appears(within: patience(8)), "no soil card")
        let button = app.buttons["open-soil-report"]
        dragPanelUp(app, until: button, in: card)
        XCTAssertTrue(button.appears(within: patience(5)), "no report button on the soil card")
        XCTAssertTrue(button.isHittable)
        return button
    }

    @MainActor
    private func openAndClose(_ app: XCUIApplication, _ button: XCUIElement) {
        button.tap()
        let reader = app.descendants(matching: .any)["pdf-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: patience(15)), "the reader didn't open")
        XCTAssertTrue(app.staticTexts["reader-page"].waitForExistence(timeout: patience(5)))
        app.buttons["reader-close"].tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: patience(5)))
    }

    /// Storage first: the row names the 11 reports and their size, and a
    /// copy from an earlier run is deleted (so the tap below really
    /// fetches). Then the tap opens the Ellendale report; relaunched with
    /// no stub (every request refused), it opens from the device. Last,
    /// the stub's PDF is deleted again, so no later run (or person) finds
    /// a 12-page stub as the real Ellendale report "on this iPhone".
    @MainActor
    func testTheSheetsReportOpensAndThenWorksOffline() {
        let app = launch(stub: true)
        deleteStoredReports(app)
        XCTAssertTrue(app.buttons["extra-soil-reports-get"].exists)
        app.terminate()

        let online = launch(stub: true)
        let button = reportButton(online)
        XCTAssertTrue(button.label.contains("Ellendale sheet"), button.label)
        XCTAssertTrue(button.label.contains("MB"), "its size before the first tap: \(button.label)")
        openAndClose(online, button)
        XCTAssertTrue(eventually(patience(5)) { button.label.contains("on this") }, button.label)
        online.terminate()

        let offline = launch(stub: false)
        let stored = reportButton(offline)
        XCTAssertTrue(stored.label.contains("on this"), stored.label)
        openAndClose(offline, stored)
        offline.terminate()

        let cleanup = launch(stub: false)
        deleteStoredReports(cleanup)
    }

    /// Storage's Soil reports row: deletes what is on the device (if
    /// anything), then reads "11 reports · 30 MB".
    @MainActor
    private func deleteStoredReports(_ app: XCUIApplication) {
        openStorage(app)
        let delete = app.buttons["extra-soil-reports-delete"]
        let status = app.staticTexts["extra-soil-reports-status"]
        reveal(status, in: app)
        XCTAssertTrue(status.exists, "no Soil reports row in Storage")
        if delete.exists {
            delete.tap()
            let confirm = app.buttons["Delete"]
            XCTAssertTrue(confirm.waitForExistence(timeout: patience(5)))
            confirm.tap()
            XCTAssertTrue(delete.waitForNonExistence(timeout: patience(5)))
        }
        XCTAssertTrue(eventually(patience(5)) { status.label == "11 reports · 30\u{00A0}MB" }, "status: \(status.label)")
    }

    /// Layers → "Offline maps & storage".
    @MainActor
    private func openStorage(_ app: XCUIApplication) {
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: patience(5)))
        let link = app.buttons["storage-link"]
        for _ in 0 ..< 8 where !(link.exists && link.isHittable) { drag(app, under: "Layers") }
        link.tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: patience(5)))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 12 where !(element.exists && element.isHittable) { drag(app, under: "Storage") }
    }

    /// Drags the list up by ~300 pt under the navigation bar.
    @MainActor
    private func drag(_ app: XCUIApplication, under bar: String) {
        let frame = app.navigationBars[bar].frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let list = app.descendants(matching: .any).matching(identifier: "storage").firstMatch
        var bottom = app.windows.firstMatch.frame.maxY - 60
        if list.exists, list.frame.height > 100 { bottom = min(bottom, list.frame.maxY - 30) }
        let start = origin.withOffset(CGVector(dx: frame.midX, dy: min(frame.maxY + 360, bottom)))
        let end = origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 40))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
