import CloudKit
import CoreData
import Foundation
import Observation
import os
import SwiftData
import SwiftUI

// iCloud sync of the pin store (docs/PINS_PLAN.md §3): SwiftData's own
// CloudKit mirroring into the PRIVATE database of one container — the app
// writes no sync code. This file decides when the store syncs (`PinCloud`),
// and watches what the mirroring reports (`PinSync`) for the Pins screen's
// one status line and the Diagnostics report. When the store doesn't sync
// (simulator, tests, `-pinsStore`, in memory, a store that failed to open)
// nothing here touches CloudKit: no `CKContainer`, no observers.

/// When the pin store syncs, and with which container.
nonisolated enum PinCloud {
    static let containerID = "iCloud.org.gruenschloss.izzymap"

    /// The models the store holds (`PinStore.schema`, the schema creation).
    static var modelTypes: [any PersistentModel.Type] {
        [PinProject.self, SavedPin.self, PinPhoto.self, PinPhotoOriginal.self]
    }

    /// A device build: only those carry the iCloud entitlements
    /// (IzzyMap.entitlements; the simulator's file has none).
    static var isDeviceBuild: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// Only the app's own store file syncs, and only in a device build:
    /// never in memory, never a `-pinsStore` file of a test's own.
    static func syncs(storeURL: URL?, defaultStore: URL, deviceBuild: Bool = isDeviceBuild) -> Bool {
        guard deviceBuild, let storeURL else { return false }
        return storeURL.standardizedFileURL.path(percentEncoded: false) == defaultStore.standardizedFileURL.path(percentEncoded: false)
    }

    static func database(syncs: Bool) -> ModelConfiguration.CloudKitDatabase {
        syncs ? .private(containerID) : .none
    }

    /// Stores whose sync events aren't the pin store's (the schema
    /// creation's temporary store): `PinSync` ignores them.
    static let ignoredStores = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Which CloudKit environment this build talks to — a guess from the
    /// embedded provisioning profile (Diagnostics): a development profile
    /// → Development; none (App Store / TestFlight builds carry none) →
    /// Production.
    static func environmentGuess(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return isDeviceBuild ? "Production (no embedded profile: App Store / TestFlight build)" : "none (simulator)"
        }
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound ..< end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return "unknown (embedded profile unreadable)"
        }
        let aps = entitlements["aps-environment"] as? String ?? "none"
        let containers = (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String])?.joined(separator: ", ") ?? "none"
        let environments = (entitlements["com.apple.developer.icloud-container-environment"] as? [String])?.joined(separator: ", ")
            ?? (entitlements["com.apple.developer.icloud-container-environment"] as? String) ?? "none"
        let guess = aps == "production" ? "Production" : "Development"
        return "\(guess) (profile \"\(plist["Name"] as? String ?? "?")\": aps-environment \(aps) · containers \(containers) · environments \(environments))"
    }
}

// MARK: - What the mirroring reports

