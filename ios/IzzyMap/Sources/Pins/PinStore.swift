import Foundation
import Observation
import IzzyKit
import os
import SwiftData
import UIKit

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
    /// Bumped after each save that wrote something (the size on disk follows).
    private(set) var saves = 0
    /// Pins not deleted, oldest first (including archived projects' pins:
    /// `mapPins` leaves those out).
    private(set) var pins: [SavedPin] = []
    /// Projects not deleted, by name.
    private(set) var projects: [PinProject] = []
    /// Soft-deleted projects, most recently deleted first (Recently deleted).
    private(set) var deletedProjects: [PinProject] = []
    /// Pins soft-deleted on their own — not together with their project,
    /// which lists those — most recently deleted first.
    private(set) var deletedPins: [SavedPin] = []

    /// Photos being added, by pin id: how far the batch has got. A batch
    /// that ended with failures stays until the card has said so
    /// (`dismissPhotoImport`).
    private(set) var photoImports: [UUID: PhotoImport] = [:]
    /// Per pin id: its photo count and newest photo (`photoCount`, `coverPhoto`).
    private(set) var photoIndex: [UUID: PhotoSummary] = [:]

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
    static let schema = Schema([PinProject.self, SavedPin.self, PinPhoto.self, PinPhotoOriginal.self])
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
        #if DEBUG
        let seed = UserDefaults.standard.integer(forKey: "debugSeedPins")
        if seed > 0, store.pins.isEmpty, store.projects.isEmpty { store.seedDemo(pins: seed) }
        #endif
        return store
    }

    #if DEBUG
    /// `-debugSeedPins N` (screenshots, UI tests; with `-pinsInMemory` or a
    /// `-pinsStore` of its own): four projects round Hobart — one with a
    /// long name, one archived — about N pins spread over them and
    /// Unfiled, titled, untitled with a note, untitled bare, over a few
    /// weeks; one project and two pins in Recently deleted.
    func seedDemo(pins count: Int) {
        let base = now()
        let projects = [
            addProject(name: "Knocklofty Reserve", colour: .teal),
            addProject(name: "Waterworks Reserve — creek line revegetation, stage 2 planting plan", colour: .gold),
            addProject(name: "Bonnet Hill", colour: .violet),
            addProject(name: "Old Midlands survey", colour: .brown),
        ]
        let titles = ["Seep below the track", "", "Big E. viminalis", "Gate", "", "Bracken front", "Gorse patch",
                      "Lookout", "", "Spring", "Fence line", "Creek crossing", "Old quarry", "Dolerite outcrop"]
        let notes = ["Sphagnum, Richea\nCheck again in spring", "Wattle regrowth along the fire trail — mostly Acacia dealbata",
                     "", "Locked; key at the depot", "", "", "Spray in March", "", "", "Running after rain", "",
                     "", "", "Dense Allocasuarina"]
        for i in 0 ..< count {
            let project: PinProject? = i % 6 == 5 ? nil : projects[i % 6 < 3 ? 0 : (i % 6 == 3 ? 1 : 2)]
            lastUsedProject = project
            let lat = -42.88 + Double(i % 7) * 0.003 - Double(i / 7) * 0.002
            let lon = 147.30 + Double(i % 5) * 0.004 + (project === projects[1] ? 0.02 : 0)
            let pin = addPin(latitude: lat, longitude: lon, placedBy: i % 3 == 0 ? .gps : .map, accuracy: 6, altitude: 120)
            pin.createdAt = base.addingTimeInterval(-Double(count - i) * 86_400 * 0.9)
            setTitle(pin, titles[i % titles.count])
            setNote(pin, notes[i % notes.count])
            if i % 9 == 4 { setColour(pin, PinColour.pink.rawValue) }
        }
        seedPhotos()
        lastUsedProject = projects[0]
        let old = addPin(latitude: -42.2, longitude: 147.5, placedBy: .map, project: projects[3])
        setTitle(old, "Remnant grassland")
        setArchived(projects[3], true)
        let gone = addProject(name: "Mt Nelson", colour: .magenta)
        lastUsedProject = gone
        addPin(latitude: -42.92, longitude: 147.32, placedBy: .map)
        deleteProject(gone)
        lastUsedProject = projects[0]
        for title in ["Wrong spot", ""] {
            let pin = addPin(latitude: -42.87, longitude: 147.31, placedBy: .map)
            setTitle(pin, title)
            delete(pin)
        }
        flush()
        reload()
    }

    /// `-debugSeedPhotos <folder>` (screenshots): the folder's JPEG/HEIC
    /// files, through the real pipeline, onto two of every three seeded
    /// pins (one to three each, cycling through the files).
    private func seedPhotos() {
        guard let path = UserDefaults.standard.string(forKey: "debugSeedPhotos"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path).sorted(), !names.isEmpty else { return }
        var next = 0
        for (i, pin) in pins.enumerated() where i % 3 != 1 {
            for _ in 0 ..< 1 + i % 3 {
                let url = URL(filePath: path).appending(path: names[next % names.count])
                next += 1
                if let data = try? Data(contentsOf: url), let imported = try? PinPhotoPipeline.library(data) {
                    _ = try? addPhoto(imported, to: pin)
                }
            }
        }
    }

    @discardableResult
    private func addPin(latitude: Double, longitude: Double, placedBy: SavedPin.Placement, project: PinProject?) -> SavedPin {
        let pin = addPin(latitude: latitude, longitude: longitude, placedBy: placedBy)
        setProject(pin, project)
        return pin
    }
    #endif

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

    /// Archived projects, by name.
    var archivedProjects: [PinProject] { projects.filter { $0.archivedAt != nil } }

    /// A project's pins (not deleted), newest first; nil: the Unfiled ones.
    func pins(in project: PinProject?) -> [SavedPin] {
        pins.filter { $0.project?.id == project?.id }.reversed()
    }

    /// Pins in no project (not deleted).
    var unfiledCount: Int { pins.count { $0.project == nil } }

    /// The pins that went with a deleted project (deleted at its moment).
    func pinsDeleted(with project: PinProject) -> [SavedPin] {
        guard let at = project.deletedAt else { return [] }
        return (project.pins ?? []).filter { $0.deletedAt == at }
    }

    /// Anything in Recently deleted.
    var hasDeleted: Bool { !deletedProjects.isEmpty || !deletedPins.isEmpty }

    /// Whole days left before a soft-deleted item is purged (at least 1).
    func daysLeft(_ deletedAt: Date?) -> Int {
        guard let deletedAt else { return 0 }
        let left = deletedAt.addingTimeInterval(Self.retention).timeIntervalSince(now())
        return max(1, Int((left / 86_400).rounded(.up)))
    }

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
        let label = PinPresenter.label(pin)
        pin.title = title
        touched(pin, saveNow: false, signal: PinPresenter.label(pin) != label)
    }

    /// Typing in the note: saved after a pause (or on `flush`). The map
    /// hears of it only when an untitled pin's label (the note's first
    /// line, `PinText.title`) changes.
    func setNote(_ pin: SavedPin, _ note: String) {
        guard pin.note != note else { return }
        let label = PinPresenter.label(pin)
        pin.note = note
        touched(pin, saveNow: false, signal: PinPresenter.label(pin) != label)
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

    /// Back from Recently deleted. A pin whose project is itself deleted
    /// comes back Unfiled (it would otherwise stay invisible).
    func restore(_ pin: SavedPin) {
        pin.deletedAt = nil
        if pin.project?.deletedAt != nil { pin.project = nil }
        touched(pin)
    }

    /// A pin by id, deleted or not (Undo needs a deleted one).
    func anyPin(_ id: UUID) -> SavedPin? {
        let descriptor = FetchDescriptor<SavedPin>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: Photos

    /// Most photos one library pick adds.
    static let photosPerPick = 20

    /// A photo to add: a camera capture, or a file's bytes still to load
    /// (PhotosPicker's `loadTransferable`, a test's generated image).
    nonisolated enum PhotoSource: Sendable {
        case camera(UIImage, metadata: CameraMetadata?, position: PinPhotoPipeline.Position?, date: Date)
        case file(@Sendable () async throws -> Data)
    }

    /// UIImagePickerController's `mediaMetadata` (a property list, read only).
    nonisolated struct CameraMetadata: @unchecked Sendable {
        let values: [String: Any]
    }

    /// How a batch of photos is getting on.
    nonisolated struct PhotoImport: Equatable, Sendable {
        var total: Int
        var done = 0
        var failed = 0
        /// Why the first photo that failed did (said once on the card).
        var reason: String?
        var finished: Bool { done + failed >= total }
    }

    /// Adds the photos one after another, each through the pipeline off
    /// the main actor (one full image decoded at a time), each saved as it
    /// is ready so the strip fills while she waits. A photo that fails is
    /// counted (the card says so once) and the rest carry on. The batch
    /// finishes even when the card closes; a pin purged meanwhile gets
    /// nothing.
    func importPhotos(_ sources: [PhotoSource], to pinID: UUID) {
        let sources = Array(sources.prefix(Self.photosPerPick))
        guard !sources.isEmpty else { return }
        // a second batch while one runs adds to its count
        var state = photoImports[pinID].flatMap { $0.finished ? nil : $0 } ?? PhotoImport(total: 0)
        state.total += sources.count
        photoImports[pinID] = state
        let container = self.container
        Task {
            for source in sources {
                // pending typing first: the photo's own save must not race it
                flush()
                let started = now()
                let result = await Task.detached(priority: .userInitiated) { () async throws -> UUID? in
                    let imported: PinPhotoImport = switch source {
                    case let .camera(image, metadata, position, date):
                        try PinPhotoPipeline.camera(image, metadata: metadata?.values, position: position, date: date)
                    case let .file(load):
                        try PinPhotoPipeline.library(try await load())
                    }
                    return try Self.insert(imported, pin: pinID, in: container, now: started)
                }.result
                switch result {
                case .success(.some):
                    reload()
                    photoImports[pinID]?.done += 1
                case .success(.none):
                    photoImports[pinID]?.failed += 1
                case let .failure(error):
                    Self.logger.error("photo import failed: \(String(describing: error), privacy: .public)")
                    if photoImports[pinID]?.reason == nil { photoImports[pinID]?.reason = error.localizedDescription }
                    photoImports[pinID]?.failed += 1
                }
            }
            if let state = photoImports[pinID], state.finished, state.failed == 0 { photoImports[pinID] = nil }
        }
    }

    /// The card has reported a batch's failures.
    func dismissPhotoImport(_ pinID: UUID) {
        if photoImports[pinID]?.finished == true { photoImports[pinID] = nil }
    }

    /// A ready photo joins the pin, newest (highest `sort`), written and
    /// saved in a context of its own: the original's bytes never sit in the
    /// main context (which `pins` keeps alive), and from the import task the
    /// external file is written off the main actor. The main context hears
    /// of it through `ModelContext.didSave` and the importer's `reload()`.
    /// nil: the pin is gone.
    nonisolated static func insert(_ imported: PinPhotoImport, pin pinID: UUID, in container: ModelContainer,
                                   now: Date) throws -> UUID? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let pin = try context.fetch(FetchDescriptor<SavedPin>(predicate: #Predicate { $0.id == pinID })).first
        else { return nil }
        var last = FetchDescriptor<PinPhoto>(predicate: #Predicate { $0.pin?.id == pinID },
                                             sortBy: [SortDescriptor(\.sort, order: .reverse)])
        last.fetchLimit = 1
        last.propertiesToFetch = [\.sort]
        let next = (try context.fetch(last).first?.sort).map { $0 + 1 } ?? 0
        let photo = PinPhoto(thumbnail: imported.thumbnail, sort: next, createdAt: imported.capturedAt ?? now,
                             width: imported.width, height: imported.height, bytes: imported.bytes)
        let original = PinPhotoOriginal(data: imported.original)
        context.insert(photo)
        context.insert(original)
        photo.original = original
        photo.pin = pin
        pin.modifiedAt = now
        try context.save()
        return photo.id
    }

    /// `insert` from the main actor, then the lists re-read (tests, seeding).
    @discardableResult
    func addPhoto(_ imported: PinPhotoImport, to pin: SavedPin) throws -> UUID? {
        flush()
        let id = try Self.insert(imported, pin: pin.id, in: container, now: now())
        reload()
        return id
    }

    /// Typing a caption: saved after a pause (or on `flush`), like the note.
    func setCaption(_ photo: PinPhoto, _ caption: String) {
        guard photo.caption != caption else { return }
        photo.caption = caption
        if let pin = photo.pin { touched(pin, saveNow: false, signal: false) } else { scheduleSave() }
    }

    /// Deletes one photo for good (the viewer asks first; single photos
    /// have no Recently deleted — they go with the pin's own soft delete).
    func deletePhoto(_ photo: PinPhoto) {
        let pin = photo.pin
        saveTask?.cancel()
        saveTask = nil
        context.delete(photo)  // its original follows by cascade
        if let pin { touched(pin) } else { commit() }
    }

    /// A photo by id (the viewer's pages hold ids, not records).
    func photo(_ id: UUID) -> PinPhoto? {
        let descriptor = FetchDescriptor<PinPhoto>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    /// How many photos these pins have — from `photoIndex`, re-read with the
    /// lists, so rows never walk a pin's photos (each with its thumbnail).
    func photoCount(_ pins: [SavedPin]) -> Int {
        pins.reduce(0) { $0 + (photoIndex[$1.id]?.count ?? 0) }
    }

    func photoCount(of pin: SavedPin) -> Int { photoIndex[pin.id]?.count ?? 0 }

    /// The newest photo's id (a row's thumbnail); nil without photos.
    func coverPhoto(of pin: SavedPin) -> UUID? { photoIndex[pin.id]?.cover }

    /// Per pin: how many photos, and the newest one's id.
    nonisolated struct PhotoSummary: Equatable, Sendable {
        var count: Int
        var cover: UUID
        var coverSort: Int
    }

    /// One light fetch per reload (id, sort and the pin link — never a
    /// thumbnail or an original).
    private func readPhotoIndex() -> [UUID: PhotoSummary] {
        var descriptor = FetchDescriptor<PinPhoto>()
        descriptor.propertiesToFetch = [\.id, \.sort, \.pin]
        var index: [UUID: PhotoSummary] = [:]
        for photo in (try? context.fetch(descriptor)) ?? [] {
            guard let pinID = photo.pin?.id else { continue }
            if var s = index[pinID] {
                s.count += 1
                if photo.sort > s.coverSort { s.cover = photo.id; s.coverSort = photo.sort }
                index[pinID] = s
            } else {
                index[pinID] = PhotoSummary(count: 1, cover: photo.id, coverSort: photo.sort)
            }
        }
        return index
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

    // MARK: Deleting for real

    /// "Delete now" in Recently deleted: the pin is gone for good.
    func deleteNow(_ pin: SavedPin) {
        guard pin.deletedAt != nil else { return }
        destroy(pin)
        commit()
    }

    /// "Delete now" for a deleted project: it and the pins that went with it.
    func deleteNow(_ project: PinProject) {
        guard project.deletedAt != nil else { return }
        let started = ContinuousClock.now
        for pin in pinsDeleted(with: project) { destroy(pin) }
        context.delete(project)
        commit()
        Self.logger.notice("deleted a project for good in \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// "Delete all now": everything in Recently deleted.
    func deleteAllNow() {
        let started = ContinuousClock.now
        defer { Self.logger.notice("deleted all for good in \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds])), privacy: .public)") }
        let allPins = (try? context.fetch(FetchDescriptor<SavedPin>())) ?? []
        let allProjects = (try? context.fetch(FetchDescriptor<PinProject>())) ?? []
        for pin in allPins where pin.deletedAt != nil { destroy(pin) }
        for project in allProjects where project.deletedAt != nil { context.delete(project) }
        commit()
    }

    // MARK: Size on disk

    /// The store's files on disk (the store, its journal, and the support
    /// folder SwiftData keeps external data in — photos, later); 0 in memory.
    /// Walked off the main actor: with photos the folder grows large.
    func bytesOnDisk() async -> Int {
        guard let url = container.configurations.first?.url, url.path != "/dev/null" else { return 0 }
        return await Task.detached(priority: .utility) { Self.bytes(of: url) }.value
    }

    /// Everything beside `store` whose name starts with its stem
    /// ("Pins.store", "Pins.store-wal", ".Pins_SUPPORT/…").
    nonisolated static func bytes(of store: URL) -> Int {
        let stem = store.deletingPathExtension().lastPathComponent
        let folder = store.deletingLastPathComponent()
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var total = 0
        for item in top where item.lastPathComponent.hasPrefix(stem) || item.lastPathComponent.hasPrefix(".\(stem)") {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            func size(_ u: URL) -> Int {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return 0 }
                return v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0
            }
            total += size(item)
            if let walker = fm.enumerator(at: item, includingPropertiesForKeys: keys) {
                for case let file as URL in walker { total += size(file) }
            }
        }
        return total
    }

    // MARK: Purge and saving

    /// Deletes for real what was soft-deleted more than `retention` ago.
    func purge() {
        // never write to a store that didn't open (this session's pins are in memory)
        guard !openFailed else { return }
        let cutoff = now().addingTimeInterval(-Self.retention)
        func expired(_ date: Date?) -> Bool { date.map { $0 < cutoff } ?? false }
        let allPins = (try? context.fetch(FetchDescriptor<SavedPin>())) ?? []
        let allProjects = (try? context.fetch(FetchDescriptor<PinProject>())) ?? []
        var purged = 0
        for pin in allPins where expired(pin.deletedAt) {
            destroy(pin)
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

    /// Deletes a pin for good; its photos and their originals follow by
    /// cascade (the save removes the external files without reading them).
    private func destroy(_ pin: SavedPin) {
        context.delete(pin)
    }

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
        do {
            try context.save()
            saves += 1
        } catch {
            Self.logger.error("pin save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-reads the lists and bumps the signal.
    func reload() {
        let allPins = (try? context.fetch(FetchDescriptor<SavedPin>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let allProjects = (try? context.fetch(FetchDescriptor<PinProject>(sortBy: [SortDescriptor(\.name)]))) ?? []
        pins = allPins.filter { $0.deletedAt == nil }
        projects = allProjects.filter { $0.deletedAt == nil }
        deletedProjects = allProjects.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
        deletedPins = allPins.filter { pin in
            guard let at = pin.deletedAt else { return false }
            return pin.project?.deletedAt != at
        }.sorted { $0.deletedAt! > $1.deletedAt! }
        photoIndex = readPhotoIndex()
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
