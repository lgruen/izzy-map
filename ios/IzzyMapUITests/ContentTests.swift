import XCTest

/// Milestone 3 content: a community card → its plants → a plant sheet →
/// back; the F2F description opened with a stubbed network. Needs the main
/// checkout's packs (a TASVEG polygon to tap). With TEST_RUNNER_SHOT_DIR
/// set, also writes design-review screenshots.
final class ContentTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")

    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    private var shotDir: String? { ProcessInfo.processInfo.environment["SHOT_DIR"] }
    private var prefix: String { ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? "m3" }

    @MainActor private func save(_ name: String) {
        guard let shotDir else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(filePath: shotDir).appending(path: "\(prefix)-\(name).png"))
    }

    @MainActor
    private func launch(extra: [String] = [], latitude: Double = -42.905, longitude: Double = 147.245,
                        zoom: Double = 14) throws -> XCUIApplication {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.dataDir.appending(path: "tasveg.pmtiles").path(percentEncoded: false)),
            "no local packs")
        let camera = #"{"latitude":\#(latitude),"longitude":\#(longitude),"zoom":\#(zoom),"heading":0}"#
        let app = offlineApp(["-dataDir", Self.dataDir.path(percentEncoded: false),
                              "-lastCamera", Self.hex(camera), "-layerState", Self.hex("{}")] + extra)
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        let map = app.descendants(matching: .any)["map"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [idle], timeout: patience(20))
        return app
    }

    /// Taps the map until a community card with plants shows.
    @MainActor private func tapCommunity(_ app: XCUIApplication) {
        for dy in [0.3, 0.34, 0.26, 0.38, 0.22] where !app.descendants(matching: .any)["plant-faces"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: dy)).tap()
            _ = app.descendants(matching: .any)["plant-faces"].waitForExistence(timeout: patience(4))
        }
        XCTAssertTrue(app.descendants(matching: .any)["plant-faces"].exists, "no community card with plants")
    }

    @MainActor private func dragUp(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
    }

    @MainActor
    func testCardPlantsPlantSheetAndBack() throws {
        let app = try launch()
        tapCommunity(app)
        sleep(2)
        save("card-peek")
        // "All n plants" under the faces opens the lists and scrolls to them
        app.buttons["plants-more"].tap()
        let section = app.descendants(matching: .any)["plants-section"]
        XCTAssertTrue(section.waitForExistence(timeout: patience(5)))
        XCTAssertTrue(app.buttons["plants-toggle"].waitForExistence(timeout: patience(2)))
        XCTAssertEqual(app.buttons["plants-toggle"].value as? String, "expanded")
        sleep(2)
        save("card-plants")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plant-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: patience(5)))
        for _ in 0 ..< 4 where !row.isHittable { dragUp(app) }
        row.tap()
        let sheet = app.descendants(matching: .any)["plant-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: patience(5)))
        XCTAssertTrue(app.staticTexts["plant-name"].waitForExistence(timeout: patience(3)))
        sleep(2)
        save("plant-sheet")
        dragUp(app)
        sleep(1)
        save("plant-sheet-scrolled")
        // back to the card, lists still open where they were
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["plants-toggle"].waitForExistence(timeout: patience(5)))
        XCTAssertFalse(sheet.exists)
        XCTAssertTrue(app.buttons["card-close"].exists)
    }

    @MainActor
    func testWhereElseAndDescriptionOpenWithAStubbedNetwork() throws {
        let app = try launch(extra: ["-stubNetwork", "documents"])
        tapCommunity(app)
        dragUp(app)
        let whereElse = app.descendants(matching: .any)["where-else"]
        XCTAssertTrue(whereElse.waitForExistence(timeout: patience(5)))
        sleep(1)
        save("card-where-else")
        let read = app.buttons["read-description"]
        XCTAssertTrue(read.waitForExistence(timeout: patience(5)))
        for _ in 0 ..< 3 where !read.isHittable { dragUp(app) }
        read.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pdf-reader"].waitForExistence(timeout: patience(15)))
        let page = app.staticTexts["reader-page"]
        XCTAssertTrue(page.waitForExistence(timeout: patience(5)))
        sleep(1)
        save("reader")
        app.buttons["reader-close"].tap()
        XCTAssertTrue(read.waitForExistence(timeout: patience(5)))
        // "Show on map" solos the community: the pill steps through its
        // largest patches, × ends it; the card stays
        let show = app.buttons["show-on-map"]
        for _ in 0 ..< 3 where !show.isHittable { dragUp(app) }
        show.tap()
        let pill = app.descendants(matching: .any)["spotlight-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: patience(5)))
        XCTAssertTrue(app.buttons["card-close"].exists)
        sleep(2)
        save("show-on-map")
        app.buttons["spotlight-next"].tap()
        let title = app.descendants(matching: .any)["spotlight-title"]
        XCTAssertTrue(title.waitForExistence(timeout: patience(3)))
        XCTAssertTrue((title.label as String).contains("patch 1 of"), title.label)
        sleep(2)
        save("show-on-map-patch")
        app.buttons["spotlight-close"].tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: patience(5)))
    }

    /// Design-review screenshots (only with TEST_RUNNER_SHOT_DIR): plant
    /// sheets for each kind of elevation, the scroll edges, "where else"
    /// and "Show on map" stepping. TEST_RUNNER_SHOT_LANDSCAPE=1 turns the
    /// device first (the iPad's main case).
    @MainActor
    func testDesignShots() throws {
        try XCTSkipUnless(shotDir != nil, "screenshots only")
        if ProcessInfo.processInfo.environment["SHOT_LANDSCAPE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let shots: [(String, [String])] = [
            ("card-peek", []),
            ("card-where-else", ["-sheetDetent", "large", "-debugScrollCard", "NO"]),
            ("card-scrolled", ["-sheetDetent", "medium", "-debugExpandPlants", "YES", "-debugScrollCard", "YES"]),
            ("plant-tall-eucalypt", ["-debugPlant", "Eucalyptus regnans"]),
            ("plant-shrub", ["-debugPlant", "Richea scoparia"]),
            ("plant-herb", ["-debugPlant", "Anemone crassifolia"]),
            ("plant-fern", ["-debugPlant", "Blechnum nudum"]),
            ("plant-tree-fern", ["-debugPlant", "Cyathea australis subsp. australis"]),
            ("plant-scrolled", ["-debugPlant", "Eucalyptus coccifera", "-debugScrollSheet", "YES"]),
            ("show-on-map", ["-debugSpotlight", "YES"]),
            ("show-on-map-patch2", ["-debugSpotlight", "YES", "-debugSpotlightStep", "2"]),
        ]
        for (name, args) in shots {
            let app = try launch(extra: ["-debugTaps", "0.6,0.32"] + args)
            sleep(name.hasPrefix("show-on-map-patch") ? 9 : 6)
            save(name)
            app.terminate()
        }
    }
}
