import XCTest

/// The Soils overlay with NO packs: its tiles ship inside the app, so these
/// run in CI too (no `-dataDir`; the base map is the offline coast outline).
final class SoilsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// UserDefaults reads `<hex>` launch arguments as Data.
    private static func hex(_ json: String) -> String {
        "<" + json.utf8.map { String(format: "%02x", $0) }.joined() + ">"
    }

    @MainActor
    private func launch(latitude: Double, longitude: Double, zoom: Double,
                        layers: String = #"{"overlay":"soils"}"#) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let camera = #"{"latitude":\#(latitude),"longitude":\#(longitude),"zoom":\#(zoom),"heading":0}"#
        let app = offlineApp(["-lastCamera", Self.hex(camera), "-layerState", Self.hex(layers)])
        app.launch()
        waitUntilReady(app)
        return app
    }

    /// The controls are up and the map has settled.
    @MainActor
    private func waitUntilReady(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["layers-button"].waitForExistence(timeout: patience(15)))
        let map = app.descendants(matching: .any)["map"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'idle'"), object: map)
        _ = XCTWaiter().wait(for: [idle], timeout: patience(20))
    }

    /// The card's header: one element, its label the spoken title.
    @MainActor
    private func header(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// A tap inside a soil polygon names its unit, code in its own case.
    /// The camera sits on the label point of a large Pss1 polygon on the
    /// Ellendale sheet (inscribed radius 3.1 km ≈ 218 pt at z12), so a tap
    /// near the uncovered map's centre lands inside it.
    @MainActor
    func testTappingASoilPolygonShowsItsUnit() {
        let app = launch(latitude: -42.625165, longitude: 146.821139, zoom: 12)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let card = header(app, startingWith: "Soil unit Pss1, Podzol and podzolic soils on sandstone 1")
        XCTAssertTrue(card.appears(within: patience(8)), "no Pss1 card")
        XCTAssertTrue(app.buttons["card-close"].exists)
    }

    /// Off the 11 mapped sheets a tap says why nothing is there, instead of
    /// silently doing nothing (Cradle Mountain: outside every sheet's
    /// frame); a second empty tap dismisses the note, as on any overlay.
    @MainActor
    func testATapOffTheSheetsExplainsTheCoverage() {
        let app = launch(latitude: -41.68, longitude: 145.95, zoom: 10)
        let spot = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        spot.tap()
        let note = header(app, startingWith: "No soil mapping here")
        XCTAssertTrue(note.appears(within: patience(8)))
        XCTAssertTrue(app.buttons["show-mapped-soils"].exists, "the one action this card offers")
        spot.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: patience(5)), "a second empty tap dismisses the note")
        XCTAssertFalse(app.buttons["card-close"].exists)
        // with another overlay, the same tap is just an empty spot
        app.terminate()
        let veg = launch(latitude: -41.68, longitude: 145.95, zoom: 10, layers: #"{"overlay":"geology"}"#)
        veg.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        XCTAssertFalse(header(veg, startingWith: "No soil mapping here").appears(within: patience(3)))
    }

    /// Soils is chosen in Layers like any overlay, and survives a relaunch.
    @MainActor
    func testSoilsPersistsAcrossRelaunch() {
        let app = launch(latitude: -42.88, longitude: 147.29, zoom: 11, layers: "{}")
        openLayers(app)
        let soils = app.buttons["overlay-soils"]
        reveal(soils, in: app)
        soils.tap()
        XCTAssertTrue(soils.isSelected)
        XCTAssertFalse(app.buttons["overlay-vegetation"].isSelected)
        let outlines = app.buttons["strength-outlines"]
        reveal(outlines, in: app)
        XCTAssertTrue(outlines.waitForExistence(timeout: patience(3)), "soils has unit lines: Outlines is offered")

        app.terminate()
        let again = offlineApp()
        again.launch()
        waitUntilReady(again)
        openLayers(again)
        let restored = again.buttons["overlay-soils"]
        reveal(restored, in: again)
        XCTAssertTrue(restored.isSelected)
    }

    /// Opens Layers (the map is idle: one tap must do it).
    @MainActor
    private func openLayers(_ app: XCUIApplication) {
        app.buttons["layers-button"].tap()
        XCTAssertTrue(app.navigationBars["Layers"].waitForExistence(timeout: patience(5)))
    }

    /// Scrolls the Layers list (sheet on iPhone, popover on iPad) until
    /// `element` can be tapped.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 where !(element.exists && element.isHittable) {
            let bar = app.navigationBars["Layers"].frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let bottom = app.windows.firstMatch.frame.maxY - 60
            origin.withOffset(CGVector(dx: bar.midX, dy: min(bar.maxY + 360, bottom)))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: bar.midX, dy: bar.maxY + 40)))
        }
    }
}