/// What went wrong, in the words the Pins screen uses.
nonisolated enum PinSyncProblem: String, Codable, Sendable, Comparable {
    case storageFull, notSignedIn, offline, failed

    /// Which one to tell first when several are current.
    var rank: Int {
        switch self {
        case .storageFull: 0
        case .notSignedIn: 1
        case .offline: 2
        case .failed: 3
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// One failure: what to say, and the raw code for Diagnostics.
nonisolated struct PinSyncFailure: Codable, Equatable, Sendable {
    var problem: PinSyncProblem
    /// "CKErrorDomain 25" (the error the problem was read from).
    var code: String
    var message: String
}

nonisolated enum PinSyncErrors {
    /// Maps a mirroring error. A CloudKit partial failure is unwrapped
    /// first (`CKPartialErrorsByItemIDKey`), and so are underlying errors
    /// (Core Data wraps CloudKit's): the most telling one wins — storage
    /// full, then not signed in, then no connection, else "failed".
    static func classify(_ error: any Error) -> PinSyncFailure {
        let all = flatten(error as NSError)
        var best: (problem: PinSyncProblem, error: NSError)?
        for candidate in all {
            guard let problem = problem(of: candidate) else { continue }
            if best == nil || problem < best!.problem { best = (problem, candidate) }
        }
        if let best {
            return PinSyncFailure(problem: best.problem, code: "\(best.error.domain) \(best.error.code)", message: best.error.localizedDescription)
        }
        // nothing recognised: the most specific CloudKit error, else the error itself
        let leaf = all.first { $0.domain == CKErrorDomain && $0.code != CKError.Code.partialFailure.rawValue } ?? (error as NSError)
        return PinSyncFailure(problem: .failed, code: "\(leaf.domain) \(leaf.code)", message: leaf.localizedDescription)
    }

    /// The error, its partial errors and underlying errors, breadth first.
    static func flatten(_ error: NSError) -> [NSError] {
        var out: [NSError] = []
        var queue = [error]
        while !queue.isEmpty, out.count < 64 {
            let e = queue.removeFirst()
            out.append(e)
            if e.domain == CKErrorDomain, let partial = e.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
                queue += partial.allValues.compactMap { $0 as? NSError }
            }
            if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(underlying) }
            if let many = e.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { queue += many }
        }
        return out
    }

    private static func problem(of e: NSError) -> PinSyncProblem? {
        switch e.domain {
        case CKErrorDomain:
            switch CKError.Code(rawValue: e.code) {
            case .quotaExceeded?: return .storageFull
            case .notAuthenticated?, .accountTemporarilyUnavailable?: return .notSignedIn
            case .networkUnavailable?, .networkFailure?: return .offline
            default: return nil
            }
        case NSURLErrorDomain:
            let offline: [Int] = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                                  NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDataNotAllowed,
                                  NSURLErrorInternationalRoamingOff]
            return offline.contains(e.code) ? .offline : nil
        default:
            return nil
        }
    }
}

/// One finished mirroring event (`NSPersistentCloudKitContainer.Event`).
nonisolated struct PinSyncEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case setup, `import`, export
    }

    var kind: Kind
    var start: Date
    var end: Date
    var succeeded: Bool
    var failure: PinSyncFailure?
    /// The store's identifier, first 8 characters (Diagnostics).
    var store: String = ""

    /// "09:41:07 export ok 0.4 s" / "… export FAILED 1.2 s · CKErrorDomain 25 storageFull: …".
    var line: String {
        let time = end.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        var s = "\(time) \(kind.rawValue) \(succeeded ? "ok" : "FAILED") \(String(format: "%.1f", end.timeIntervalSince(start))) s"
        if !store.isEmpty { s += " · store \(store)" }
        if let failure { s += " · \(failure.code) \(failure.problem.rawValue): \(failure.message)" }
        return s
    }
}

/// What the mirroring has said, kept across launches (UserDefaults): the
/// last success and the last failure per kind, and the last ten events.
nonisolated struct PinSyncLog: Codable, Equatable, Sendable {
    struct Failed: Codable, Equatable, Sendable {
        var date: Date
        var failure: PinSyncFailure
    }

    var lastSuccess: [String: Date] = [:]
    var lastFailure: [String: Failed] = [:]
    var events: [PinSyncEvent] = []

    static let eventsKept = 10

    mutating func record(_ event: PinSyncEvent) {
        if event.succeeded {
            lastSuccess[event.kind.rawValue] = event.end
        } else {
            let failure = event.failure ?? PinSyncFailure(problem: .failed, code: "no error", message: "the event failed without an error")
            lastFailure[event.kind.rawValue] = Failed(date: event.end, failure: failure)
        }
        events.append(event)
        if events.count > Self.eventsKept { events.removeFirst(events.count - Self.eventsKept) }
    }

    /// The last finished import or export that succeeded.
    var lastSynced: Date? {
        [lastSuccess[PinSyncEvent.Kind.import.rawValue], lastSuccess[PinSyncEvent.Kind.export.rawValue]].compactMap { $0 }.max()
    }

    /// The failure still current: one not followed by a success of its own
    /// kind (a lost connection: by any success — the connection is back).
    /// Several: the most telling, then the newest.
    var currentFailure: PinSyncFailure? {
        let anySuccess = lastSuccess.values.max()
        let current = lastFailure.compactMap { kind, failed -> Failed? in
            if let ok = lastSuccess[kind], ok >= failed.date { return nil }
            if failed.failure.problem == .offline, let ok = anySuccess, ok >= failed.date { return nil }
            return failed
        }
        return current.min { a, b in
            a.failure.problem != b.failure.problem ? a.failure.problem < b.failure.problem : a.date > b.date
        }?.failure
    }
}

