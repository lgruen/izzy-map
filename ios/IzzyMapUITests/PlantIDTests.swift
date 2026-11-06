import XCTest

/// Identify a plant end to end with the DEBUG fake identifier (no 0.7 GB
/// model; `-plantIDFake`) and a drawn stand-in photo for the system picker
/// (`-plantIDPickStub`: PhotosPicker runs in another process): capture from
/// the library → framing → results → the plant sheet. Offline throughout;
/// `-stubNetwork offline` lets the UN photo fetches fail quietly.
final class PlantIDUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(_ mode: String) -> XCUIApplication {
        let app = offlineApp(["-plantIDFake", mode, "-plantIDPickStub", "YES",
                              "-plantIDLocation", " -42.88,147.32", "-stubNetwork", "offline"])
        app.launch()
        return app
    }

    @MainActor
    private func identify(_ app: XCUIApplication) {
        let wait = patience(20)
        let button = app.buttons["plant-id-button"]
        XCTAssertTrue(eventually(wait) { button.isHittable }, "the Identify button")
        button.tap()
        XCTAssertTrue(app.staticTexts["Identify a plant"].appears(within: wait), "Identify opens")
        let library = app.buttons["plant-id-library"]
        XCTAssertTrue(library.appears(within: wait))
        attachScreenshot("plant-id-capture")
        library.tap()
        let frame = app.descendants(matching: .any)["plant-id-frame"]
        XCTAssertTrue(frame.appears(within: wait), "the framing step")
        let go = app.buttons["plant-id-identify"]
        XCTAssertTrue(eventually(wait) { go.isEnabled }, "Identify is enabled once the (fake) model is loaded")
        // a pinch and a drag change the square (it stays inside the photo)
        frame.pinch(withScale: 1.6, velocity: 2)
        frame.swipeLeft()
        attachScreenshot("plant-id-framing")
        go.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-results"].appears(within: wait), "results")
    }

    @MainActor
    func testLibraryPhotoToSpeciesAndPlantSheet() throws {
        let app = launch("species")
        identify(app)
        let wait = patience(10)
        let answer = app.descendants(matching: .any)["plant-id-answer"]
        XCTAssertTrue(answer.appears(within: wait))
        XCTAssertTrue(answer.label.contains("Acacia dealbata"), "species answer: \(answer.label)")
        // the common name as a headline: first letter up (rows keep "silver wattle")
        XCTAssertTrue(answer.label.contains("Silver wattle"), "headline common name: \(answer.label)")
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-crop"].exists, "her crop beside the candidates")
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-ladder"].exists, "the ladder graphic")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plant-id-candidate-' AND label CONTAINS 'Recorded within 10 km'")).firstMatch.exists,
                      "the prior's marker")
        // the location sentence quotes the counted radius (= the badges' 10 km), not the prior's σ
        let loc = app.descendants(matching: .any)["plant-id-location"]
        XCTAssertTrue(loc.exists && loc.label.contains("within 10 km"), "location sentence: \(loc.label)")
        attachScreenshot("plant-id-results-species")
        // the top candidate opens the existing plant sheet
        let row = app.buttons["plant-id-candidate-0"]
        XCTAssertTrue(row.appears(within: wait))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plant-sheet"].appears(within: wait), "the plant sheet")
        XCTAssertTrue(app.staticTexts["plant-name"].appears(within: wait))
        attachScreenshot("plant-id-plant-sheet")
        // back to the results, then the credits
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let credits = app.buttons["plant-id-credits"]
        XCTAssertTrue(credits.appears(within: wait))
        for _ in 0 ..< 4 where !credits.isHittable { app.swipeUp() }
        credits.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-credits-headline"].appears(within: wait), "credits")
        // the model's licence and citation, one more step in
        let acks = app.buttons["acknowledgements-link"]
        XCTAssertTrue(acks.appears(within: wait))
        acks.tap()
        let bioclip = app.buttons["ack-bioclip"]
        XCTAssertTrue(bioclip.appears(within: wait), "acknowledgements list BioCLIP")
        bioclip.tap()
        let text = app.textViews["ack-text"]
        XCTAssertTrue(text.appears(within: wait))
        XCTAssertTrue(eventually(wait) { (text.value as? String)?.contains("Imageomics Institute") == true }, "the MIT notice")
        XCTAssertTrue((text.value as? String)?.contains("NEURIPS2025_94da80cb") == true, "the citation")
        attachScreenshot("plant-id-acknowledgements")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(bioclip.appears(within: wait))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(acks.appears(within: wait))
        // closing Identify lets the map's button come back
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["plant-id-close"].tap()
        XCTAssertTrue(eventually(wait) { app.buttons["plant-id-button"].isHittable }, "closed")
    }

    @MainActor
    func testGenusAnswerAndALabelWithoutAProfile() throws {
        let app = launch("genus")
        identify(app)
        let wait = patience(10)
        let answer = app.descendants(matching: .any)["plant-id-answer"]
        XCTAssertTrue(answer.appears(within: wait))
        XCTAssertTrue(answer.label.contains("species unsure"), "genus answer: \(answer.label)")
        // the genus's likeliest three, as tiles
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-genus-top"].exists)
        attachScreenshot("plant-id-results-genus")
        // Eucalyptus nitens has no Understorey Network profile: the minimal sheet
        let nitens = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'plant-id-candidate-' AND label CONTAINS 'nitens'")).firstMatch
        XCTAssertTrue(nitens.appears(within: wait))
        for _ in 0 ..< 4 where !nitens.isHittable { app.swipeUp() }
        nitens.tap()
        XCTAssertTrue(app.staticTexts["plant-id-noprofile-name"].appears(within: wait))
        XCTAssertTrue(app.staticTexts["Not in the Understorey Network guide"].exists)
        // Frame Again keeps the photo
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reframe = app.buttons["plant-id-reframe"]
        for _ in 0 ..< 4 where !reframe.isHittable { app.swipeUp() }
        reframe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-frame"].appears(within: wait))
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-framing-hint"].exists, "framing hint")
    }

    @MainActor
    func testNotSure() throws {
        let app = launch("unsure")
        identify(app)
        let answer = app.descendants(matching: .any)["plant-id-answer"]
        XCTAssertTrue(answer.appears(within: patience(10)))
        XCTAssertTrue(answer.label.contains("Not sure"), "answer: \(answer.label)")
        XCTAssertTrue(app.staticTexts["Closest matches"].exists)
        attachScreenshot("plant-id-results-unsure")
    }
}

