import CloudKit
import Foundation
import SwiftData
import Testing
@testable import IzzyMap

@MainActor
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "izzymap-pinsync-\(UUID().uuidString)")!
}

/// When the store syncs: only the app's own file in a device build. The
/// simulator, tests, `-pinsStore` and in-memory stores never touch CloudKit.
@MainActor
@Suite struct PinSyncConfigurationTests {
    @Test func theSimulatorAndTestsNeverSync() throws {
        #expect(!PinCloud.isDeviceBuild)
        // this test host's own launch choice
        let choice = PinStore.storeChoice()
        #expect(!choice.syncs)
        let memory = PinStore.inMemory(defaults: freshDefaults())
        #expect(memory.sync == nil)
        #expect(memory.container.configurations.first?.cloudKitContainerIdentifier == nil)
        // an on-disk store opened the default way is local too
        let dir = URL.temporaryDirectory.appending(path: "pinsync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = PinStore.makeContainer(url: dir.appending(path: "Pins.store"))
        #expect(!opened.failed && opened.error == nil)
        #expect(opened.container.configurations.first?.cloudKitContainerIdentifier == nil)
    }

    @Test func onlyTheDefaultFileInADeviceBuildSyncs() {
        let none = freshDefaults()
        #expect(PinStore.storeChoice(args: none, deviceBuild: false) == (PinStore.defaultStoreURL(), false))
        let device = PinStore.storeChoice(args: none, deviceBuild: true)
        #expect(device.url == PinStore.defaultStoreURL() && device.syncs)

        let custom = freshDefaults()
        custom.set("/tmp/ui-test/Pins.store", forKey: "pinsStore")
        let test = PinStore.storeChoice(args: custom, deviceBuild: true)
        #expect(test.url?.path(percentEncoded: false) == "/tmp/ui-test/Pins.store" && !test.syncs)

        let memory = freshDefaults()
        memory.set(true, forKey: "pinsInMemory")
        let inMemory = PinStore.storeChoice(args: memory, deviceBuild: true)
        #expect(inMemory.url == nil && !inMemory.syncs)
    }

    /// The configuration a syncing store gets names the container (built,
    /// never opened: opening needs the device entitlements).
    @Test func aSyncingConfigurationNamesThePrivateContainer() {
        let url = URL.temporaryDirectory.appending(path: "never-opened.store")
        let on = ModelConfiguration(schema: PinStore.schema, url: url, cloudKitDatabase: PinCloud.database(syncs: true))
        #expect(on.cloudKitContainerIdentifier == PinCloud.containerID)
        let off = ModelConfiguration(schema: PinStore.schema, url: url, cloudKitDatabase: PinCloud.database(syncs: false))
        #expect(off.cloudKitContainerIdentifier == nil)
        #expect(PinCloud.containerID == "iCloud.org.gruenschloss.izzymap")
    }
}

/// Mirroring errors → the Pins screen's words, partial failures unwrapped.
@Suite struct PinSyncErrorTests {
    private func ck(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    private func partial(_ errors: [NSError]) -> NSError {
        var byID: [CKRecord.ID: NSError] = [:]
        for (i, e) in errors.enumerated() { byID[CKRecord.ID(recordName: "r\(i)")] = e }
        return ck(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: byID])
    }

    @Test func plainCloudKitErrors() {
        #expect(PinSyncErrors.classify(ck(.quotaExceeded)) == PinSyncFailure(problem: .storageFull, code: "CKErrorDomain 25", message: ck(.quotaExceeded).localizedDescription))
        #expect(PinSyncErrors.classify(ck(.notAuthenticated)).problem == .notSignedIn)
        #expect(PinSyncErrors.classify(ck(.networkUnavailable)).problem == .offline)
        #expect(PinSyncErrors.classify(ck(.networkFailure)).problem == .offline)
        let other = PinSyncErrors.classify(ck(.serverRejectedRequest))
        #expect(other.problem == .failed && other.code == "CKErrorDomain \(CKError.Code.serverRejectedRequest.rawValue)")
    }

