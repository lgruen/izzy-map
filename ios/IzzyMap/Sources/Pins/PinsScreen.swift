import IzzyKit
import SwiftUI

/// What the Pins screen pushes.
nonisolated enum PinsRoute: Hashable, Sendable {
    case project(UUID)
    case unfiled
    case deleted
}

/// The Pins screen (docs/PINS_PLAN.md §5; `Presentation.pins`): projects
/// with their colour, Unfiled, Archived (folded), Recently deleted. Built
/// like Storage — the system's opaque sheet (large on a phone, a form
/// sheet on an iPad), rows straight on it, the section's point first (New
/// project, the ink capsule). A project's page lists its pins; a pin row
/// closes the screen and opens that pin's card on the map. Escape pops one
/// level (the editor, then a pushed page), then closes.
struct PinsScreen: View {
    let model: AppModel
    let store: PinStore
    /// Opened from the iPad's Layers popover, as Storage is: ✓ and the
    /// last Escape go back to Layers (nil: the screen is the modal itself).
    var done: (() -> Void)? = nil
    @State private var path: [PinsRoute] = []
    @State private var editor: ProjectEditor.Mode?
    @State private var showsArchived = false
    /// Export: the sheet's target; picking pins for it (nil: not picking).
    @State private var export: PinExportTarget?
    @State private var selection: Set<UUID>?
    /// Escape while the export sheet is up: the sheet decides (Cancel while
    /// it works, else close).
    @State private var exportEscape = 0
    #if DEBUG
    @State private var debugOpened = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            PinsHome(model: model, store: store, showsArchived: $showsArchived, done: close) { editor = .new }
                .navigationDestination(for: PinsRoute.self) { route in
                    switch route {
                    case let .project(id):
                        ProjectPage(model: model, store: store, project: id, selection: $selection, done: close, export: { export = $0 }) { editor = .edit(id) }
                    case .unfiled: ProjectPage(model: model, store: store, project: nil, selection: $selection, done: close, export: { export = $0 }) {}
                    case .deleted: RecentlyDeletedPage(model: model, store: store, done: close)
                    }
                }
        }
        // over Layers (iPad) the screen itself is one level more: the last
        // Escape goes back to Layers, as from Storage
        .modalEscape(model, depth: depth + (done == nil ? 0 : 1)) {
            if export != nil { exportEscape += 1 } else if editor != nil { editor = nil } else if selection != nil { selection = nil } else if !path.isEmpty { path.removeLast() } else { done?() }
        }
        .onChange(of: path) { selection = nil }
        .sheet(item: $export) { target in
            PinExportSheet(store: store, target: target, escapeRequest: exportEscape) { export = nil }
                .projectEditorPresentation()
        }
        .sheet(item: $editor) { mode in
            ProjectEditor(model: model, store: store, mode: mode, deleted: {
                // the deleted project's page has nothing left to show
                if case let .project(id)? = path.last, store.project(id) == nil { path.removeLast() }
            }, close: { editor = nil })
            .projectEditorPresentation()
        }
        // Undo for a project (or a pin) deleted while the screen is up: at
        // its foot (the map's banner slot is under the sheet)
        .safeAreaInset(edge: .bottom) {
            if let undo = model.pinUndo {
                PinUndoBanner(undo: undo, onMap: false) { model.undoPinDelete() } onDismiss: { model.setPinUndo(nil) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.pinUndo)
        #if DEBUG
        // screenshots: `-openPinsProject <name>` / `-openPinsDeleted YES`
        .task {
            guard !debugOpened else { return }
            debugOpened = true
            let args = UserDefaults.standard
            if let name = args.string(forKey: "openPinsProject"), let p = store.projects.first(where: { $0.name.hasPrefix(name) }) {
                path = [.project(p.id)]
            } else if args.bool(forKey: "openPinsDeleted") {
                path = [.deleted]
            }
            // `-openPinsSelect N`: selecting, the first N pins ticked
            if args.object(forKey: "openPinsSelect") != nil, let last = path.last {
                // after the push (a path change ends selecting)
                try? await Task.sleep(for: .milliseconds(500))
                let project: PinProject? = if case let .project(id) = last { store.project(id) } else { nil }
                selection = Set(store.pins(in: project).prefix(args.integer(forKey: "openPinsSelect")).map(\.id))
            }
            if args.bool(forKey: "openPinsExport"), let last = path.last {
                switch last {
                case let .project(id): export = PinExportTarget(project: id, pins: nil)
                case .unfiled: export = PinExportTarget(project: nil, pins: nil)
                case .deleted: break
                }
            }
            if args.bool(forKey: "openPinsEditor") { editor = path.last.flatMap { if case let .project(id) = $0 { .edit(id) } else { nil } } ?? .new }
        }
        #endif
        .accessibilityIdentifier("pins-screen")
    }

    /// Levels above the home page: a pushed page, picking pins, a sheet.
    private var depth: Int {
        path.count + (editor == nil && export == nil ? 0 : 1) + (selection == nil ? 0 : 1)
    }

    /// ✓: back to Layers when opened from it, else the whole screen closes.
    private func close() {
        if let done { done() } else { model.dismissModal() }
    }
}