/// Design screenshots of Identify with the REAL model on the evaluation's
/// CC0 sample photos — local only, and online (the candidates' Understorey
/// Network photos are fetched by the app, as on a phone): run with
/// `TEST_RUNNER_PLANTID_SHOTS=1` after `build_packs.py plantid`. Skipped
/// otherwise (CI has neither the model nor the photos).
final class PlantIDShotsUITests: XCTestCase {
    static let repo = "/Users/leo/izzy-map"
    static let model = "\(repo)/data/packs/stage-plantid/plantid"
    static let samples = "\(repo)/pipeline/cache/plantid/coreml/bioclip25/data/samples"

    @MainActor
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    private func run(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dataDir", "\(Self.repo)/data", "-debugPlantID", "YES", "-welcomeSeen", "YES"] + args
        app.launch()
        return app
    }

    @MainActor
    func testRealModelShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLANTID_SHOTS"] == "1", "design shots: TEST_RUNNER_PLANTID_SHOTS=1")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(Self.model)/v3-head.bin"), "no staged plantid pack")
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = pad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        // (photo, location, crop) — locations are the observations' own (test.parquet)
        let photos: [(String, String, String?)] = [
            ("637002849", " -43.475,146.642", nil),
            ("474508960", " -41.907,146.062", nil),
            ("594582089", " -41.806,147.507", nil),
        ]
        for (i, (id, loc, crop)) in photos.enumerated() {
            var args = ["-plantIDDir", Self.model, "-plantIDPhoto", "\(Self.samples)/\(id).jpg", "-plantIDLocation", loc]
            if let crop { args += ["-plantIDCrop", crop] }
            if i > 0 { args += ["-plantIDAutoIdentify", "YES"] }
            let app = run(args)
            if i == 0 {
                XCTAssertTrue(app.descendants(matching: .any)["plant-id-frame"].waitForExistence(timeout: 30))
                sleep(2)
                shot("framing-\(id)")
                let go = app.buttons["plant-id-identify"]
                XCTAssertTrue(eventually(180) { go.isEnabled })
                go.tap()
                sleep(1)
                shot("identifying-\(id)")
            }
            XCTAssertTrue(app.descendants(matching: .any)["plant-id-results"].waitForExistence(timeout: 240))
            sleep(6)  // the UN photos arrive
            shot("results-\(id)")
            if i == 0 {
                app.swipeUp()
                sleep(1)
                shot("results-\(id)-scrolled")
                app.buttons["plant-id-candidate-0"].tap()
                sleep(4)
                shot("plant-sheet-\(id)")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                let credits = app.buttons["plant-id-credits"]
                for _ in 0 ..< 4 where !credits.isHittable { app.swipeUp() }
                credits.tap()
                sleep(2)
                shot("credits")
            }
            app.terminate()
        }
        // the capture screen with the model still to come
        let app = run(["-fakePacks", "vector,topo,relief,refphotos,plantid=downloading:0.42"])
        XCTAssertTrue(app.descendants(matching: .any)["plant-id-model-status"].waitForExistence(timeout: 30))
        sleep(1)
        shot("capture-downloading")
        app.terminate()
        // a genus answer (the fake identifier over real UN species)
        let fake = run(["-plantIDFake", "genus", "-plantIDPhoto", "\(Self.samples)/594582089.jpg",
                        "-plantIDAutoIdentify", "YES", "-plantIDLocation", " -42.88,147.32"])
        XCTAssertTrue(fake.descendants(matching: .any)["plant-id-results"].waitForExistence(timeout: 60))
        sleep(6)
        shot("results-genus-fake")
    }

    /// The real model on the three CC0 samples, then the results scrolled
    /// up and down repeatedly, each swipe timed (XCUITest waits for the app
    /// to go idle after a gesture, so a busy main thread shows up as a slow
    /// swipe). Opt-in, like the shots: TEST_RUNNER_PLANTID_SCROLL=1, with
    /// the staged plantid pack. Profile alongside with `xctrace record
    /// --template 'Time Profiler' --attach <pid>`.
    @MainActor
    func testRealModelResultsScroll() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLANTID_SCROLL"] == "1", "TEST_RUNNER_PLANTID_SCROLL=1")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(Self.model)/v3-head.bin"), "no staged plantid pack")
        let photos = [("637002849", " -43.475,146.642"), ("474508960", " -41.907,146.062"), ("594582089", " -41.806,147.507")]
        var worst = 0.0
        for (id, loc) in photos {
            let app = run(["-plantIDDir", Self.model, "-plantIDPhoto", "\(Self.samples)/\(id).jpg", "-plantIDLocation", loc,
                           "-plantIDAutoIdentify", "YES"])
            XCTAssertTrue(app.descendants(matching: .any)["plant-id-results"].waitForExistence(timeout: 240))
            for round in 0 ..< 6 {
                for up in [true, false] {
                    let start = Date.now
                    if up { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
                    let took = Date.now.timeIntervalSince(start)
                    worst = max(worst, took)
                    print("PLANTID-SCROLL \(id) round \(round) \(up ? "up" : "down") \(String(format: "%.2f", took)) s")
                }
            }
            if id == photos[0].0 {
                // what the accessibility audit does on top: a full snapshot
                // of the results, then Apple's own audit (issues ignored —
                // only its cost is measured here)
                var start = Date.now
                _ = app.debugDescription
                print("PLANTID-SCROLL snapshot \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                start = Date.now
                try? app.performAccessibilityAudit { _ in true }
                print("PLANTID-SCROLL audit \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                for _ in 0 ..< 3 {
                    start = Date.now
                    app.swipeUp(velocity: .fast)
                    let took = Date.now.timeIntervalSince(start)
                    worst = max(worst, took)
                    print("PLANTID-SCROLL after-audit swipe \(String(format: "%.2f", took)) s")
                }
                // the 13k-observer credits list
                let credits = app.buttons["plant-id-credits"]
                for _ in 0 ..< 4 where !credits.isHittable { app.swipeUp() }
                start = Date.now
                credits.tap()
                XCTAssertTrue(app.descendants(matching: .any)["plant-id-credits-headline"].waitForExistence(timeout: 30))
                print("PLANTID-SCROLL credits open \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                for _ in 0 ..< 4 {
                    start = Date.now
                    app.swipeUp(velocity: .fast)
                    print("PLANTID-SCROLL credits swipe \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                }
                start = Date.now
                _ = app.debugDescription
                print("PLANTID-SCROLL credits snapshot \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                start = Date.now
                try? app.performAccessibilityAudit { _ in true }
                print("PLANTID-SCROLL credits audit \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                // back to the results, then the first candidate's plant sheet
                app.navigationBars.buttons.element(boundBy: 0).tap()
                let first = app.buttons["plant-id-candidate-0"]
                for _ in 0 ..< 4 where !first.isHittable { app.swipeDown() }
                first.tap()
                XCTAssertTrue(app.descendants(matching: .any)["plant-sheet"].waitForExistence(timeout: 30))
                start = Date.now
                try? app.performAccessibilityAudit { _ in true }
                print("PLANTID-SCROLL sheet audit \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s")
                for _ in 0 ..< 3 {
                    start = Date.now
                    app.swipeUp(velocity: .fast)
                    let took = Date.now.timeIntervalSince(start)
                    worst = max(worst, took)
                    print("PLANTID-SCROLL after-sheet-audit swipe \(String(format: "%.2f", took)) s")
                }
            }
            app.terminate()
        }
        print("PLANTID-SCROLL worst \(String(format: "%.2f", worst)) s")
        XCTAssertLessThan(worst, 5, "a swipe over the results waited > 5 s for the app")
    }

    /// The Diagnostics benchmark with the real model (pack + app copy, CPU
    /// only — the simulator has no Neural Engine and each load is ~20 s):
    /// the run starts only after the confirmation, writes a row per load
    /// and finishes. Opt-in: TEST_RUNNER_PLANTID_BENCH=1, with the staged
    /// plantid pack. Also checks that Identify's open was timed.
    @MainActor
    func testRealModelBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLANTID_BENCH"] == "1", "TEST_RUNNER_PLANTID_BENCH=1")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(Self.model)/v3-head.bin"), "no staged plantid pack")
        let app = run(["-plantIDDir", Self.model, "-plantIDBenchmarkUnits", "0"])
        let credits = app.buttons["plant-id-credits"]
        XCTAssertTrue(credits.waitForExistence(timeout: 30))
        credits.press(forDuration: 1.6)
        let bench = app.buttons["diagnostics-benchmark"]
        if !bench.waitForExistence(timeout: 5) {
            // the release also tapped the button: Credits on top of Diagnostics
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(bench.waitForExistence(timeout: 10), "Diagnostics with the benchmark button")
        let report = app.staticTexts["diagnostics-report"]
        let timed = eventually(30) { report.label.contains("Identify open: ") && !report.label.contains("Identify open: none") }
        XCTAssertTrue(timed, "the open of Identify was timed: \(report.label.prefix(1500))")
        // the identifier loading in the background: refused until it has loaded
        let text = app.staticTexts["diagnostics-benchmark-text"]
        let run = app.buttons["Run Benchmark"].firstMatch
        let started = eventually(120) {
            bench.tap()
            XCTAssertTrue(run.waitForExistence(timeout: 5), "the confirmation")
            run.tap()
            if eventually(3, { bench.label == "Benchmarking…" }) { return true }
            sleep(5)
            return false
        }
        XCTAssertTrue(started, "the benchmark started once the identifier had loaded")
        XCTAssertTrue(eventually(300) { bench.label != "Benchmarking…" }, "the benchmark finished")
        let result = text.label
        XCTAssertTrue(result.contains("footprint after release"), result)
        print("PLANTID-BENCH\n\(result)")
        XCTAssertTrue(result.contains("pack      CPU only"), result)
        XCTAssertTrue(result.contains("app copy  CPU only"), result)
        XCTAssertFalse(result.contains("failed"), result)
        shot("benchmark")
    }
}