    @Test func partialFailuresAreUnwrappedAndTheMostTellingWins() {
        #expect(PinSyncErrors.classify(partial([ck(.networkFailure), ck(.quotaExceeded), ck(.serverRecordChanged)])).problem == .storageFull)
        #expect(PinSyncErrors.classify(partial([ck(.serverRecordChanged), ck(.notAuthenticated)])).problem == .notSignedIn)
        // nothing recognised: "failed", with the inner error's code, not the wrapper's
        let unknown = PinSyncErrors.classify(partial([ck(.serverRecordChanged)]))
        #expect(unknown.problem == .failed && unknown.code == "CKErrorDomain \(CKError.Code.serverRecordChanged.rawValue)")
    }

    @Test func wrappedAndNetworkErrors() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_400, userInfo: [NSUnderlyingErrorKey: partial([ck(.quotaExceeded)])])
        #expect(PinSyncErrors.classify(wrapped).problem == .storageFull)
        #expect(PinSyncErrors.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)).problem == .offline)
        let plain = PinSyncErrors.classify(NSError(domain: "Other", code: 7))
        #expect(plain.problem == .failed && plain.code == "Other 7")
    }
}

/// What the mirroring said → one status; the line's words for each.
@MainActor
@Suite struct PinSyncStatusTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(_ kind: PinSyncEvent.Kind, at seconds: Double, ok: Bool, _ problem: PinSyncProblem? = nil) -> PinSyncEvent {
        PinSyncEvent(kind: kind, start: t0.addingTimeInterval(seconds - 1), end: t0.addingTimeInterval(seconds), succeeded: ok,
                     failure: problem.map { PinSyncFailure(problem: $0, code: "CKErrorDomain 0", message: "test") })
    }

    @Test func statusFollowsTheAccountThenFailuresThenTheLastSync() {
        var log = PinSyncLog()
        #expect(PinSyncStatus.derive(account: .available, log: log) == .starting)
        #expect(PinSyncStatus.derive(account: .unknown, log: log) == .starting)
        log.record(event(.setup, at: 1, ok: true))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .starting)
        log.record(event(.export, at: 10, ok: true))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .synced(t0.addingTimeInterval(10)))
        log.record(event(.import, at: 20, ok: true))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .synced(t0.addingTimeInterval(20)))
        // storage full on export: an import's success doesn't clear it, an export's does
        log.record(event(.export, at: 30, ok: false, .storageFull))
        log.record(event(.import, at: 40, ok: true))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .problem(.storageFull))
        log.record(event(.export, at: 50, ok: true))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .synced(t0.addingTimeInterval(50)))
        // a lost connection is over once anything succeeds again
        log.record(event(.export, at: 60, ok: false, .offline))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .problem(.offline))
        log.record(event(.import, at: 70, ok: true))
        #expect(PinSyncStatus.derive(account: .available, log: log) == .synced(t0.addingTimeInterval(70)))
        // the account wins over everything
        #expect(PinSyncStatus.derive(account: .noAccount, log: log) == .accountOff)
        #expect(PinSyncStatus.derive(account: .restricted, log: log) == .restricted)
        #expect(PinSyncStatus.derive(account: .temporarilyUnavailable, log: log) == .needsAttention)
        #expect(PinSyncStatus.derive(account: .couldNotDetermine(nil), log: log) == .synced(t0.addingTimeInterval(70)))
    }

    @Test func severalFailuresTellTheMostTellingOne() {
        var log = PinSyncLog()
        log.record(event(.import, at: 1, ok: false, .offline))
        log.record(event(.export, at: 2, ok: false, .failed))
        log.record(event(.setup, at: 3, ok: false, .notSignedIn))
        #expect(log.currentFailure?.problem == .notSignedIn)
    }

    @Test func theLogKeepsTenEventsAndSurvivesARelaunch() {
        let defaults = freshDefaults()
        let sync = PinSync(defaults: defaults)
        for i in 0 ..< 13 { sync.record(event(.import, at: Double(i), ok: true)) }
        #expect(sync.log.events.count == PinSyncLog.eventsKept)
        #expect(sync.log.events.first?.end == t0.addingTimeInterval(3))
        let again = PinSync(defaults: defaults)
        #expect(again.log == sync.log)
        #expect(again.account == .unknown)
    }

    @Test func eachStatusHasItsLine() {
        let now = t0.addingTimeInterval(3600 * 12)
        let device = "iPhone"
        #expect(PinSyncText.line(.localOnly, now: now, device: device) == "On this iPhone only")
        #expect(PinSyncText.line(.localOnly, now: now, device: "iPad") == "On this iPad only")
        #expect(PinSyncText.line(.accountOff, now: now, device: device) == "iCloud is off on this iPhone — pins stay here")
        #expect(PinSyncText.line(.restricted, now: now, device: device) == "iCloud is restricted on this iPhone — pins stay here")
        #expect(PinSyncText.line(.needsAttention, now: now, device: device) == "Sign in to iCloud again in Settings — pins stay here")
        #expect(PinSyncText.line(.problem(.storageFull), now: now, device: device) == "iCloud storage is full")
        #expect(PinSyncText.line(.problem(.notSignedIn), now: now, device: device) == "Not signed in to iCloud")
        #expect(PinSyncText.line(.problem(.offline), now: now, device: device) == "Waiting for a connection")
        #expect(PinSyncText.line(.problem(.failed), now: now, device: device) == "iCloud sync failed")
        #expect(PinSyncText.line(.starting, now: now, device: device) == "iCloud sync is on")
        #expect(PinSyncText.line(.synced(now.addingTimeInterval(-20)), now: now, device: device) == "Last synced with iCloud · just now")
        #expect(PinSyncText.line(.synced(now.addingTimeInterval(-150)), now: now, device: device) == "Last synced with iCloud · 2 min ago")
    }

    @Test func agoInFixedWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Hobart")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 12))!
        #expect(PinSyncText.ago(noon.addingTimeInterval(-59), now: noon, calendar: calendar) == "just now")
        #expect(PinSyncText.ago(noon.addingTimeInterval(-60), now: noon, calendar: calendar) == "1 min ago")
        #expect(PinSyncText.ago(noon.addingTimeInterval(-3599), now: noon, calendar: calendar) == "59 min ago")
        #expect(PinSyncText.ago(noon.addingTimeInterval(-3 * 3600), now: noon, calendar: calendar) == "3 h ago")
        #expect(PinSyncText.ago(noon.addingTimeInterval(-20 * 3600), now: noon, calendar: calendar) == "yesterday")
        let older = noon.addingTimeInterval(-5 * 86_400)
        #expect(PinSyncText.ago(older, now: noon, calendar: calendar) == PinText.shortDate(older, now: noon, calendar: calendar))
    }

    /// The Pins screen reads the store's watcher (injected here, never started).
    @Test func theStoresWatcherDrivesTheLine() {
        let sync = PinSync(defaults: freshDefaults())
        let store = PinStore(container: PinStore.makeContainer(url: nil).container, sync: sync, defaults: freshDefaults())
        #expect(PinSyncText.line(store.sync?.status ?? .localOnly, now: t0, device: "iPhone") == "iCloud sync is on")
        sync.setAccount(.noAccount)
        #expect(PinSyncText.line(store.sync!.status, now: t0, device: "iPhone") == "iCloud is off on this iPhone — pins stay here")
        sync.setAccount(.available)
        sync.record(event(.export, at: 0, ok: true))
        #expect(PinSyncText.line(store.sync!.status, now: t0.addingTimeInterval(240), device: "iPhone") == "Last synced with iCloud · 4 min ago")
        let local = PinStore.inMemory(defaults: freshDefaults())
        #expect(PinSyncText.line(local.sync?.status ?? .localOnly, now: t0, device: "iPhone") == "On this iPhone only")
    }

    /// Storage's footer claims iCloud only when the status says it synced.
    @Test func theStorageFooterFollowsTheStatus() {
        let base = "Your pins, notes, photos and projects, kept on this iPhone and in its backups"
        #expect(PinSyncText.storageFooter(.localOnly, now: t0, device: "iPhone") == base + ".")
        #expect(PinSyncText.storageFooter(.synced(t0), now: t0, device: "iPhone") == base + ", and synced with your iCloud.")
        #expect(PinSyncText.storageFooter(.starting, now: t0, device: "iPhone") == base + ". iCloud sync is on.")
        #expect(PinSyncText.storageFooter(.accountOff, now: t0, device: "iPhone") == base + ". iCloud is off on this iPhone — pins stay here.")
        #expect(PinSyncText.storageFooter(.problem(.storageFull), now: t0, device: "iPhone") == base + ". iCloud storage is full.")
    }

    /// A finished import re-reads the store (a mirroring import is no
    /// `ModelContext.didSave`); failed imports and exports don't.
    @Test func aFinishedImportReloadsTheStore() throws {
        let sync = PinSync(defaults: freshDefaults())
        let store = PinStore(container: PinStore.makeContainer(url: nil).container, sync: sync, defaults: freshDefaults())
        // a row written underneath, as an import would (its own context)
        let other = ModelContext(store.container)
        other.insert(SavedPin(lat: -42.9, lon: 147.3, placedBy: .map, project: nil, now: t0))
        try other.save()
        var revision = store.revision, saves = store.saves
        sync.record(event(.export, at: 1, ok: true))
        sync.record(event(.import, at: 2, ok: false, .offline))
        #expect(store.revision == revision && store.saves == saves)
        sync.record(event(.import, at: 3, ok: true))
        #expect(store.revision > revision && store.saves == saves + 1)
        #expect(store.pins.count == 1)
        revision = store.revision
        saves = store.saves
        sync.record(event(.import, at: 4, ok: true))
        #expect(store.revision > revision && store.saves == saves + 1)
    }
}

