import SwiftUI

/// The one project editor (docs/PINS_PLAN.md §5): a form sheet with the
/// name and the colour — and, for a project that exists, its note,
/// Archive and Delete. Opened from a pin card's project chip ("New
/// project…") and from the Pins screen (New project, Edit). Changes apply
/// on Create / Save (Return in the name field); ✕ or Escape closes just
/// this sheet (both ask first when something was typed). Archive and
/// Delete act at once (Delete is soft, with Undo).
struct ProjectEditor: View {
    /// What the sheet edits.
    enum Mode: Identifiable, Hashable {
        case new
        case edit(UUID)
        var id: String {
            switch self {
            case .new: "new"
            case let .edit(id): id.uuidString
            }
        }
    }

    let model: AppModel
    let store: PinStore
    let mode: Mode
    /// A new project was made (the card files its pin in it).
    var created: (PinProject) -> Void = { _ in }
    /// The project was deleted (the Pins screen leaves its page).
    var deleted: () -> Void = {}
    /// Bumped by Escape (a hardware keyboard): the same as ✕ — asks first
    /// when something was typed or picked.
    var escapeRequest = 0
    /// Whether something typed or picked would be lost (the card's form:
    /// the model's Escape asks the editor instead of closing it).
    var editedChanged: (Bool) -> Void = { _ in }
    let close: () -> Void

    @State private var name = ""
    @State private var colour = PinColour.standard
    @State private var note = ""
    @State private var loaded = false
    /// What the fields held when the sheet opened (changes = a difference).
    @State private var original: Fields?
    @FocusState private var focus: Field?
    /// The sheet's width (where the palette's row fits at the pages' inset).
    @State private var width: CGFloat = 0
    /// ✕ with something typed or picked: asks before throwing it away.
    @State private var confirmDiscard = false

    private enum Field: Hashable { case name, note }

    private var project: PinProject? { Self.project(mode, in: store) }
    /// From the mode, never from the lookup: a project that went away while
    /// its editor was open must not turn the sheet into "New project".
    private var isNew: Bool { mode == .new }

