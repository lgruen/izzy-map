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
    /// Open map away from the pin, on the phone and beside the iPad's card.
    private static let emptySpot = CGVector(dx: 0.7, dy: 0.25)

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
        // (the facts row reads as one element: "<date>, By hand on the map")
        XCTAssertTrue(app.staticTexts["pin-source"].firstMatch.label.hasSuffix("By hand on the map"))
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
        // an empty tap elsewhere closes it again (open map on both devices:
        // right of the pin, clear of the iPad's side card on the left and
        // of the map buttons at the trailing edge)
        app.coordinate(withNormalizedOffset: Self.emptySpot).tap()
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
        // the sheet drops to its glance (never a blank raised sheet) and, on
        // a phone held upright, the pill sits above it — not in the top
        // slot a raised sheet covers
        let banner = app.descendants(matching: .any)["pin-undo-banner"].firstMatch
        let search = app.textFields["search-field"]
        let window = app.windows.firstMatch
        if window.horizontalSizeClass == .compact, window.verticalSizeClass == .regular {
            XCTAssertTrue(eventually(patience(3)) {
                search.exists && search.frame.minY > window.frame.height * 0.6
            }, "the sheet back at its glance")
            XCTAssertTrue(eventually(patience(3)) { banner.frame.maxY <= search.frame.minY }, "the pill above the sheet")
        }
        XCTAssertTrue(undo.isHittable)
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

    // MARK: Pins screen (slice 2)

    @MainActor private func screen(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["pins-screen"].firstMatch }

    /// The card's chip opens the Pins screen; a project made there takes
    /// the pin (the chip); Layers opens the screen too; the project's page
    /// lists the pin, and its row opens that pin's card on the map.
    @MainActor
    func testPinsScreenFromTheChipAndFromLayersToAPinsCard() {
        let app = launch(["-debugLongPress", "\(Self.spot.dx),\(Self.spot.dy)"])
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(8)))
        XCTAssertTrue(eventually(patience(5)) { self.title(app).hasFocus })
        app.typeText("Gate")

        // the chip's menu: "All pins…"
        app.buttons["pin-project"].tap()
        app.buttons["All pins…"].tap()
        XCTAssertTrue(screen(app).waitForExistence(timeout: patience(5)), "the Pins screen from the chip")
        // a new project, confirmed with Return
        app.buttons["pins-new-project"].tap()
        let name = app.textFields["project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: patience(3)))
        XCTAssertTrue(eventually(patience(3)) { name.hasFocus }, "the name field is ready")
        app.typeText("Knocklofty\n")
        let row = app.buttons["pins-project-Knocklofty"]
        XCTAssertTrue(row.waitForExistence(timeout: patience(3)), "the new project is listed")
        app.buttons["pins-done"].tap()
        XCTAssertTrue(eventually(patience(3)) { !self.screen(app).exists })

        // file the pin in it from the card's chip
        XCTAssertTrue(card(app).exists, "the card stayed open under the screen")
        app.buttons["pin-project"].tap()
        app.buttons["Knocklofty"].tap()
        XCTAssertTrue(eventually(patience(3)) { (app.buttons["pin-project"].value as? String) == "Knocklofty" })
        app.buttons["card-close"].tap()
        XCTAssertTrue(eventually(patience(3)) { !self.card(app).exists })

        // Layers → Pins → the project → the pin's row → its card (once the
        // panel sheet is back down off the controls)
        sleep(1)
        XCTAssertTrue(eventually(patience(5)) { app.buttons["layers-button"].isHittable })
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: patience(5)))
        let layersRow = app.buttons["layers-pins"]
        // (drag under the bar: a swipe on the medium sheet moves the sheet)
        for _ in 0 ..< 6 where !(layersRow.exists && layersRow.isHittable) {
            let bar = app.navigationBars["Layers"].frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let bottom = app.windows.firstMatch.frame.maxY - 60
            origin.withOffset(CGVector(dx: bar.midX, dy: min(bar.maxY + 360, bottom)))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: bar.midX, dy: bar.maxY + 40)))
        }
        layersRow.tap()
        XCTAssertTrue(screen(app).waitForExistence(timeout: patience(5)), "the Pins screen from Layers")
        app.buttons["pins-project-Knocklofty"].tap()
        let pinRow = app.buttons["pin-row-Gate"]
        XCTAssertTrue(pinRow.waitForExistence(timeout: patience(3)), "the project lists its pin")
        pinRow.tap()
        XCTAssertTrue(eventually(patience(5)) { !self.screen(app).exists }, "the screen goes")
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(5)), "the pin's card opens")
        XCTAssertEqual(title(app).value as? String, "Gate")
    }

    /// The card's "New project…" is the same editor; Create files the pin.
    @MainActor
    func testNewProjectFromTheCardFilesThePin() {
        let app = launch(["-debugLongPress", "\(Self.spot.dx),\(Self.spot.dy)"])
        XCTAssertTrue(card(app).waitForExistence(timeout: patience(8)))
        app.buttons["pin-project"].tap()
        app.buttons["New project…"].tap()
        let name = app.textFields["project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: patience(3)))
        XCTAssertTrue(eventually(patience(3)) { name.hasFocus })
        app.typeText("Bonnet Hill")
        app.buttons["project-save"].tap()
        XCTAssertTrue(eventually(patience(3)) { !name.exists }, "the editor closes")
        XCTAssertTrue(eventually(patience(3)) { (app.buttons["pin-project"].value as? String) == "Bonnet Hill" })
    }

    /// Delete a project from its editor: Undo at the foot of the screen
    /// brings it back; deleted again, Recently deleted restores it.
    @MainActor
    func testDeleteAProjectUndoAndRestoreFromRecentlyDeleted() {
        let app = launch(["-debugSeedPins", "6", "-openPins", "YES"])
        XCTAssertTrue(screen(app).waitForExistence(timeout: patience(8)))
        let project = app.buttons["pins-project-Knocklofty Reserve"]
        XCTAssertTrue(project.waitForExistence(timeout: patience(3)))

        func deleteIt() {
            project.tap()
            app.buttons["project-edit"].tap()
            let delete = app.buttons["project-delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: patience(3)))
            for _ in 0 ..< 3 where !delete.isHittable { app.swipeUp() }
            delete.tap()
            XCTAssertTrue(eventually(patience(3)) { !project.exists }, "gone from the list (back on the screen's first page)")
        }

        deleteIt()
        let undo = app.buttons["pin-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: patience(3)))
        undo.tap()
        XCTAssertTrue(project.waitForExistence(timeout: patience(3)), "Undo brings the project back")

        deleteIt()
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.waitForExistence(timeout: patience(2)) { dismiss.tap() }
        let bin = app.buttons["pins-deleted"]
        for _ in 0 ..< 3 where !bin.isHittable { app.swipeUp() }
        bin.tap()
        let restore = app.buttons["deleted-restore-Knocklofty Reserve"]
        XCTAssertTrue(restore.waitForExistence(timeout: patience(3)))
        restore.tap()
        XCTAssertTrue(eventually(patience(3)) { !restore.exists })
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(project.waitForExistence(timeout: patience(3)), "restored from Recently deleted")
    }
}

private extension XCUIElement {
    /// The field has the keyboard (software or hardware).
    @MainActor var hasFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