/// The "[pins]" block of the Diagnostics report.
@MainActor
@Suite struct PinDiagnosticsTests {
    @Test func aLocalStoreReportsItsRowsAndThatItDoesntSync() {
        let store = PinStore.inMemory(defaults: freshDefaults())
        store.addProject(name: "Knocklofty", colour: .teal)
        store.addPin(latitude: -42.88, longitude: 147.3, placedBy: .map)
        store.delete(store.addPin(latitude: -42.89, longitude: 147.3, placedBy: .map))
        let lines = PinDiagnostics.lines(store, environment: "none (simulator)", schemaResult: nil)
        #expect(lines.first == "[pins]")
        #expect(lines.contains("store: in memory"))
        #expect(lines.contains { $0.hasPrefix("opened with CloudKit: no (cloudKitDatabase .none) · configuration container: none") })
        #expect(lines.contains("build: simulator"))
        #expect(lines.contains("CloudKit environment (guess): none (simulator)"))
        #expect(lines.contains("local rows: projects 1 (0 deleted) · pins 2 (1 deleted) · photos 0 · originals 0"))
        #expect(lines.contains("sync: off (the simulator never syncs)"))
        #expect(lines.last == "schema creation: never run on this device")
        #expect(PinCloud.environmentGuess() == "none (simulator)")
    }

