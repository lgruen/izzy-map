import UIKit
import XCTest

/// The pins export (docs/PINS_PLAN.md §6): a seeded project with photos
/// goes to the system share sheet as a .docx, and — through a scripted
/// Google (`-googleStub YES`: no network, no credentials, a stub sign-in
/// page) — to "Open in Google Docs". Selecting pins exports just those.
final class PinExportTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pinexport-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        let photos = dir.appending(path: "photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        // drawn stand-ins (no photo is committed), fed through the real import pipeline
        for i in 0 ..< 3 {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { ctx in
                UIColor(hue: CGFloat(i) / 3, saturation: 0.4, brightness: 0.8, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
                UIColor(red: 0.2, green: 0.4, blue: 0.2, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 700, width: 1600, height: 500))
            }
            try image.jpegData(compressionQuality: 0.8)!.write(to: photos.appending(path: "p\(i).jpg"))
        }
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = offlineApp(["-pinsStore", dir.appending(path: "Pins.store").path(percentEncoded: false),
                              "-debugSeedPins", "8", "-debugSeedPhotos", dir.appending(path: "photos").path(percentEncoded: false),
                              "-openPins", "YES", "-openPinsProject", "Knocklofty"] + extra)
        app.resetAuthorizationStatus(for: .location)
        app.launch()
        XCTAssertTrue(app.staticTexts["project-title"].waitForExistence(timeout: patience(25)), "the project's page")
        return app
    }

    @MainActor private func sheet(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["export-sheet"].firstMatch }

    @MainActor
    func testShareFileOffersTheDocxInTheShareSheet() {
        let app = launch()
        app.buttons["project-export"].tap()
        XCTAssertTrue(sheet(app).waitForExistence(timeout: patience(5)))
        XCTAssertTrue(app.buttons["export-photos"].exists, "the seeded project has photos: Include photos is offered")
        app.buttons["export-share"].tap()
        // the system share sheet (UIActivityViewController), headed by the
        // file's name: "Knocklofty Reserve — pins, 24 Nov 2026.docx"
        let list = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: patience(20)), "the share sheet")
        let file = list.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH '.docx'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: patience(5)), "it offers the .docx")
        XCTAssertTrue(file.label.hasPrefix("Knocklofty Reserve — pins, "), file.label)
    }

    @MainActor
    func testGoogleDocsThroughTheStubToOpenInGoogleDocs() {
        let app = launch(["-googleStub", "YES"])
        app.buttons["project-export"].tap()
        XCTAssertTrue(sheet(app).waitForExistence(timeout: patience(5)))
        let google = app.buttons["export-google"]
        XCTAssertTrue(google.exists, "with a client id (the stub's), Google Docs is offered")
        google.tap()
        // stub sign-in → build → resumable upload → the Doc's link
        let open = app.buttons["export-open-doc"]
        XCTAssertTrue(open.waitForExistence(timeout: patience(30)), "Open in Google Docs")
        XCTAssertTrue(app.descendants(matching: .any)["export-uploaded"].exists)
        XCTAssertTrue(app.buttons["export-disconnect"].exists, "connected now")
        // Done closes; a second export remembers the last Doc
        app.buttons["export-done"].tap()
        XCTAssertTrue(eventually(patience(5)) { !sheet(app).exists })
        app.buttons["project-export"].tap()
        XCTAssertTrue(app.buttons["export-last-doc"].waitForExistence(timeout: patience(5)), "the last Doc of this project, this session")
    }

    @MainActor
    func testSelectingPinsExportsJustThose() {
        let app = launch(["-googleStub", "YES"])
        app.buttons["pins-select"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pin-row-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: patience(3)))
        let total = rows.count
        XCTAssertGreaterThan(total, 2)
        rows.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        XCTAssertEqual(app.staticTexts["pins-selected-count"].label, "2 selected")
        let export = app.buttons["pins-export-selected"]
        XCTAssertTrue(export.label.contains("2 pins"), export.label)
        export.tap()
        XCTAssertTrue(sheet(app).waitForExistence(timeout: patience(5)))
        let counts = app.staticTexts["export-counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: patience(3)))
        XCTAssertTrue(counts.label.hasPrefix("2 of \(total) pins"), counts.label)
        app.buttons["export-close"].tap()
        XCTAssertTrue(eventually(patience(5)) { !sheet(app).exists })
        app.buttons["pins-select-cancel"].tap()
        XCTAssertTrue(app.buttons["pins-select"].waitForExistence(timeout: patience(3)), "back to the list")
    }
}
