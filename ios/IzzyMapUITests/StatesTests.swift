import XCTest

/// Milestone 7 "every state designed" (docs/DESIGN.md §3 "States"): the
/// first-launch welcome and "Maps arriving" chip, offline / empty / error
/// states. The functional tests need no packs (fake pack states). With
/// TEST_RUNNER_SHOT_DIR (+ TEST_RUNNER_SHOT_PREFIX, TEST_RUNNER_SHOT_LANDSCAPE=1)
/// and the main checkout's packs, `testStateShots` writes the design-review
/// screenshots of every state.
final class StatesTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let dataDir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "data")
    private static var hasPacks: Bool {
        FileManager.default.fileExists(atPath: dataDir.appending(path: "tasveg.pmtiles").path(percentEncoded: false))
    }

    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    private static func camera(_ latitude: Double, _ longitude: Double, _ zoom: Double) -> String {
        hex(#"{"latitude":\#(latitude),"longitude":\#(longitude),"zoom":\#(zoom),"heading":0}"#)
    }

    @MainActor
    private func launch(_ args: [String], camera: String = StatesTests.camera(-42.905, 147.245, 14),
                        data: Bool = true) -> XCUIApplication {
        var all = ["-lastCamera", camera, "-layerState", Self.hex("{}")] + args
        if data, Self.hasPacks { all += ["-dataDir", Self.dataDir.path(percentEncoded: false)] }
        let app = offlineApp(all)
        app.launch()
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        return app
    }

    /// The welcome shows on a first launch, rings nothing it can't do, and
    /// OK puts it away; the chip says how far the core packs are and opens
    /// Storage.
    @MainActor
    func testWelcomeAndMapsArriving() {
        let app = launch(["-welcomeSeen", "NO", "-fakePacks", "vector,topo=downloading:0.5,relief=paused,plantid",
                          "-fakePackSeconds", "600"], data: false)
        let welcome = app.descendants(matching: .any)["welcome"]
        XCTAssertTrue(welcome.waitForExistence(timeout: patience(5)))
        let chip = app.buttons["maps-arriving"]
        XCTAssertTrue(chip.waitForExistence(timeout: patience(5)))
        XCTAssertTrue(chip.label.contains("topographic map"), chip.label)
        XCTAssertTrue(chip.label.contains("percent"), chip.label)
        app.buttons["welcome-ok"].tap()
        XCTAssertTrue(eventually(patience(3)) { !welcome.exists }, "OK dismisses the welcome")
        chip.tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: patience(5))
            || app.staticTexts["Storage"].waitForExistence(timeout: patience(2)), "the chip opens Storage")
    }

    /// Every core pack here: no chip. Opening Layers dismisses the welcome.
    @MainActor
    func testNoChipOnceTheMapsAreHereAndLayersDismissesTheWelcome() {
        let app = launch(["-welcomeSeen", "NO", "-fakePacks", "vector,topo,relief,plantid"], data: false)
        XCTAssertTrue(app.descendants(matching: .any)["welcome"].waitForExistence(timeout: patience(5)))
        XCTAssertFalse(app.buttons["maps-arriving"].exists)
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: patience(5)))
        XCTAssertFalse(app.descendants(matching: .any)["welcome"].exists)
    }

    // MARK: Screenshots

    private var shotDir: String? { ProcessInfo.processInfo.environment["SHOT_DIR"] }
    private var prefix: String { ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? "m7" }

    @MainActor private func save(_ name: String) {
        guard let shotDir else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(filePath: shotDir).appending(path: "\(prefix)-\(name).png"))
    }

    @MainActor private func waitForIdle(_ app: XCUIApplication) {
        let map = app.descendants(matching: .any)["map"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [idle], timeout: patience(20))
    }

    /// One screenshot per designed state (no aerial or UN photos in any).
    @MainActor
    func testStateShots() throws {
        try XCTSkipUnless(shotDir != nil, "screenshots only")
        try XCTSkipUnless(Self.hasPacks, "no local packs")
        if ProcessInfo.processInfo.environment["SHOT_LANDSCAPE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let core = "vector,topo,relief,plantid"
        let state = Self.camera(-42.0, 146.6, 7.2)
        let hobart = Self.camera(-42.905, 147.245, 14)
        let hobart11 = Self.camera(-42.86, 147.3, 11)
        // a spot in the South West nobody has recorded around (7 × 7 empty
        // record cells): the "Recorded near here" empty state
        let unrecorded = Self.camera(-43.36, 146.44, 14)
        typealias Shot = (name: String, args: [String], camera: String, wait: UInt32, then: ((XCUIApplication) -> Void)?)
        let shots: [Shot] = [
            // first launch, offline, topo still arriving: coast + vegetation,
            // the welcome and the chip
            ("first-launch", ["-welcomeSeen", "NO", "-fakePacks", "vector,topo=downloading:0.62,relief=downloading:0.1",
                              "-fakePackSeconds", "900"], state, 5, nil),
            ("first-launch-z11", ["-fakePacks", "vector,topo=downloading:0.62,relief=downloading:0.1",
                                  "-fakePackSeconds", "900"], hobart11, 5, nil),
            ("maps-waiting-offline", ["-fakePacks", "vector,topo=paused,relief"], hobart11, 4, nil),
            ("maps-failed", ["-fakePacks", "vector,topo=failed,relief,plantid"], hobart11, 4, nil),
            ("maps-arriving-storage", ["-fakePacks", "vector,topo=downloading:0.62,relief=downloading:0.1",
                                       "-fakePackSeconds", "900"], hobart11, 3, { app in
                app.buttons["maps-arriving"].tap()
                sleep(3)
            }),
            ("relief-default", ["-fakePacks", core], Self.camera(-42.68, 146.62, 12), 5, nil),
            ("document-offline", ["-fakePacks", core, "-debugTaps", "0.6,0.32", "-sheetDetent", "large"], hobart, 6, nil),
            ("document-offline-tapped", ["-fakePacks", core, "-debugTaps", "0.6,0.32", "-sheetDetent", "large"], hobart, 6, { app in
                let read = app.buttons["read-description"]
                if read.waitForExistence(timeout: patience(5)) { read.tap() }
                sleep(2)
            }),
            ("nearby-empty", ["-fakePacks", core, "-debugTaps", "0.6,0.32", "-sheetDetent", "large",
                              "-debugExpandPlants", "YES", "-debugScrollCard", "YES"], unrecorded, 7, { app in
                // down past the two lists to "Recorded near here"
                let empty = app.descendants(matching: .any)["nearby-empty"]
                for _ in 0 ..< 12 where !(empty.exists && empty.isHittable) {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)))
                }
                sleep(1)
            }),
            ("plant-photo-offline", ["-fakePacks", core, "-debugTaps", "0.6,0.32", "-debugPlant", "Bauera rubioides"], hobart, 7, nil),
            ("plant-habitats", ["-fakePacks", core, "-debugTaps", "0.6,0.32", "-debugPlant", "Bauera rubioides",
                                "-debugScrollSheet", "habitats"], hobart, 8, nil),
            ("plant-habitats-wet", ["-fakePacks", core, "-debugTaps", "0.6,0.32", "-debugPlant", "Goodenia elongata",
                                    "-debugScrollSheet", "habitats"], hobart, 8, nil),
            ("search-empty", ["-fakePacks", core, "-debugSearch", "Mt Welingtonn"], hobart11, 5, nil),
            ("areas-empty", ["-fakePacks", core, "-resetAreas", "YES", "-openLayers", "YES", "-openStorage", "YES",
                             "-storageScroll", "areas"], hobart11, 5, nil),
            ("storage-pack-failed", ["-fakePacks", "vector,topo=failed,relief,plantid=paused", "-openLayers", "YES",
                                     "-openStorage", "YES"], hobart11, 5, nil),
            ("plantid-model-missing", ["-fakePacks", "vector,topo,relief", "-debugPlantID", "YES"], hobart11, 5, nil),
            ("plantid-model-arriving", ["-fakePacks", "vector,topo,relief,plantid=downloading:0.42",
                                        "-fakePackSeconds", "900", "-debugPlantID", "YES"], hobart11, 5, nil),
            ("location-denied", ["-fakePacks", core, "-debugNotice", "denied"], hobart11, 4, nil),
            ("location-nofix", ["-fakePacks", core, "-debugNotice", "noFix"], hobart11, 4, nil),
        ]
        let only = ProcessInfo.processInfo.environment["SHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for shot in shots where only?.contains(shot.name) ?? true {
            // UN thumbnails fail quietly (the offline guard counts real requests)
            let app = launch(shot.args + ["-stubNetwork", "offline"], camera: shot.camera)
            waitForIdle(app)
            sleep(shot.wait)
            shot.then?(app)
            save(shot.name)
            app.terminate()
        }
    }
}