/// The iCloud account as CloudKit reports it.
nonisolated enum PinSyncAccount: Equatable, Sendable {
    /// Not asked yet (or the answer hasn't come).
    case unknown
    case available, noAccount, restricted, temporarilyUnavailable
    case couldNotDetermine(String?)

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine(nil)
        @unknown default: self = .couldNotDetermine("unknown status \(status.rawValue)")
        }
    }

    var line: String {
        switch self {
        case .unknown: "not asked yet"
        case .available: "available"
        case .noAccount: "noAccount (signed out, or iCloud off for IzzyMap)"
        case .restricted: "restricted"
        case .temporarilyUnavailable: "temporarilyUnavailable (Settings asks to sign in again)"
        case let .couldNotDetermine(why): "couldNotDetermine" + (why.map { " (\($0))" } ?? "")
        }
    }
}

/// The Pins screen's one line about sync.
nonisolated enum PinSyncStatus: Equatable, Sendable {
    /// The store doesn't sync (simulator, sync off).
    case localOnly
    /// Signed out of iCloud, or iCloud off for the app.
    case accountOff
    case restricted
    /// iCloud wants her to sign in again (Settings).
    case needsAttention
    case problem(PinSyncProblem)
    /// The last import or export that finished well (a fact, not a promise
    /// that every edit is up: the app can't see what waits to upload).
    case synced(Date)
    /// On, nothing finished yet (said neutrally: no spinner that could stick
    /// if the mirroring never reports).
    case starting

    static func derive(account: PinSyncAccount, log: PinSyncLog) -> PinSyncStatus {
        switch account {
        case .noAccount: return .accountOff
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .needsAttention
        case .unknown, .available, .couldNotDetermine: break
        }
        if let failure = log.currentFailure { return .problem(failure.problem) }
        if let date = log.lastSynced { return .synced(date) }
        return .starting
    }

    func symbol(device: String) -> String {
        switch self {
        case .localOnly: device == "iPad" ? "ipad" : "iphone"
        case .accountOff, .restricted, .needsAttention: "icloud.slash"
        case .problem: "exclamationmark.icloud"
        case .synced: "checkmark.icloud"
        case .starting: "icloud"
        }
    }
}

nonisolated enum PinSyncText {
    /// "Last synced with iCloud · 2 min ago", "iCloud is off on this iPhone — pins
    /// stay here", "iCloud storage is full", "On this iPhone only", ….
    static func line(_ status: PinSyncStatus, now: Date, device: String) -> String {
        switch status {
        case .localOnly: "On this \(device) only"
        case .accountOff: "iCloud is off on this \(device) — pins stay here"
        case .restricted: "iCloud is restricted on this \(device) — pins stay here"
        case .needsAttention: "Sign in to iCloud again in Settings — pins stay here"
        case .problem(.storageFull): "iCloud storage is full"
        case .problem(.notSignedIn): "Not signed in to iCloud"
        case .problem(.offline): "Waiting for a connection"
        case .problem(.failed): "iCloud sync failed"
        case let .synced(date): "Last synced with iCloud · \(ago(date, now: now))"
        case .starting: "iCloud sync is on"
        }
    }

    /// Storage's Pins footer: where her pins are kept, as the status says.
    static func storageFooter(_ status: PinSyncStatus, now: Date, device: String) -> String {
        let base = "Your pins, notes, photos and projects, kept on this \(device) and in its backups"
        switch status {
        case .localOnly: return base + "."
        case .synced: return base + ", and synced with your iCloud."
        default: return base + ". " + line(status, now: now, device: device) + "."
        }
    }

    /// "just now", "2 min ago", "3 h ago", "yesterday", "24 Nov" (fixed
    /// words, no locale's abbreviations — a status line, not a timestamp).
    static func ago(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return PinText.shortDate(date, now: now, calendar: calendar)
    }
}