    private var fields: Fields { Fields(name: name, colour: colour, note: note) }
    /// Something typed or picked that Save would keep (swipe-down is then
    /// off; Cancel stays the explicit discard).
    private var hasChanges: Bool { original.map { $0 != fields } ?? false }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            // plain sections on the sheet's own ground, as Storage, at the
            // Pins pages' insets (no jump from a project's page to Edit) —
            // unless that leaves the palette too little room for its one row
            // of eight (a phone): then the card's own inset
            PinsList(horizontalMargin: width >= Self.pagesInsetWidth ? nil : 0) {
                Section {
                    HStack(spacing: 12) {
                        KeyBox(hex: colour.hex, opacity: 1, width: 28, height: 28)
                        TextField("Name", text: $name, prompt: Text("Name, e.g. the site").foregroundStyle(DesignColor.secondaryInk))
                            .font(.headline)
                            .foregroundStyle(DesignColor.ink)
                            .focused($focus, equals: .name)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                            .accessibilityIdentifier("project-name")
                    }
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Name").panelHeader()
                }
                .panelRows()
                .listSectionSeparator(.hidden)

                Section {
                    // the card's own palette row, as wide as on the card
                    SwatchRow(selected: colour.rawValue) { colour = $0 }
                        .frame(maxWidth: Self.paletteWidth, alignment: .leading)
                        .listRowSeparator(.hidden)
                } header: {
                    Text("Colour").panelHeader()
                } footer: {
                    Text("Its pins take this colour, unless a pin has its own.")
                        .foregroundStyle(DesignColor.secondaryInk)
                }
                .panelRows()
                .listSectionSeparator(.hidden)

                if let project {
                    Section {
                        TextField("Note", text: $note, prompt: Text("Add a note").foregroundStyle(DesignColor.secondaryInk),
                                  axis: .vertical)
                            .font(.body)
                            .foregroundStyle(DesignColor.ink)
                            .lineLimit(2 ... 8)
                            .focused($focus, equals: .note)
                            .padding(12)
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("project-note")
                    } header: {
                        Text("Note").panelHeader()
                    }
                    .panelRows()
                    .listSectionSeparator(.hidden)

                    Section {
                        Button {
                            Self.toggleArchived(mode, fields: fields, in: store)
                            close()
                        } label: {
                            Label(project.archivedAt == nil ? "Archive project" : "Unarchive project",
                                  systemImage: project.archivedAt == nil ? "archivebox" : "tray.and.arrow.up")
                                .foregroundStyle(DesignColor.ink)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("project-archive")
                        Button(role: .destructive) {
                            model.deleteProject(project)
                            close()
                            deleted()
                        } label: {
                            Label("Delete project", systemImage: "trash")
                                .foregroundStyle(Color(uiColor: .systemRed))
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("project-delete")
                    } footer: {
                        Text(Self.footer(project, pins: store.pins(in: project).count))
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                    .panelRows()
                    .listSectionSeparator(.hidden)
                }
            }
            .navigationTitle(isNew ? "New project" : "Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: cancel)
                    .accessibilityIdentifier("project-cancel")
                    // anchored on ✕ (on iPad a popover points at it)
                    .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .hidden) {
                        Button("Discard changes", role: .destructive, action: close)
                            .accessibilityIdentifier("project-discard")
                        Button("Keep editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save", action: save)
                        .buttonStyle(.glassProminent)
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("project-save")
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
        .onAppear(perform: load)
        .interactiveDismissDisabled(hasChanges)
        // Escape: as ✕
        .onChange(of: escapeRequest) { cancel() }
        .onChange(of: hasChanges, initial: true) { editedChanged(hasChanges) }
        .onDisappear { editedChanged(false) }
        // the project went away while its editor was open (another window,
        // later iCloud): nothing left to edit
        .onChange(of: store.revision, initial: true) {
            if !isNew, project == nil { close() }
        }
        .accessibilityIdentifier("project-editor")
    }

    /// The palette row's width: the card's (one row of eight 44 pt
    /// targets), so both editors read as one palette.
    static let paletteWidth: CGFloat = 8 * SwatchLayout.target - (SwatchLayout.target - SwatchRow.visual)
    /// A sheet at least this wide keeps the Pins pages' insets (about
    /// 36 pt a side: the list's margin and the row's) with the palette in
    /// one row.
    static let pagesInsetWidth: CGFloat = paletteWidth + 2 * 36

    static func footer(_ project: PinProject, pins: Int) -> String {
        let archive = project.archivedAt == nil
            ? "An archived project’s pins leave the map; they stay in Pins."
            : "Archived: its pins are off the map."
        let what = pins == 0 ? "the project" : "the project and its \(PinText.count(pins))"
        return "\(archive) Deleting moves \(what) to Recently deleted for 30 days."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let project {
            name = project.name
            colour = PinColour.named(project.colour) ?? .standard
            note = project.note
        } else if isNew {
            colour = store.nextProjectColour()
            focus = .name
        }
        original = fields
    }

    /// ✕ and Escape: close, or ask first when something would be lost.
    private func cancel() {
        if hasChanges { confirmDiscard = true } else { close() }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if case let .created(project) = Self.commit(mode, fields: fields, in: store) { created(project) }
        close()
    }

    // MARK: The edits (static, so tests drive them without a view)

    /// The editor's fields.
    struct Fields: Equatable {
        var name: String
        var colour: PinColour
        var note: String
        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    enum Commit: Equatable {
        case created(PinProject)
        case edited
        /// The edited project is gone: nothing is written (never a duplicate).
        case gone
        /// No name: nothing is written.
        case invalid
    }

    static func project(_ mode: Mode, in store: PinStore) -> PinProject? {
        if case let .edit(id) = mode { return store.project(id) }
        return nil
    }

    /// Save / Create.
    
    static func commit(_ mode: Mode, fields: Fields, in store: PinStore) -> Commit {
        guard !fields.trimmedName.isEmpty else { return .invalid }
        switch mode {
        case .new:
            return .created(store.addProject(name: fields.trimmedName, colour: fields.colour))
        case .edit:
            guard let project = project(mode, in: store) else { return .gone }
            store.editProject(project, name: fields.trimmedName, colour: fields.colour, note: fields.note)
            return .edited
        }
    }

    /// Archive / Unarchive: what was typed before is saved first (with a
    /// name), then the switch — the tap must not drop a rename.
    static func toggleArchived(_ mode: Mode, fields: Fields, in store: PinStore) {
        guard let project = project(mode, in: store) else { return }
        let archive = project.archivedAt == nil
        commit(mode, fields: fields, in: store)
        store.setArchived(project, archive)
    }
}

extension View {
    /// The project editor's (and Export's) presentation: the large
    /// (opaque) sheet on a phone — at medium it would be glass over a busy
    /// list or card — and the system's form sheet on an iPad, as Storage.
    /// (Fitted to its content it collapsed to the title bar: a `List` has
    /// no ideal height.)
    func projectEditorPresentation() -> some View {
        presentationDetents([.large])
            .presentationSizing(.form)
    }
}
