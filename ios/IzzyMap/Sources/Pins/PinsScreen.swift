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
    @State private var path: [PinsRoute] = []
    @State private var editor: ProjectEditor.Mode?
    @State private var showsArchived = false
    #if DEBUG
    @State private var debugOpened = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            PinsHome(model: model, store: store, showsArchived: $showsArchived) { editor = .new }
                .navigationDestination(for: PinsRoute.self) { route in
                    switch route {
                    case let .project(id): ProjectPage(model: model, store: store, project: id) { editor = .edit(id) }
                    case .unfiled: ProjectPage(model: model, store: store, project: nil) {}
                    case .deleted: RecentlyDeletedPage(model: model, store: store)
                    }
                }
        }
        .modalEscape(model, depth: path.count + (editor == nil ? 0 : 1)) {
            if editor != nil { editor = nil } else if !path.isEmpty { path.removeLast() }
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
            if args.bool(forKey: "openPinsEditor") { editor = path.last.flatMap { if case let .project(id) = $0 { .edit(id) } else { nil } } ?? .new }
        }
        #endif
        .accessibilityIdentifier("pins-screen")
    }
}

// MARK: - Home

private struct PinsHome: View {
    let model: AppModel
    let store: PinStore
    @Binding var showsArchived: Bool
    let newProject: () -> Void

    private var isEmpty: Bool { store.pins.isEmpty && store.projects.isEmpty }

    var body: some View {
        PinsList {
            Section {
                NewProjectButton(action: newProject)
                    .listRowSeparator(.hidden)
                if isEmpty {
                    PinsEmptyState()
                        .listRowSeparator(.hidden)
                }
            }
            .panelRows()

            // projects, then Unfiled as the list's last row (not a project:
            // a glyph, not a swatch)
            if !store.activeProjects.isEmpty || store.unfiledCount > 0 {
                Section {
                    ForEach(store.activeProjects) { project in
                        ProjectRow(store: store, project: project)
                    }
                    if store.unfiledCount > 0 {
                        NavigationLink(value: PinsRoute.unfiled) {
                            PinsRowLabel(title: "Unfiled", status: Self.status(store.pins(in: nil))) {
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
        }
        .navigationTitle("Pins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneItem(model: model) }
    }

    /// "12 pins · 3–24 Nov", "No pins yet".
    static func status(_ pins: [SavedPin]) -> String {
        guard !pins.isEmpty else { return "No pins yet" }
        let range = PinText.dateRange(pins.map(\.createdAt)).map { " · \($0)" } ?? ""
        return PinText.count(pins.count) + range
    }

    static func deletedStatus(_ store: PinStore) -> String {
        let projects = store.deletedProjects.count, pins = store.deletedPins.count
        var parts: [String] = []
        if projects > 0 { parts.append("\(projects.formatted()) \(projects == 1 ? "project" : "projects")") }
        if pins > 0 { parts.append(PinText.count(pins)) }
        return parts.joined(separator: " · ") + " · kept 30 days"
    }
}

/// "New project": the screen's point, first — the ink capsule Storage
/// uses for "Download an area…". ⌘N on a keyboard.
private struct NewProjectButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New project", systemImage: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(DesignColor.ink, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .keyboardShortcut("n")
        .padding(.vertical, 4)
        .accessibilityIdentifier("pins-new-project")
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
            PinsRowLabel(title: PinText.projectName(project.name), status: PinsHome.status(store.pins(in: project))) {
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
    let edit: () -> Void
    /// The header (with the name) is on screen: the bar stays empty until
    /// it scrolls away, so the name is never shown twice.
    @State private var headerVisible = true

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
                        PinRow(pin: pin, enabled: pin.isOnMap) { model.showPin(pin.id) }
                    }
                } header: {
                    if !list.isEmpty { Text("Pins").panelHeader() }
                }
                .panelRows()
            }
        }
        .navigationTitle(headerVisible ? "" : record.map { PinText.projectName($0.name) } ?? "Unfiled")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneItem(model: model) }
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
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("project-title")
                        .onScrollVisibilityChange(threshold: 0.5) { headerVisible = $0 }
                    Text(archived ? "Archived · \(PinsHome.status(pins))" : PinsHome.status(pins))
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
        .padding(.vertical, 6)
    }
}