// MARK: - The watcher

/// What iCloud sync is doing for the pin store: the account, and what
/// SwiftData's mirroring reports (`NSPersistentCloudKitContainer.
/// eventChangedNotification` — SwiftData's store posts the Core Data
/// events). Created only for a store opened with CloudKit (`PinStore.sync`);
/// `start()` is what first touches CloudKit.
@Observable
final class PinSync {
    let containerID: String
    private(set) var account: PinSyncAccount = .unknown
    private(set) var accountChecked: Date?
    private(set) var log: PinSyncLog
    /// Called after every import that finished well: the store re-reads
    /// (`PinStore` sets it) — a mirroring import is no `ModelContext.didSave`,
    /// and whether SwiftData posts a remote-change notification is unproven.
    @ObservationIgnored var importFinished: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PinSync")

    #if DEBUG
    static let logKey = "pinsSyncLog-dev"
    #else
    static let logKey = "pinsSyncLog"
    #endif

    init(containerID: String = PinCloud.containerID, defaults: UserDefaults = .standard) {
        self.containerID = containerID
        self.defaults = defaults
        log = defaults.data(forKey: Self.logKey).flatMap { try? JSONDecoder().decode(PinSyncLog.self, from: $0) } ?? PinSyncLog()
    }

    var status: PinSyncStatus { PinSyncStatus.derive(account: account, log: log) }

    /// Starts watching: the account now and on every change, and the
    /// mirroring's events. Only for a store that syncs.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  let end = event.endDate else { return }
            guard !PinCloud.ignoredStores.withLock({ $0.contains(event.storeIdentifier) }) else { return }
            let kind: PinSyncEvent.Kind = switch event.type {
            case .setup: .setup
            case .import: .import
            case .export: .export
            @unknown default: .setup
            }
            let record = PinSyncEvent(kind: kind, start: event.startDate, end: end, succeeded: event.succeeded,
                                      failure: event.error.map(PinSyncErrors.classify), store: String(event.storeIdentifier.prefix(8)))
            MainActor.assumeIsolated { self?.record(record) }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        })
        refreshAccount()
    }

    /// Asks CloudKit for the account (the answer arrives later).
    func refreshAccount() {
        accountTask?.cancel()
        accountTask = Task { [weak self] in await self?.updateAccount() }
    }

    /// Asks CloudKit for the account and waits for the answer, at most
    /// `timeout` (Diagnostics). false: no answer in time — `account` is the
    /// previous one.
    func refreshAccountNow(timeout: Duration = .seconds(5)) async -> Bool {
        accountTask?.cancel()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.updateAccount(); return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func updateAccount() async {
        let container = self.container ?? CKContainer(identifier: containerID)
        self.container = container
        let result: PinSyncAccount
        do {
            result = PinSyncAccount(try await container.accountStatus())
        } catch {
            result = .couldNotDetermine("\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)")
        }
        setAccount(result)
    }

    func setAccount(_ account: PinSyncAccount, at date: Date = Date()) {
        self.account = account
        accountChecked = date
    }

    func record(_ event: PinSyncEvent) {
        log.record(event)
        if !event.succeeded {
            Self.logger.error("sync \(event.kind.rawValue, privacy: .public) failed: \(event.line, privacy: .public)")
        }
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Self.logKey) }
        if event.kind == .import, event.succeeded { importFinished?() }
    }
}

/// The Pins screen's sync line: the status, kept current (an "ago" ages),
/// in the footer's own type like the size line under it.
struct PinSyncLine: View {
    let sync: PinSync?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = sync?.status ?? .localOnly
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: status.symbol(device: DeviceNoun.current))
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(PinSyncText.line(status, now: context.date, device: DeviceNoun.current))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pins-sync-status")
            }
            .foregroundStyle(DesignColor.secondaryInk)
        }
    }
}