// MARK: - Home

private struct PinsHome: View {
    let model: AppModel
    let store: PinStore
    @Binding var showsArchived: Bool
    let done: () -> Void
    let newProject: () -> Void

    private var isEmpty: Bool { store.pins.isEmpty && store.projects.isEmpty }

    var body: some View {
        PinsList {
            // nothing yet: the drawing teaches the two gestures; a project
            // can wait (the toolbar's + makes one any time)
            if isEmpty {
                Section {
                    PinsEmptyState()
                        .listRowSeparator(.hidden)
                }
                .panelRows()
            }

            // projects, then Unfiled as the list's last row (not a project:
            // a glyph, not a swatch)
            if !store.activeProjects.isEmpty || store.unfiledCount > 0 {
                Section {
                    ForEach(store.activeProjects) { project in
                        ProjectRow(store: store, project: project)
                    }
                    if store.unfiledCount > 0 {
                        NavigationLink(value: PinsRoute.unfiled) {
                            PinsRowLabel(title: "Unfiled", status: Self.status(store.pins(in: nil), in: store)) {
                                GlyphSwatch(symbol: "tray")
                            }
                        }
                        .accessibilityIdentifier("pins-unfiled")
                    }
                } header: {
                    if !store.activeProjects.isEmpty { Text("Projects").panelHeader() }
                } footer: {
                    if store.pins.isEmpty {
                        Text("Long-press the map to place a pin; it joins the project you used last.")
                            .foregroundStyle(DesignColor.secondaryInk)
                    } else if store.activeProjects.isEmpty {
                        Text("Unfiled pins are in no project; a pin’s card files it in one.")
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                }
                .panelRows()
            }

            // what is out of the way: archived projects (folded), the bin
            if !store.archivedProjects.isEmpty || store.hasDeleted {
                Section {
                    if !store.archivedProjects.isEmpty {
                        Button {
                            withAnimation(.snappy) { showsArchived.toggle() }
                        } label: {
                            HStack(spacing: 12) {
                                PinsRowLabel(title: "Archived", status: "\(store.archivedProjects.count.formatted()) \(store.archivedProjects.count == 1 ? "project" : "projects") · off the map") {
                                    GlyphSwatch(symbol: "archivebox")
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.down")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(DesignColor.secondaryInk)
                                    .rotationEffect(.degrees(showsArchived ? 180 : 0))
                                    .frame(width: 14, height: 44)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("pins-archived")
                        if showsArchived {
                            ForEach(store.archivedProjects) { project in
                                ProjectRow(store: store, project: project)
                            }
                        }
                    }
                    if store.hasDeleted {
                        NavigationLink(value: PinsRoute.deleted) {
                            PinsRowLabel(title: "Recently deleted", status: Self.deletedStatus(store)) {
                                GlyphSwatch(symbol: "trash")
                            }
                        }
                        .accessibilityIdentifier("pins-deleted")
                    }
                }
                .panelRows()
            }

            // where the pins are (iCloud or this device only), and what it
            // all takes on this device (photos are most of it)
            let hasPins = !store.pins.isEmpty || store.hasDeleted
            if hasPins || store.sync != nil {
                Section {} footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // where they are ("On this iPad only", "In iCloud"),
                        // then what they take — the device named once
                        PinSyncLine(sync: store.sync)
                        if hasPins, let size = PinsStorageSection.size(bytes) {
                            Text(PinsScreenText.sizeLine(pins: store.pins.count, photos: store.photoCount(store.pins),
                                               deleted: store.deletedPins.count
                                                   + store.deletedProjects.reduce(0) { $0 + store.pinsDeleted(with: $1).count },
                                               size: size))
                                .monospacedDigit()
                                .foregroundStyle(DesignColor.secondaryInk)
                                .accessibilityIdentifier("pins-size")
                        }
                    }
                }
            }
        }
        .navigationTitle("Pins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New project", systemImage: "plus", action: newProject)
                    .keyboardShortcut("n")
                    .accessibilityIdentifier("pins-new-project")
            }
            DoneItem(done: done)
        }
        .task(id: store.saves) { bytes = await store.bytesOnDisk() }
    }

