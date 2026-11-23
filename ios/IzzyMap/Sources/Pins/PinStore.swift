import Foundation
import Observation
import IzzyKit
import os
import SwiftData

/// The pins and projects of this device (docs/PINS_PLAN.md §3), shared by
/// every window (`AppData.pins`): one SwiftData store, local for now
/// (`cloudKitDatabase: .none`; milestone 2 switches CloudKit on), with a
/// small facade so views and the map never touch the context themselves.
///
/// **One change signal**, `revision`: bumped on every edit made here, and
/// when the store changes underneath — another context's save or a
/// persistent-store remote change (how iCloud imports will arrive) — after
/// re-reading the lists. The map layer and the views key on it.
///
/// Edits stamp `modifiedAt`. Structural changes (add, move, delete, a
/// project) save at once; typing in a title or note saves after a short
/// pause (`saveDelay`) and on `flush()` — the card closing, the app
/// leaving the foreground.
@Observable
final class PinStore {
    let container: ModelContainer
    /// Bumped whenever what the store holds may have changed.
    private(set) var revision = 0
    /// Pins not deleted, oldest first (including archived projects' pins:
    /// `mapPins` leaves those out).
    private(set) var pins: [SavedPin] = []
    /// Projects not deleted, by name.
    private(set) var projects: [PinProject] = []

    /// The store file couldn't be opened: this session's pins live in
    /// memory only (the file is left untouched). The map says so.
    let openFailed: Bool

    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// Soft-deleted pins and projects are purged after this long.
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// How long typing may go unsaved.
    static let saveDelay: Duration = .milliseconds(500)
    static let lastProjectKey = "pinsLastProject"
    static let schema = Schema([PinProject.self, SavedPin.self])
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Pins")

    private var context: ModelContext { container.mainContext }

    /// `container` as given (tests: in memory); `now` and `defaults` injectable.
    init(container: ModelContainer, openFailed: Bool = false, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { Date() }) {
        self.container = container
        self.openFailed = openFailed
        self.defaults = defaults
        self.now = now
        container.mainContext.autosaveEnabled = false
        reload()
        observeUnderlyingChanges()
    }

    /// An empty store in memory (unit tests, previews, `-pinsInMemory`).
    static func inMemory(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) -> PinStore {
        PinStore(container: makeContainer(url: nil).container, defaults: defaults, now: now)
    }

    /// The app's store: Application Support/Pins/Pins.store (`Pins-dev/` in
    /// DEBUG builds, so a development build never mixes with TestFlight's
    /// data); included in backups. DEBUG launch arguments for tests:
    /// `-pinsInMemory YES`, `-pinsStore <file path>`. Purges what was
    /// deleted more than 30 days ago.
    static func launch(enabled: Bool) -> PinStore? {
        guard enabled else { return nil }
        var url: URL? = defaultStoreURL()
        #if DEBUG
        let args = UserDefaults.standard
        if args.bool(forKey: "pinsInMemory") {
            url = nil
        } else if let path = args.string(forKey: "pinsStore"), !path.isEmpty {
            url = URL(filePath: path)
        }
        #endif
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let opened = makeContainer(url: url)
        let store = PinStore(container: opened.container, openFailed: opened.failed)
        // never purge (or otherwise write) when the real store didn't open
        if !opened.failed { store.purge() }
        return store
    }

    static func defaultStoreURL() -> URL {
        #if DEBUG
        let folder = "Pins-dev"
        #else
        let folder = "Pins"
        #endif
        return URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
            .appending(path: "Pins.store")
    }

    /// A store that can't be opened must not take the app down: the pins
    /// then live in memory for this session (`failed`; logged, and the map
    /// says so). The file that failed is never deleted or overwritten.
    static func makeContainer(url: URL?) -> (container: ModelContainer, failed: Bool) {
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        do {
            return (try ModelContainer(for: schema, configurations: configuration), false)
        } catch {
            logger.fault("pin store unreadable, using memory: \(String(describing: error), privacy: .public)")
            // an in-memory store of a valid schema always opens
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            return (try! ModelContainer(for: schema, configurations: memory), true)
        }
    }