// MARK: - Diagnostics

/// The pins block of the Diagnostics report: the raw facts for the first
/// device runs with sync — where the store is, whether it was opened with
/// CloudKit, the account, the environment, the last events, and the local
/// row counts to compare with the CloudKit Console.
enum PinDiagnostics {
    /// `accountFresh` false: CloudKit didn't answer the refresh in time, the
    /// account shown is the previous answer.
    static func lines(_ store: PinStore, environment: String = PinCloud.environmentGuess(),
                      schemaResult: String? = PinSchemaResult.last, accountFresh: Bool = true) -> [String] {
        var out: [String] = ["[pins]"]
        let configuration = store.container.configurations.first
        let path = configuration.map { $0.isStoredInMemoryOnly ? "in memory" : $0.url.path(percentEncoded: false) } ?? "none"
        out.append("store: \(path)")
        out.append("opened with CloudKit: \(store.sync != nil ? "yes, private database of \(PinCloud.containerID)" : "no (cloudKitDatabase .none)")"
                   + " · configuration container: \(configuration?.cloudKitContainerIdentifier ?? "none")")
        if store.openFailed { out.append("OPEN FAILED, pins in memory this session: \(store.openError ?? "?")") }
        out.append("build: \(PinCloud.isDeviceBuild ? "device" : "simulator")")
        out.append("CloudKit environment (guess): \(environment)")
        let c = store.localCounts()
        out.append("local rows: projects \(c.projects) (\(c.deletedProjects) deleted) · pins \(c.pins) (\(c.deletedPins) deleted) · photos \(c.photos) · originals \(c.originals)")
        if let sync = store.sync {
            out.append("iCloud account: \(sync.account.line)\(sync.accountChecked.map { " · checked \($0.formatted(.iso8601))" } ?? "")"
                       + (accountFresh ? "" : " (refreshing — no answer within 5 s, this is the previous one)"))
            out.append("status line: \(PinSyncText.line(sync.status, now: Date(), device: DeviceNoun.current))")
            for kind in PinSyncEvent.Kind.allCases {
                let ok = sync.log.lastSuccess[kind.rawValue].map { $0.formatted(.iso8601) } ?? "never"
                var line = "last \(kind.rawValue): ok \(ok)"
                if let failed = sync.log.lastFailure[kind.rawValue] {
                    line += " · failed \(failed.date.formatted(.iso8601)) \(failed.failure.code) \(failed.failure.problem.rawValue): \(failed.failure.message)"
                }
                out.append(line)
            }
            out.append("events (last \(PinSyncLog.eventsKept), oldest first):")
            if sync.log.events.isEmpty { out.append("  none yet") }
            for event in sync.log.events { out.append("  \(event.line)") }
        } else {
            out.append("sync: off (\(PinCloud.isDeviceBuild ? "not the app's own store file" : "the simulator never syncs"))")
        }
        if PinSchemaResult.requested { out.append("schema creation REQUESTED: runs at the next launch (relaunch from Xcode)") }
        out.append("schema creation: \(schemaResult ?? "never run on this device")")
        return out
    }
}

/// "Create iCloud schema": the request Diagnostics leaves for the next
/// launch, and the last run's full text (shown in the report).
nonisolated enum PinSchemaResult {
    static let key = "pinsSchemaResult"
    static let requestKey = "pinsSchemaRequested"

    static var last: String? { UserDefaults.standard.string(forKey: key) }

    static func save(_ text: String) { UserDefaults.standard.set(text, forKey: key) }

    /// Diagnostics asked for a run at the next launch.
    static var requested: Bool {
        get { UserDefaults.standard.bool(forKey: requestKey) }
        set { UserDefaults.standard.set(newValue, forKey: requestKey) }
    }
}

#if DEBUG && !targetEnvironment(simulator)
/// Writes the pin record types into CloudKit's Development environment —
/// Apple's way for SwiftData ("Syncing model data across a person's
/// devices"): a Core Data model made from the SwiftData schema, an
/// `NSPersistentCloudKitContainer` on it, `initializeCloudKitSchema()`,
/// the store removed. Only ever at launch, BEFORE the SwiftData container
/// opens (`PinStore.launch`), as Apple's article does — never while the
/// live store mirrors the same zone (the temporary store would import
/// every record and photo, and the live one the sample records). On a
/// temporary store file, deleted after, so the app's own file is never
/// opened by Core Data first. DEBUG device builds only: the
/// `-pinsCreateSchema YES` launch argument, or Diagnostics → "Create
/// iCloud schema", which asks for it at the next launch.
nonisolated enum PinCloudSchema {
    /// Blocks until done (seconds or more: it uploads sample records and
    /// deletes them) — launch only, under Xcode (no launch watchdog).
    static func run() -> String {
        var lines = ["\(Date().formatted(.iso8601)) · container \(PinCloud.containerID)"]
        let started = ContinuousClock.now
        let dir = URL.temporaryDirectory.appending(path: "pins-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try autoreleasepool {
                guard let model = NSManagedObjectModel.makeManagedObjectModel(for: PinCloud.modelTypes) else {
                    throw NSError(domain: "IzzyMap.PinCloudSchema", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "makeManagedObjectModel returned nil"])
                }
                lines.append("model: " + model.entities.compactMap(\.name).sorted().joined(separator: ", "))
                let description = NSPersistentStoreDescription(url: dir.appending(path: "Schema.store"))
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: PinCloud.containerID)
                // load synchronously: done before the schema is initialised
                description.shouldAddStoreAsynchronously = false
                let container = NSPersistentCloudKitContainer(name: "PinsSchema", managedObjectModel: model)
                container.persistentStoreDescriptions = [description]
                var loadError: (any Error)?
                container.loadPersistentStores { _, error in loadError = error }
                let coordinator = container.persistentStoreCoordinator
                // the store leaves the coordinator before its files are
                // deleted, whatever happens next
                defer {
                    for store in coordinator.persistentStores {
                        do { try coordinator.remove(store) } catch { lines.append("removing the temporary store failed: \(error)") }
                    }
                }
                if let loadError { throw loadError }
                PinCloud.ignoredStores.withLock { ids in for store in coordinator.persistentStores { ids.insert(store.identifier) } }
                try container.initializeCloudKitSchema(options: [])
                lines.append("initializeCloudKitSchema: OK — the record types are in the Development environment; deploy them to Production in the CloudKit Console")
            }
        } catch {
            let ns = error as NSError
            lines.append("FAILED: \(ns.domain) \(ns.code): \(ns.localizedDescription)")
            lines.append("mapped: \(PinSyncErrors.classify(error).problem.rawValue)")
            lines.append("full error: \(String(describing: error))")
        }
        lines.append("took \(started.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds])))")
        return lines.joined(separator: "\n")
    }
}

/// Diagnostics → "Create iCloud schema" (docs/PINS_PLAN.md §7 step 2):
/// only asks for a run at the next launch, which does the work before the
/// pin store opens.
struct PinSchemaSection: View {
    let changed: () -> Void
    @State private var requested = PinSchemaResult.requested

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if requested {
                Label("iCloud schema: runs at the next launch", systemImage: "icloud.and.arrow.up")
                Button("Cancel Request", role: .cancel) { set(false) }
                    .font(.footnote)
            } else {
                Button("Create iCloud schema", systemImage: "icloud.and.arrow.up") { set(true) }
                    .accessibilityIdentifier("diagnostics-pins-schema")
            }
            Text("Writes the pin record types into the CloudKit Development environment of \(PinCloud.containerID) (sample records, deleted again) at the next launch, before the pin store opens. Then stop IzzyMap and run it again FROM XCODE: that launch blocks for a while as it talks to iCloud, which only the debugger tolerates (the launch watchdog doesn't apply under it). The result appears below under \"schema creation\". Then deploy the schema to Production in the CloudKit Console.")
                .font(.footnote)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func set(_ on: Bool) {
        PinSchemaResult.requested = on
        requested = on
        changed()
    }
}
#endif