    @State private var bytes = 0

    /// "12 pins · 5 photos · 3–24 Nov", "12 pins · 3–24 Nov", "No pins yet".
    static func status(_ pins: [SavedPin], in store: PinStore) -> String {
        guard !pins.isEmpty else { return "No pins yet" }
        let range = PinText.dateRange(pins.map(\.createdAt)).map { " · \($0)" } ?? ""
        return PinText.count(pins: pins.count, photos: store.photoCount(pins)) + range
    }

    static func deletedStatus(_ store: PinStore) -> String {
        let projects = store.deletedProjects.count, pins = store.deletedPins.count
        var parts: [String] = []
        if projects > 0 { parts.append("\(projects.formatted()) \(projects == 1 ? "project" : "projects")") }
        if pins > 0 { parts.append(PinText.count(pins)) }
        return parts.joined(separator: " · ") + " · kept 30 days"
    }
}

/// No pins and no projects yet: the state's silhouette with a few pins as
/// the map draws them, and the two ways to place one.
private struct PinsEmptyState: View {
    @State private var footprints = FootprintStore.shared

    /// Where the drawing's pins sit (Hobart, the Freycinet coast, Cradle, the
    /// Tamar), in four palette colours.
    private static let sample: [(latitude: Double, longitude: Double, hex: String)] = [
        (-42.88, 147.33, PinColour.orange.hex), (-42.05, 148.12, PinColour.teal.hex),
        (-41.65, 145.95, PinColour.violet.hex), (-41.25, 146.90, PinColour.gold.hex),
    ]

