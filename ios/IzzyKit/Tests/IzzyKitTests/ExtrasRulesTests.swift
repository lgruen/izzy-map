import Foundation
import Testing
@testable import IzzyKit

@Suite struct ExtrasRulesTests {
    static let pdf = Data("%PDF-1.7\n".utf8)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])
    static let html = Data("<!doctype html><title>Log in</title>".utf8)

    static func items(_ n: Int, bytes: Int? = 100) -> [ExtraItem] {
        (0 ..< n).map { ExtraItem(id: "f\($0)", url: URL(string: "https://example.org/\($0)")!, bytes: bytes) }
    }
    static func ok(_ head: Data) -> FetchResult { .response(status: 200, head: head, allowedHost: true) }

    @Test func sniffing() {
        #expect(ContentSniff.isPDF(Self.pdf))
        #expect(!ContentSniff.isPDF(Self.html))
        #expect(ContentSniff.isImage(Self.jpeg))
        #expect(ContentSniff.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
        #expect(ContentSniff.isImage(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)))
        #expect(ContentSniff.isImage(Data("GIF89a".utf8)))
        #expect(!ContentSniff.isImage(Self.html))
        #expect(!ContentSniff.isImage(Data()))
    }

    @Test func verdictsPerKind() {
        // ArcGIS: a removed item is 400 + HTML; any 4xx is gone; 5xx skips
        #expect(FetchVerdict.of(.response(status: 400, head: Self.html, allowedHost: true), kind: .sheets) == .gone)
        #expect(FetchVerdict.of(.response(status: 403, head: Self.html, allowedHost: true), kind: .sheets) == .gone)
        #expect(FetchVerdict.of(.response(status: 503, head: Self.html, allowedHost: true), kind: .sheets) == .skip(status: 503))
        // a sheet answering 200 HTML is gone (counts as done); a photo's is a captive portal
        #expect(FetchVerdict.of(Self.ok(Self.html), kind: .sheets) == .gone)
        #expect(FetchVerdict.of(Self.ok(Self.html), kind: .photos) == .captivePortal)
        #expect(FetchVerdict.of(Self.ok(Self.html), kind: .f2f) == .captivePortal)
        // photos: only a readable 404/410 is gone
        #expect(FetchVerdict.of(.response(status: 404, head: Data(), allowedHost: true), kind: .photos) == .gone)
        #expect(FetchVerdict.of(.response(status: 410, head: Data(), allowedHost: true), kind: .photos) == .gone)
        #expect(FetchVerdict.of(.response(status: 403, head: Data(), allowedHost: true), kind: .photos) == .skip(status: 403))
        // a redirect off the publisher's host is never stored
        #expect(FetchVerdict.of(.response(status: 200, head: Self.jpeg, allowedHost: false), kind: .photos) == .captivePortal)
        #expect(FetchVerdict.of(Self.ok(Self.jpeg), kind: .photos) == .store)
        #expect(FetchVerdict.of(Self.ok(Self.pdf), kind: .f2f) == .store)
        #expect(FetchVerdict.of(.offline, kind: .f2f) == .offline)
        // soil reports: F2F's rules — any 4xx gone, a 200 that isn't a PDF
        // or ends off the publisher is a login page, 5xx skips
        #expect(FetchVerdict.of(.response(status: 404, head: Self.html, allowedHost: true), kind: .soilReports) == .gone)
        #expect(FetchVerdict.of(.response(status: 403, head: Self.html, allowedHost: true), kind: .soilReports) == .gone)
        #expect(FetchVerdict.of(.response(status: 500, head: Data(), allowedHost: true), kind: .soilReports) == .skip(status: 500))
        #expect(FetchVerdict.of(Self.ok(Self.html), kind: .soilReports) == .captivePortal)
        #expect(FetchVerdict.of(.response(status: 200, head: Self.pdf, allowedHost: false), kind: .soilReports) == .captivePortal)
        #expect(FetchVerdict.of(Self.ok(Self.pdf), kind: .soilReports) == .store)
    }

    @Test func soilReportsFollowF2FsPolicy() {
        let soil = ExtraKind.soilReports.policy, f2f = ExtraKind.f2f.policy
        #expect(soil == f2f)
        #expect(soil.concurrency == 1 && soil.goneStreakLimit == 3 && soil.goneStatuses == .allClientErrors)
        #expect(!soil.wrongTypeIsGone)
        #expect(ExtraKind.soilReports.expected == .pdf)
        // persisted names: task descriptions, gone-mark files, the folder
        #expect(ExtraKind.soilReports.rawValue == "soil-reports" && ExtraKind.soilReports.folder == "soil-reports")
        #expect(ExtraKind(rawValue: "soil-reports") == .soilReports)
        #expect(Set(ExtraKind.allCases.map(\.folder)).count == ExtraKind.allCases.count)
    }

    @Test func hostsAllowed() {
        #expect(ExtrasCatalog.allows(host: "database.understorey-network.org.au", for: .photos))
        #expect(!ExtrasCatalog.allows(host: "evil.example", for: .photos))
        #expect(!ExtrasCatalog.allows(host: nil, for: .photos))
        #expect(ExtrasCatalog.allows(host: "nre.tas.gov.au", for: .f2f))
        #expect(ExtrasCatalog.allows(host: "arcgis-content.s3.amazonaws.com", for: .sheets))
        #expect(ExtrasCatalog.allows(host: "www.arcgis.com", for: .sheets))
        #expect(ExtrasCatalog.sheetURL("ab12")?.absoluteString == "https://www.arcgis.com/sharing/rest/content/items/ab12/data")
        #expect(ExtrasCatalog.sheetURL("../etc") == nil)
        // soil reports: NRE's data library, new and old names, nothing else
        #expect(ExtrasCatalog.allows(host: "nrmdatalibrary.nre.tas.gov.au", for: .soilReports))
        #expect(ExtrasCatalog.allows(host: "NRMDataLibrary.dpipwe.tas.gov.au", for: .soilReports))
        #expect(!ExtrasCatalog.allows(host: "nre.tas.gov.au", for: .soilReports))
        #expect(!ExtrasCatalog.allows(host: "evil.nrmdatalibrary.nre.tas.gov.au", for: .soilReports))
        #expect(!ExtrasCatalog.allows(host: "nrmdatalibrary.nre.tas.gov.au.evil.example", for: .soilReports))
        #expect(!ExtrasCatalog.allows(host: nil, for: .soilReports))
        // and their hosts open nothing else
        #expect(!ExtrasCatalog.allows(host: "nrmdatalibrary.nre.tas.gov.au", for: .f2f))
        #expect(!ExtrasCatalog.allows(host: "nrmdatalibrary.nre.tas.gov.au", for: .sheets))
        let report = URL(string: "https://nrmdatalibrary.nre.tas.gov.au/FactSheets/WfW/SoilReports/Hobart_report.pdf")!
        #expect(ExtrasCatalog.soilReportURL(key: "hobart", url: report) == report)
        #expect(ExtrasCatalog.soilReportURL(key: "south-esk", url: report) == report)
        #expect(ExtrasCatalog.soilReportURL(key: "../hobart", url: report) == nil)
        #expect(ExtrasCatalog.soilReportURL(key: "Hobart", url: report) == nil)
        #expect(ExtrasCatalog.soilReportURL(key: "", url: report) == nil)
        #expect(ExtrasCatalog.soilReportURL(key: "hobart", url: URL(string: "http://nrmdatalibrary.nre.tas.gov.au/x.pdf")!) == nil)
        #expect(ExtrasCatalog.soilReportURL(key: "hobart", url: URL(string: "https://evil.example/Hobart_report.pdf")!) == nil)
        #expect(ExtrasCatalog.soilReportFileName("south-esk") == "south-esk.pdf")
    }

    @Test func resumeSkipsPresentGoneAndSkippedFiles() {
        let items = Self.items(5)
        var gone = GoneMarks()
        gone.mark("f1")
        let b = ExtrasBatch(kind: .sheets, items: items, present: ["f0"], gone: gone, skippedThisSession: ["f2"])
        #expect(b.todo.map(\.id) == ["f3", "f4"])
        #expect(b.done == 2)  // present + gone
        #expect(b.bytesPresent == 100)
        #expect(b.bytesRemaining == 200)
        let all = ExtrasBatch(kind: .sheets, items: items, present: Set(items.map(\.id)), gone: GoneMarks())
        #expect(all.phase == .finished)
    }

    @Test func goneCountsAsDoneAndAStoreForgetsTheMark() {
        var gone = GoneMarks()
        gone.mark("f0")
        var b = ExtrasBatch(kind: .sheets, items: Self.items(3), present: [], gone: GoneMarks())
        b.record("f0", .response(status: 400, head: Self.html, allowedHost: true))
        b.record("f1", Self.ok(Self.pdf))
        b.record("f2", Self.ok(Self.pdf))
        #expect(b.phase == .finished)
        #expect(b.gone.contains("f0"))
        #expect(b.statusText == "✓ downloaded · 1 sheet no longer published")
        // a tap/batch success forgets an old mark
        var again = ExtrasBatch(kind: .sheets, items: Self.items(1), present: [], gone: GoneMarks())
        again.record("f0", .response(status: 404, head: Data(), allowedHost: true))
        #expect(again.gone.contains("f0"))
    }

    @Test(arguments: [(ExtraKind.sheets, 5), (.photos, 10), (.f2f, 3), (.soilReports, 3)])
    func aGoneStreakIsACaptivePortal(kind: ExtraKind, limit: Int) {
        var b = ExtrasBatch(kind: kind, items: Self.items(limit + 3), present: [], gone: GoneMarks())
        // one stored breaks a streak
        b.record("f0", .response(status: 404, head: Data(), allowedHost: true))
        b.record("f1", Self.ok(kind == .photos ? Self.jpeg : Self.pdf))
        #expect(b.gone.contains("f0"))
        for i in 2 ..< 2 + limit - 1 {
            b.record("f\(i)", .response(status: 404, head: Data(), allowedHost: true))
            #expect(b.phase == .running)
        }
        let verdict = b.record("f\(limit + 1)", .response(status: 404, head: Data(), allowedHost: true))
        #expect(verdict == .captivePortal)
        #expect(b.phase == .stopped(.captivePortal))
        // the streak's marks are undone; the earlier, isolated one stays
        #expect(b.gone.count == 1)
        #expect(b.gone.contains("f0"))
        // nothing after a stop changes the batch
        b.record("f\(limit + 2)", Self.ok(Self.jpeg))
        #expect(!b.present.contains("f\(limit + 2)"))
        #expect(b.statusText == "Stopped — a Wi-Fi login page may be in the way.")
    }

    @Test func nonImageStopsPhotosAndServerErrorsSkip() {
        var b = ExtrasBatch(kind: .photos, items: Self.items(4), present: [], gone: GoneMarks())
        b.record("f0", .response(status: 502, head: Data(), allowedHost: true))
        #expect(b.phase == .running)
        b.record("f1", Self.ok(Self.jpeg))
        b.record("f2", Self.ok(Self.jpeg))
        b.record("f3", Self.ok(Self.jpeg))
        #expect(b.phase == .finished)
        #expect(b.statusText == "✓ downloaded · 1 photo failed, will retry next time the app opens")
        var portal = ExtrasBatch(kind: .photos, items: Self.items(3), present: [], gone: GoneMarks())
        portal.record("f0", Self.ok(Self.html))
        #expect(portal.phase == .stopped(.captivePortal))
        #expect(portal.present.isEmpty)
    }

    @Test func offlineAndCancelStopAndKeepWhatArrived() {
        var b = ExtrasBatch(kind: .f2f, items: Self.items(3, bytes: nil), present: [], gone: GoneMarks())
        b.record("f0", Self.ok(Self.pdf))
        b.record("f1", .offline)
        #expect(b.phase == .stopped(.offline))
        #expect(b.present == ["f0"])
        var c = ExtrasBatch(kind: .f2f, items: Self.items(3), present: [], gone: GoneMarks())
        c.cancel()
        #expect(c.phase == .stopped(.cancelled))
        #expect(c.statusText == "0.0\u{00A0}MB of 0.0\u{00A0}MB on this device")
        var reports = ExtrasBatch(kind: .soilReports, items: Self.items(3), present: [], gone: GoneMarks())
        reports.record("f0", .response(status: 404, head: Self.html, allowedHost: true))
        reports.record("f1", Self.ok(Self.pdf))
        reports.record("f2", Self.ok(Self.pdf))
        #expect(reports.statusText == "✓ downloaded · 1 report no longer published")
    }

    @Test func spacePreflight() {
        var b = ExtrasBatch(kind: .sheets, items: Self.items(3, bytes: 100_000_000), present: ["f0"], gone: GoneMarks())
        b.preflight(freeBytes: 250_000_000, margin: 100_000_000)
        #expect(b.phase == .stopped(.needsSpace(bytes: 200_000_000)))
        #expect(b.statusText == "Not enough free space — needs about 200\u{00A0}MB free.")
        var fine = ExtrasBatch(kind: .sheets, items: Self.items(3, bytes: 100_000_000), present: ["f0"], gone: GoneMarks())
        fine.preflight(freeBytes: 1_000_000_000, margin: 100_000_000)
        #expect(fine.phase == .running)
        var unknown = ExtrasBatch(kind: .sheets, items: Self.items(1), present: [], gone: GoneMarks())
        unknown.preflight(freeBytes: nil)
        #expect(unknown.phase == .running)
    }

    @Test func totalsUseTheMeanForUnknownSizes() {
        var items = Self.items(3)
        items[2].bytes = nil
        #expect(ExtrasCatalog.totalBytes(items) == 300)
        #expect(ExtrasText.megabytes(152_058_880) == "152\u{00A0}MB")
        #expect(ExtrasText.megabytes(600_000) == "0.6\u{00A0}MB")
    }

    @Test func realBatchesFromTheBundledTables() throws {
        let catalog = try TestData.catalog()
        let photos = ExtrasCatalog.photos(catalog.plants)
        #expect(photos.count >= 990 && photos.count <= 1_100)  // 997 on 2026-10-25
        #expect(Set(photos.map(\.id)).count == photos.count)
        #expect(photos.allSatisfy { $0.url.host() == PlantPhoto.host })
        let total = ExtrasCatalog.totalBytes(photos)
        #expect(total > 120_000_000 && total < 200_000_000)  // ~152 MB
        let trees = try TestData.data.trees()
        let sheets = ExtrasCatalog.sheets(trees)
        #expect(sheets.count == trees.sheets.count)
        #expect(sheets.allSatisfy { $0.url.host() == "www.arcgis.com" && $0.id.hasSuffix(".pdf") })
        let f2f = ExtrasCatalog.f2f(try TestData.data.f2fIndex())
        #expect(f2f.count == 11)
        #expect(f2f.allSatisfy { $0.url.host() == "nre.tas.gov.au" })
        // soil reports: one per map sheet, straight from soil_units.json
        let soils = try TestData.data.soilUnits()
        let reports = ExtrasCatalog.soilReports(soils)
        #expect(reports.count == 11 && soils.sheets.count == 11)
        #expect(Set(reports.map(\.id)).count == reports.count)
        #expect(Set(reports.map(\.id)) == Set(soils.sheets.keys.map { "\($0).pdf" }))
        #expect(reports.allSatisfy { ExtrasCatalog.allows(host: $0.url.host(), for: .soilReports) && $0.url.scheme == "https" })
        #expect(reports.allSatisfy { ($0.bytes ?? 0) > 100_000 })
        let reportBytes = soils.sheets.values.reduce(0) { $0 + $1.bytes }
        #expect(ExtrasCatalog.totalBytes(reports) == reportBytes)
        #expect(reportBytes > 25_000_000 && reportBytes < 40_000_000)  // 29.8 MB on 2026-11-18
        let southEsk = try #require(reports.first { $0.id == "south-esk.pdf" })
        #expect(southEsk.url.lastPathComponent == "South_Esk_report.pdf")
        let batch = ExtrasBatch(kind: .soilReports, items: reports, present: [], gone: GoneMarks())
        #expect(batch.statusText == "report 1 of 11 · 0.0\u{00A0}MB of 30\u{00A0}MB")
    }

    @Test(arguments: [(ExtraKind.f2f, 1), (.photos, 4), (.sheets, 2), (.soilReports, 1)])
    func windowsOfTheKindsConcurrency(kind: ExtraKind, window: Int) {
        var b = ExtrasBatch(kind: kind, items: Self.items(10), present: [], gone: GoneMarks())
        var started: [String] = []
        while let item = b.nextToStart() { started.append(item.id) }
        #expect(started == (0 ..< window).map { "f\($0)" })
        // one completion frees one slot
        b.record("f0", Self.ok(kind == .photos ? Self.jpeg : Self.pdf))
        #expect(b.nextToStart()?.id == "f\(window)")
        #expect(b.nextToStart() == nil)
        // a task left running by an earlier launch takes a slot, is never started twice
        var resumed = ExtrasBatch(kind: kind, items: Self.items(10), present: [], gone: GoneMarks())
        let adopted = resumed.markInFlight("f0"), unknown = resumed.markInFlight("nope")
        #expect(adopted && !unknown)
        var next: [String] = []
        while let item = resumed.nextToStart() { next.append(item.id) }
        #expect(!next.contains("f0"))
        #expect(next.count == window - 1)
    }

    @Test func oneStallOrBrokenTransferRetriesBeforeItCounts() {
        var b = ExtrasBatch(kind: .photos, items: Self.items(3), present: [], gone: GoneMarks())
        _ = b.nextToStart()
        b.record("f0", .timedOut)
        #expect(b.phase == .running)
        // the stalled file goes out again first
        #expect(b.nextToStart()?.id == "f0")
        b.record("f0", .failed)
        #expect(b.phase == .running)
        _ = b.nextToStart()
        b.record("f0", .failed)  // third failure: skipped for the session
        #expect(b.phase == .running)
        #expect(b.skipped == ["f0"])
        b.record("f1", Self.ok(Self.jpeg))
        // a file that stalls every time stops the batch as "needs reception"
        for _ in 0 ... ExtraKind.photos.policy.retries { b.record("f2", .timedOut) }
        #expect(b.phase == .stopped(.offline))
        #expect(b.present == ["f1"])
        // no network path is never retried
        var off = ExtrasBatch(kind: .sheets, items: Self.items(3), present: [], gone: GoneMarks())
        off.record("f0", .offline)
        #expect(off.phase == .stopped(.offline))
        // a completion for a file the batch isn't waiting for changes nothing
        var other = ExtrasBatch(kind: .sheets, items: Self.items(2), present: [], gone: GoneMarks())
        other.record("elsewhere", .offline)
        #expect(other.phase == .running)
    }

    @Test func transientVerdicts() {
        #expect(FetchVerdict.captivePortal.isTransient && FetchVerdict.offline.isTransient)
        #expect(FetchVerdict.timedOut.isTransient && FetchVerdict.cancelled.isTransient)
        #expect(!FetchVerdict.gone.isTransient && !FetchVerdict.skip(status: 500).isTransient)
        #expect(!FetchVerdict.failed.isTransient && !FetchVerdict.store.isTransient)
    }

    @Test func aBatchsMarksMergeWithoutClobberingATapsMarks() {
        let t0 = Date(timeIntervalSince1970: 0), t1 = Date(timeIntervalSince1970: 100)
        let before = GoneMarks(["a": t0, "b": t0])
        let after = GoneMarks(["a": t0, "c": t1])  // b forgotten, c marked
        var file = GoneMarks(["a": t0, "b": t0, "tap": t1])  // a tap marked "tap" meanwhile
        file.apply(from: before, to: after)
        #expect(file == GoneMarks(["a": t0, "c": t1, "tap": t1]))
    }

    @Test func f2fChaptersCarryTheirSizes() throws {
        let index = try TestData.data.f2fIndex()
        let f2f = ExtrasCatalog.f2f(index)
        #expect(f2f.allSatisfy { ($0.bytes ?? 0) > 500_000 })
        let total = ExtrasCatalog.totalBytes(f2f)
        #expect(total > 25_000_000 && total < 45_000_000)  // 30.4 MB on 2026-11-03
        let b = ExtrasBatch(kind: .f2f, items: f2f, present: [], gone: GoneMarks())
        #expect(b.statusText.hasSuffix("0.0\u{00A0}MB of 30\u{00A0}MB"))
        // an index without sizes still decodes (the field is additive)
        let old = #"{"baseUrl":"https://nre.tas.gov.au/Documents/","index":{"DOB":{"file":"f2f_dry_eucalypt.pdf","page":3}}}"#
        let decoded = try JSONDecoder().decode(F2FIndex.self, from: Data(old.utf8))
        #expect(decoded.sizes == nil)
        #expect(ExtrasCatalog.f2f(decoded).first?.bytes == nil)
    }

    @Test func wholeTransferCeilingFollowsTheDeclaredSize() throws {
        #expect(ExtrasTimeouts.resourceCeiling(bytes: nil) == 600)
        #expect(ExtrasTimeouts.resourceCeiling(bytes: 0) == 600)
        // the ladder: rounded up to 600 × 2ⁿ
        #expect(ExtrasTimeouts.resourceCeiling(bytes: 6_660_000) == 600)
        #expect(ExtrasTimeouts.resourceCeiling(bytes: 6_670_000) == 1_200)
        #expect(ExtrasTimeouts.resourceCeiling(bytes: 60_000_000) == 9_600)
        // every F2F chapter (largest 6.62 MB) and every plant photo: 600 s
        let f2f = ExtrasCatalog.f2f(try TestData.data.f2fIndex())
        let largestChapter = try #require(f2f.compactMap(\.bytes).max())
        #expect(largestChapter > 6_000_000 && largestChapter < 6_660_000)
        #expect(f2f.allSatisfy { ExtrasTimeouts.resourceCeiling(bytes: $0.bytes) == 600 })
        let photos = ExtrasCatalog.photos(try TestData.catalog().plants)
        #expect(photos.allSatisfy { ExtrasTimeouts.resourceCeiling(bytes: $0.bytes) == 600 })
        // the largest tree sheet (7.11 MB ≈ 640 s at 11.1 kB/s) is on the 1,200 s rung
        let sheets = ExtrasCatalog.sheets(try TestData.data.trees())
        let largestSheet = try #require(sheets.max { ($0.bytes ?? 0) < ($1.bytes ?? 0) })
        #expect(ExtrasTimeouts.resourceCeiling(bytes: largestSheet.bytes) == 1_200)
        // the 20.2 MB South Esk report (≈ 1,815 s) is on the 2,400 s rung
        let reports = ExtrasCatalog.soilReports(try TestData.data.soilUnits())
        let southEsk = try #require(reports.first { $0.id == "south-esk.pdf" })
        #expect(ExtrasTimeouts.resourceCeiling(bytes: southEsk.bytes) == 2_400)
        // one foreground session per distinct ceiling: three for today's
        // tables — a table change that mints another session shows up here
        let all = f2f + photos + sheets + reports
        let ceilings = Set(all.map { ExtrasTimeouts.resourceCeiling(bytes: $0.bytes) })
        #expect(ceilings == [600, 1_200, 2_400])
    }

    @Test func goneMarksRoundTrip() throws {
        var g = GoneMarks()
        g.mark("a", on: Date(timeIntervalSince1970: 1_000))
        let back = try JSONDecoder().decode(GoneMarks.self, from: JSONEncoder().encode(g))
        #expect(back == g)
        g.forget("a")
        #expect(g.count == 0)
    }
}