    // MARK: Reading

    func pin(_ id: UUID) -> SavedPin? { pins.first { $0.id == id } }
    func project(_ id: UUID) -> PinProject? { projects.first { $0.id == id } }

    /// The pins the map draws (not in an archived or deleted project).
    var mapPins: [SavedPin] { pins.filter(\.isOnMap) }

    /// Projects a pin can join (not archived), by name.
    var activeProjects: [PinProject] { projects.filter { $0.archivedAt == nil } }

    /// The project new pins join: the one used last, while it exists and
    /// isn't archived or deleted.
    var lastUsedProject: PinProject? {
        get {
            _ = revision
            guard let raw = defaults.string(forKey: Self.lastProjectKey), let id = UUID(uuidString: raw),
                  let project = project(id), project.archivedAt == nil else { return nil }
            return project
        }
        set {
            if let newValue { defaults.set(newValue.id.uuidString, forKey: Self.lastProjectKey) } else { defaults.removeObject(forKey: Self.lastProjectKey) }
            revision += 1
        }
    }

    /// The first palette colour no active project uses yet (all used: the standard).
    func nextProjectColour() -> PinColour {
        let used = Set(activeProjects.map(\.colour))
        return PinColour.allCases.first { !used.contains($0.rawValue) } ?? PinColour.standard
    }

    // MARK: Pins

    /// A new pin, in the project used last (or none).
    @discardableResult
    func addPin(latitude: Double, longitude: Double, placedBy: SavedPin.Placement, accuracy: Double? = nil,
                altitude: Double? = nil) -> SavedPin {
        let pin = SavedPin(lat: latitude, lon: longitude, placedBy: placedBy,
                           accuracy: placedBy == .gps ? accuracy : nil, altitude: placedBy == .gps ? altitude : nil,
                           project: lastUsedProject, now: now())
        context.insert(pin)
        commit()
        return pin
    }

    /// Typing in the title: saved after a pause (or on `flush`). The map
    /// hears of it (`revision`) only when its label changes; the card sees
    /// its own text through the record (a model is observable).
    func setTitle(_ pin: SavedPin, _ title: String) {
        guard pin.title != title else { return }
        let label = MapText.latin1Label(pin.title)
        pin.title = title
        touched(pin, saveNow: false, signal: MapText.latin1Label(title) != label)
    }

    /// Typing in the note: saved after a pause (or on `flush`). The map
    /// never draws the note: no signal.
    func setNote(_ pin: SavedPin, _ note: String) {
        guard pin.note != note else { return }
        pin.note = note
        touched(pin, saveNow: false, signal: false)
    }

    /// A colour of its own, or nil for the project's.
    func setColour(_ pin: SavedPin, _ name: String?) {
        guard pin.colour != name else { return }
        pin.colour = name
        touched(pin)
    }

    /// Into a project (nil: Unfiled); that project becomes the one new pins join.
    func setProject(_ pin: SavedPin, _ project: PinProject?) {
        if pin.project?.id != project?.id {
            pin.project = project
            touched(pin)
        }
        lastUsedProject = project
    }

    /// A new position: by hand (`.map`, no accuracy) or at a fix (`.gps`).
    func move(_ pin: SavedPin, latitude: Double, longitude: Double, placedBy: SavedPin.Placement,
              accuracy: Double? = nil, altitude: Double? = nil) {
        pin.lat = latitude
        pin.lon = longitude
        pin.placedBy = placedBy.rawValue
        pin.accuracy = placedBy == .gps ? accuracy : nil
        pin.altitude = placedBy == .gps ? altitude : nil
        touched(pin)
    }

    /// Soft delete: off the map, restorable for 30 days.
    func delete(_ pin: SavedPin) {
        pin.deletedAt = now()
        touched(pin)
    }