    @Test func aSyncingStoreReportsAccountEventsAndFailures() {
        let sync = PinSync(defaults: freshDefaults())
        let store = PinStore(container: PinStore.makeContainer(url: nil).container, sync: sync, defaults: freshDefaults())
        sync.setAccount(.available)
        let end = Date()
        sync.record(PinSyncEvent(kind: .import, start: end.addingTimeInterval(-0.5), end: end, succeeded: true, store: "ABCDEF12"))
        sync.record(PinSyncEvent(kind: .export, start: end.addingTimeInterval(-1), end: end, succeeded: false,
                                 failure: PinSyncFailure(problem: .storageFull, code: "CKErrorDomain 25", message: "Quota exceeded")))
        let lines = PinDiagnostics.lines(store, environment: "Development (test)", schemaResult: "OK (test)")
        #expect(lines.contains { $0.hasPrefix("opened with CloudKit: yes, private database of iCloud.org.gruenschloss.izzymap") })
        #expect(lines.contains { $0.hasPrefix("iCloud account: available · checked ") })
        #expect(lines.contains("status line: iCloud storage is full"))
        #expect(lines.contains { $0.hasPrefix("last import: ok ") && !$0.contains("failed") })
        #expect(lines.contains { $0.hasPrefix("last export: ok never · failed ") && $0.hasSuffix("CKErrorDomain 25 storageFull: Quota exceeded") })
        #expect(lines.contains("last setup: ok never"))
        #expect(lines.contains("events (last 10, oldest first):"))
        #expect(lines.contains { $0.contains(" import ok 0.5 s · store ABCDEF12") })
        #expect(lines.contains { $0.contains(" export FAILED 1.0 s · CKErrorDomain 25 storageFull: Quota exceeded") })
        #expect(lines.last == "schema creation: OK (test)")
    }
}