/// One pin: the map's mark, its name, the date, the note's first line.
private struct PinRow: View {
    let pin: SavedPin
    /// Off the map (an archived project): shown, not a way to the map.
    let enabled: Bool
    let show: () -> Void

    var body: some View {
        let title = pin.displayTitle
        let hasTitle = !pin.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let noteLine = PinText.firstLine(pin.note)
        // an untitled pin is named by its note or its date: don't say it twice
        let date = hasTitle || noteLine != nil ? PinText.shortDate(pin.createdAt) : nil
        Button(action: show) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                PinMark(hex: PinColour.hex(forName: pin.effectiveColourName))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .foregroundStyle(DesignColor.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let date {
                            Text(date)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(DesignColor.secondaryInk)
                                .fixedSize()
                        }
                    }
                    if hasTitle, let noteLine {
                        Text(noteLine)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .accessibilityIdentifier("pin-row-\(title)")
    }
}

// MARK: - Recently deleted

/// Soft-deleted projects and pins with the days left before they go for
/// good: Restore, Delete now (asks first), Delete all now.
private struct RecentlyDeletedPage: View {
    let model: AppModel
    let store: PinStore
    @State private var confirm: PinsDeleteNow?

    var body: some View {
        PinsList {
            Section {
                if !store.hasDeleted {
                    Text("Nothing here.")
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .padding(.vertical, 4)
                }
                ForEach(store.deletedProjects) { project in
                    DeletedRow(title: PinText.projectName(project.name),
                               status: "\(PinText.count(store.pinsDeleted(with: project).count)) · \(daysLeft(project.deletedAt))",
                               restore: { store.restoreProject(project) },
                               delete: { confirm = .project(project, in: store) }) {
                        KeyBox(hex: PinColour.hex(forName: project.colour), opacity: 1, width: PinsMetrics.swatch, height: PinsMetrics.swatch)
                    }
                }
                ForEach(store.deletedPins) { pin in
                    DeletedRow(title: pin.displayTitle, status: "\(daysLeft(pin.deletedAt)) · \(Self.place(pin))",
                               restore: { store.restore(pin) },
                               delete: { confirm = .pin(pin) }) {
                        PinMark(hex: PinColour.hex(forName: pin.effectiveColourName))
                            .frame(width: PinsMetrics.swatch)
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
                        Text("Delete All Now")
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
        .toolbar { DoneItem(model: model) }
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

    private func daysLeft(_ date: Date?) -> String {
        let n = store.daysLeft(date)
        return n == 1 ? "1 day left" : "\(n) days left"
    }

    /// "Knocklofty", "Unfiled".
    static func place(_ pin: SavedPin) -> String {
        guard let project = pin.project, project.deletedAt == nil else { return "Unfiled" }
        return PinText.projectName(project.name)
    }
}

private struct DeletedRow<Mark: View>: View {
    let title: String
    let status: String
    let restore: () -> Void
    let delete: () -> Void
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 8) {
            PinsRowLabel(title: title, status: status, mark: mark)
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
/// hairline, rows straight on the opaque sheet, compact section spacing.
private struct PinsList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            List { content }
                .panelListSurface()
                .listSectionSpacing(.compact)
                .contentMargins(.top, 8, for: .scrollContent)
        }
    }
}

/// A row's mark, name (one line, truncated) and status line.
private struct PinsRowLabel<Mark: View>: View {
    let title: String
    let status: String
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 12) {
            mark()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(DesignColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.secondaryInk)
                    .lineLimit(1)
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

/// Done: closes the whole screen (as in Storage).
private struct DoneItem: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark") { model.dismissModal() }
                .accessibilityIdentifier("pins-done")
        }
    }
}

// MARK: - Storage

/// Storage → "Pins": how many, and what the store takes on this device
/// (photos will add to it). A state row, like the others; nothing to remove
/// here — pins are deleted in Pins.
struct PinsStorageSection: View {
    let store: PinStore
    /// The store on disk (StorageView measures it as the store saves).
    let bytes: Int64
    @State private var footprints = FootprintStore.shared

    var body: some View {
        Section {
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
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(minHeight: StorageMetrics.thumbHeight + 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pins-storage")
        } header: {
            Text("Pins").panelHeader()
        } footer: {
            Text("Your pins, notes and projects, kept on this \(DeviceNoun.current) and in its backups.")
                .foregroundStyle(DesignColor.secondaryInk)
        }
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