    func restore(_ pin: SavedPin) {
        pin.deletedAt = nil
        touched(pin)
    }

    /// A pin by id, deleted or not (Undo needs a deleted one).
    func anyPin(_ id: UUID) -> SavedPin? {
        let descriptor = FetchDescriptor<SavedPin>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: Projects

    /// A new project; it becomes the one new pins join.
    @discardableResult
    func addProject(name: String, colour: PinColour) -> PinProject {
        let project = PinProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines), colour: colour.rawValue, now: now())
        context.insert(project)
        commit()
        lastUsedProject = project
        return project
    }

    func editProject(_ project: PinProject, name: String? = nil, colour: PinColour? = nil, note: String? = nil) {
        if let name { project.name = name }
        if let colour { project.colour = colour.rawValue }
        if let note { project.note = note }
        project.modifiedAt = now()
        commit()
    }

    func setArchived(_ project: PinProject, _ archived: Bool) {
        project.archivedAt = archived ? now() : nil
        project.modifiedAt = now()
        commit()
    }

    /// Soft delete, taking its pins along (same moment, so restoring the
    /// project brings back exactly those — not pins deleted on their own).
    func deleteProject(_ project: PinProject) {
        let at = now()
        project.deletedAt = at
        project.modifiedAt = at
        for pin in project.pins ?? [] where pin.deletedAt == nil {
            pin.deletedAt = at
            pin.modifiedAt = at
        }
        commit()
    }

    func restoreProject(_ project: PinProject) {
        let at = project.deletedAt
        project.deletedAt = nil
        project.modifiedAt = now()
        for pin in project.pins ?? [] where at != nil && pin.deletedAt == at {
            pin.deletedAt = nil
            pin.modifiedAt = now()
        }
        commit()
    }

    // MARK: Purge and saving

    /// Deletes for real what was soft-deleted more than `retention` ago.
    func purge() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        func expired(_ date: Date?) -> Bool { date.map { $0 < cutoff } ?? false }
        let allPins = (try? context.fetch(FetchDescriptor<SavedPin>())) ?? []
        let allProjects = (try? context.fetch(FetchDescriptor<PinProject>())) ?? []
        var purged = 0
        for pin in allPins where expired(pin.deletedAt) {
            context.delete(pin)
            purged += 1
        }
        for project in allProjects where expired(project.deletedAt) {
            context.delete(project)
            purged += 1
        }
        guard purged > 0 else { return }
        Self.logger.notice("purged \(purged) deleted pins/projects")
        commit()
    }

    /// Saves pending typing now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    // MARK: Internals

    private func touched(_ pin: SavedPin, saveNow: Bool = true, signal: Bool = true) {
        pin.modifiedAt = now()
        if saveNow {
            commit()
        } else {
            if signal { revision += 1 }
            scheduleSave()
        }
    }

    /// Save, re-read the lists, signal.
    private func commit() {
        saveTask?.cancel()
        saveTask = nil
        save()
        reload()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        guard context.hasChanges else { return }
        do { try context.save() } catch {
            Self.logger.error("pin save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-reads the lists and bumps the signal.
    func reload() {
        let allPins = (try? context.fetch(FetchDescriptor<SavedPin>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let allProjects = (try? context.fetch(FetchDescriptor<PinProject>(sortBy: [SortDescriptor(\.name)]))) ?? []
        pins = allPins.filter { $0.deletedAt == nil }
        projects = allProjects.filter { $0.deletedAt == nil }
        revision += 1
    }

    /// Another context's save (a background import) or a remote change to
    /// the persistent store (CloudKit, once on): re-read and signal. Our
    /// own context's saves are already signalled.
    private func observeUnderlyingChanges() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [ModelContext.didSave, .NSPersistentStoreRemoteChange]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, sender != ObjectIdentifier(self.context) else { return }
                    self.reload()
                }
            })
        }
    }
}