    var body: some View {
        VStack(spacing: 14) {
            if let outline = footprints.outline {
                TasmaniaMiniMap(outline: outline, marks: .pins(Self.sample, radius: 5), scaleBar: false)
                    .frame(width: 132)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text("No pins yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                Text("Long-press the map to place a pin where you point, or tap \(Image(systemName: "mappin.and.ellipse")) to pin where you are.")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pins-empty")
    }
}

/// A project: its swatch, name and "n pins · dates".
private struct ProjectRow: View {
    let store: PinStore
    let project: PinProject

    var body: some View {
        NavigationLink(value: PinsRoute.project(project.id)) {
            PinsRowLabel(title: PinText.projectName(project.name), status: PinsHome.status(store.pins(in: project), in: store), titleLines: 2) {
                KeyBox(hex: PinColour.hex(forName: project.colour), opacity: 1, width: PinsMetrics.swatch, height: PinsMetrics.swatch)
            }
        }
        .accessibilityIdentifier("pins-project-\(project.name)")
    }
}

// MARK: - A project's page (and Unfiled)

/// A project — or, with `project` nil, the Unfiled pins: a header (swatch,
/// name, note, counts and dates, Show on map, Edit), then its pins. A pin
/// row closes the screen and opens the pin's card on the map.
private struct ProjectPage: View {
    let model: AppModel
    let store: PinStore
    /// nil: Unfiled.
    let project: UUID?
    /// Picking pins to export (nil: not picking).
    @Binding var selection: Set<UUID>?
    let done: () -> Void
    let export: (PinExportTarget) -> Void
    let edit: () -> Void
    /// The header (with the name) is on screen: the bar stays empty until
    /// it scrolls away, so the name is never shown twice.
    @State private var headerVisible = true
    /// The page's width and where the header row's content sits in it:
    /// the export bar lines up with the rows' edges.
    @State private var pageFrame: CGRect = .zero
    @State private var contentFrame: CGRect = .zero

    var body: some View {
        let record = project.flatMap { store.project($0) }
        let list = store.pins(in: record)
        PinsList {
            if project == nil || record != nil {
                Section {
                    header(record, pins: list)
                }
                .panelRows()

                Section {
                    if list.isEmpty {
                        Text(record == nil ? "No unfiled pins." : "No pins yet. Choose this project on a pin’s card to file the pin here.")
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .padding(.vertical, 4)
                    }
                    ForEach(list) { pin in
                        if let chosen = selection {
                            PinRow(store: store, pin: pin, enabled: true, selected: chosen.contains(pin.id)) {
                                if chosen.contains(pin.id) { selection?.remove(pin.id) } else { selection?.insert(pin.id) }
                            }
                        } else {
                            PinRow(store: store, pin: pin, enabled: pin.isOnMap) { model.showPin(pin.id) }
                        }
                    }
                } header: {
                    if !list.isEmpty { PinsSectionHeader(count: list.count, selection: $selection, all: list.map(\.id)) }
                }
                .panelRows()
            }
        }
        // both in window coordinates (a named space doesn't reach into
        // the list's rows)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pageFrame = $0 }
        .navigationTitle(headerVisible ? "" : record.map { PinText.projectName($0.name) } ?? "Unfiled")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // picking pins: one way out, in words — no ✕ beside the ✓
            // that would read as Cancel / Done
            if selection != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { withAnimation(.snappy) { selection = nil } }
                        .accessibilityIdentifier("pins-select-cancel")
                }
            } else {
                DoneItem(done: done)
            }
        }
        .navigationBarBackButtonHidden(selection != nil)
        .safeAreaInset(edge: .bottom) {
            if let chosen = selection {
                let measured = contentFrame.width > 0 && pageFrame.width > 0
                ExportSelectionBar(count: chosen.count, leading: measured ? max(0, contentFrame.minX - pageFrame.minX) : 16,
                                   trailing: measured ? max(0, pageFrame.maxX - contentFrame.maxX) : 16) {
                    export(PinExportTarget(project: project, pins: chosen))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func header(_ record: PinProject?, pins: [SavedPin]) -> some View {
        let archived = record?.archivedAt != nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                if let record {
                    KeyBox(hex: PinColour.hex(forName: record.colour), opacity: 1, width: 44, height: 44)
                } else {
                    GlyphSwatch(symbol: "tray", side: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.map { PinText.projectName($0.name) } ?? "Unfiled")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("project-title")
                        .onScrollVisibilityChange(threshold: 0.5) { headerVisible = $0 }
                    Text(archived ? "Archived · \(PinsHome.status(pins, in: store))" : PinsHome.status(pins, in: store))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                }
                Spacer(minLength: 0)
            }
            if let note = record?.note.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Text(note)
                    .font(.body)
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if archived {
                Text("Its pins are off the map. Unarchive it (Edit) to show them again.")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // while picking pins the bar at the foot is the one action
            if selection == nil {
                actions(record, pins: pins, archived: archived)
            }
        }
        .padding(.vertical, 6)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contentFrame = $0 }
    }

    private func actions(_ record: PinProject?, pins: [SavedPin], archived: Bool) -> some View {
        HStack(spacing: 8) {
            if !archived {
                Button { model.showOnMap(pins) } label: {
                    ActionLabel(title: "Show on map", symbol: "map")
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(pins.isEmpty)
                .opacity(pins.isEmpty ? 0.4 : 1)
                .accessibilityIdentifier("project-show")
            }
            Button { export(PinExportTarget(project: project, pins: nil)) } label: {
                ActionLabel(title: "Export", symbol: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(pins.isEmpty)
            .opacity(pins.isEmpty ? 0.4 : 1)
            .accessibilityIdentifier("project-export")
            if record != nil {
                Button(action: edit) {
                    ActionLabel(title: "Edit", symbol: "pencil")
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("project-edit")
            }
        }
    }
}

/// One pin: the map's mark, its name, the date, the note's first line.
private struct PinRow: View {
    let store: PinStore
    let pin: SavedPin
    /// Off the map (an archived project): shown, not a way to the map.
    let enabled: Bool
    /// Picking pins to export: the row's checkmark (nil: not picking).
    var selected: Bool? = nil
    let show: () -> Void

    var body: some View {
        let row = Self.title(pin)
        let title = row.text
        let noteLine = PinText.firstLine(pin.note)
        Button(action: show) {
            // one 40 pt lead column: the newest photo, or the map's mark on
            // a key plate of the same size
            HStack(alignment: .center, spacing: 12) {
                PinRowMark(store: store, pin: pin, side: PinPhotoMetrics.row)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .foregroundStyle(row.untitled ? DesignColor.secondaryInk : DesignColor.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(PinText.shortDate(pin.createdAt))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                            .fixedSize()
                    }
                    if let noteLine {
                        Text(noteLine)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .lineLimit(1)
                    }
                }
                if let selected { SelectionMark(on: selected) }
            }
            .frame(minHeight: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .accessibilityAddTraits(selected == true ? .isSelected : [])
        .accessibilityIdentifier("pin-row-\(pin.displayTitle)")
    }

    static func title(_ pin: SavedPin) -> (text: String, untitled: Bool) { PinsScreenText.rowTitle(pin.title) }
}

/// The Pins screen's words that follow rules (unit-tested).
nonisolated enum PinsScreenText {
    /// A pin row's title: the pin's own, else "Untitled pin" (set in
    /// secondary ink) — never its note, which has the second line, nor the
    /// date, which every row shows trailing.
    static func rowTitle(_ title: String) -> (text: String, untitled: Bool) {
        let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? ("Untitled pin", true) : (own, false)
    }

    /// The status line under the list: "25 pins · 32 photos · 10 MB";
    /// with only deleted ones left, "No pins on the map · 1 in Recently
    /// deleted · 3.2 MB" (never "0 pins" beside a size). The device is
    /// named once, by the sync line above it.
    static func sizeLine(pins: Int, photos: Int, deleted: Int, size: String) -> String {
        if pins == 0, deleted > 0 { return "No pins on the map · \(deleted.formatted()) in Recently deleted · \(size)" }
        return "\(PinText.count(pins: pins, photos: photos)) · \(size)"
    }

    /// A Recently deleted row's two lines: where it goes back to (and its
    /// photos), then the days left — "Knocklofty Reserve · 3 photos" /
    /// "12 days left".
    static func deletedStatus(place: String, photos: Int, daysLeft: Int) -> String {
        let first = place + (photos > 0 ? " · \(PinText.photoCount(photos))" : "")
        return first + "\n" + (daysLeft == 1 ? "1 day left" : "\(daysLeft) days left")
    }
}

// MARK: - Recently deleted

/// Soft-deleted projects and pins with the days left before they go for
/// good: Restore, Delete now (asks first), Delete all now.
private struct RecentlyDeletedPage: View {
    let model: AppModel
    let store: PinStore
    let done: () -> Void
    @State private var confirm: PinsDeleteNow?

    var body: some View {
        PinsList {
            Section {
                if !store.hasDeleted {
                    Text("Nothing deleted in the last 30 days.")
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .padding(.vertical, 4)
                }
                ForEach(store.deletedProjects) { project in
                    let gone = store.pinsDeleted(with: project)
                    DeletedRow(title: PinText.projectName(project.name), titleLines: 2,
                               status: PinsScreenText.deletedStatus(place: PinText.count(gone.count), photos: store.photoCount(gone),
                                                                    daysLeft: store.daysLeft(project.deletedAt)),
                               restore: { store.restoreProject(project) },
                               delete: { confirm = .project(project, in: store) }) {
                        KeyBox(hex: PinColour.hex(forName: project.colour), opacity: 1, width: PinsMetrics.swatch, height: PinsMetrics.swatch)
                    }
                }
                ForEach(store.deletedPins) { pin in
                    let row = PinRow.title(pin)
                    DeletedRow(title: row.text, untitled: row.untitled,
                               status: PinsScreenText.deletedStatus(place: Self.place(pin), photos: store.photoCount(of: pin),
                                                                    daysLeft: store.daysLeft(pin.deletedAt)),
                               identifier: pin.displayTitle,
                               restore: { store.restore(pin) },
                               delete: { confirm = .pin(pin) }) {
                        PinRowMark(store: store, pin: pin, side: PinsMetrics.swatch)
                    }
                }
            } footer: {
                Text("Deleted pins and projects stay here for 30 days, then they’re gone for good.")
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .panelRows()

            if store.hasDeleted {
                Section {
                    Button(role: .destructive) { confirm = .all(in: store) } label: {
                        Text("Delete all now")
                            .foregroundStyle(Color(uiColor: .systemRed))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("deleted-delete-all")
                }
                .panelRows()
            }
        }
        .navigationTitle("Recently deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneItem(done: done) }
        // overdue items go now, not only at launch (a long-running iPad)
        .onAppear { model.purgePins() }
        // the dialog shows words taken when it opened — never a record that
        // "Delete" has just removed (read while the dialog animates away)
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button(c.button, role: .destructive) { model.deleteNow(c) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    /// Where a pin goes back to: "Knocklofty", "Unfiled".
    static func place(_ pin: SavedPin) -> String {
        guard let project = pin.project, project.deletedAt == nil else { return "Unfiled" }
        return PinText.projectName(project.name)
    }
}

private struct DeletedRow<Mark: View>: View {
    let title: String
    var titleLines = 1
    var untitled = false
    let status: String
    /// The row's id in UI tests (default: the title).
    var identifier: String? = nil
    let restore: () -> Void
    let delete: () -> Void
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        let title = identifier ?? self.title
        HStack(spacing: 8) {
            PinsRowLabel(title: self.title, status: status, titleLines: titleLines, statusLines: 2, untitled: untitled, mark: mark)
            Spacer(minLength: 0)
            Button(action: delete) {
                Image(systemName: "trash")
                    .foregroundStyle(DesignColor.secondaryInk)
                    .frame(width: 40, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Delete now")
            .accessibilityIdentifier("deleted-delete-\(title)")
            GetButton(title: "Restore", action: restore)
                .accessibilityIdentifier("deleted-restore-\(title)")
        }
    }
}

// MARK: - Shared pieces

enum PinsMetrics {
    /// A project's square swatch in a row.
    static let swatch: CGFloat = 28
}

/// The list as Storage builds it: below the navigation bar behind a
/// hairline, rows straight on the opaque sheet, compact section spacing —
/// every Pins surface (the screen's pages, the project editor, Export).
struct PinsList<Content: View>: View {
    /// The list's side margins (nil: the system's, as Storage).
    var horizontalMargin: CGFloat? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            List { content }
                .panelListSurface()
                .listSectionSpacing(.compact)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
        }
        // a pushed page keeps the sheet's own ground (the navigation
        // container otherwise lays an opaque white page over it on iPad)
        .containerBackground(.clear, for: .navigation)
    }
}

/// A row's mark, name and status line. A project's name may take two
/// lines (a long one keeps its distinguishing tail; beyond that the
/// middle goes), a status line too where it carries two facts.
private struct PinsRowLabel<Mark: View>: View {
    let title: String
    let status: String?
    var titleLines = 1
    var statusLines = 1
    /// "Untitled pin": a stand-in, in secondary ink.
    var untitled = false
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 12) {
            mark()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(untitled ? DesignColor.secondaryInk : DesignColor.ink)
                    .lineLimit(titleLines)
                    .truncationMode(titleLines > 1 ? .middle : .tail)
                    .fixedSize(horizontal: false, vertical: true)
                // each line of the status its own (a narrow row may wrap the
                // first — a project's name — but never drop the next)
                if let status {
                    let lines = status.split(separator: "\n").map(String.init)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(DesignColor.secondaryInk)
                                .lineLimit(i == 0 ? statusLines : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }
}

/// A glyph in the swatch column (Unfiled, Archived, Recently deleted): a
/// keyline square with no fill — not a colour, so not a key box.
struct GlyphSwatch: View {
    let symbol: String
    var side: CGFloat = PinsMetrics.swatch

    var body: some View {
        Image(systemName: symbol)
            .font(side > 30 ? .title3 : .footnote)
            .foregroundStyle(DesignColor.secondaryInk)
            .frame(width: side, height: side)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

/// Done: closes the whole screen — or goes back to Layers when opened from
/// it (as in Storage).
private struct DoneItem: ToolbarContent {
    let done: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark", action: done)
                .accessibilityIdentifier("pins-done")
        }
    }
}

// MARK: - Storage

/// Storage → "Pins": how many, and what the store takes on this device,
/// photos included (`PinStore.bytesOnDisk` walks the external-data folder).
/// A state row whose chevron leads to the Pins screen — pins are deleted
/// there, nothing is removed here.
struct PinsStorageSection: View {
    let store: PinStore
    /// The store on disk (StorageView measures it as the store saves).
    let bytes: Int64
    /// Opens the Pins screen.
    let open: () -> Void
    @State private var footprints = FootprintStore.shared

    var body: some View {
        Section {
            Button(action: open) { row }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("pins-storage")
        } header: {
            Text("Pins").panelHeader()
        } footer: {
            Text(PinSyncText.storageFooter(store.sync?.status ?? .localOnly, now: Date(), device: DeviceNoun.current))
                .foregroundStyle(DesignColor.secondaryInk)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Group {
                if let outline = footprints.outline {
                    TasmaniaMiniMap(outline: outline, marks: .pins(marks, radius: 2), scaleBar: false)
                } else {
                    GlyphSwatch(symbol: "mappin.and.ellipse", side: StorageMetrics.thumbWidth)
                }
            }
            .frame(width: StorageMetrics.thumbWidth, height: StorageMetrics.thumbHeight)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(pins: store.pins.count, projects: store.projects.count))
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                StatusLine(symbol: StateSymbol.onDevice,
                           text: "On this \(DeviceNoun.current)" + (Self.size(Int(bytes)).map { " · \($0)" } ?? ""),
                           identifier: "pins-storage-status")
            }
            Spacer(minLength: 8)
            // the system's disclosure chevron, as a NavigationLink draws it
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 2)
        }
        .padding(.vertical, 4)
        .frame(minHeight: StorageMetrics.thumbHeight + 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Where her pins are (the map's drawing, small).
    private var marks: [(latitude: Double, longitude: Double, hex: String)] {
        store.mapPins.map { ($0.lat, $0.lon, PinColour.hex(forName: $0.effectiveColourName)) }
    }

    /// "248 KB" under a megabyte (a store of notes is small), else as the
    /// other rows; nil for nothing on disk (an in-memory store).
    static func size(_ bytes: Int) -> String? {
        guard bytes > 0 else { return nil }
        return bytes < 1_000_000 ? "\(max(1, Int((Double(bytes) / 1000).rounded())))\u{00A0}KB" : StorageText.size(bytes)
    }

    /// "12 pins in 3 projects", "1 pin", "No pins yet".
    static func title(pins: Int, projects: Int) -> String {
        guard pins > 0 || projects > 0 else { return "No pins yet" }
        guard projects > 0 else { return PinText.count(pins) }
        return "\(PinText.count(pins)) in \(projects.formatted()) \(projects == 1 ? "project" : "projects")"
    }
}
