import SwiftUI

/// The one project editor (docs/PINS_PLAN.md §5): a form sheet with the
/// name and the colour — and, for a project that exists, its note,
/// Archive and Delete. Opened from a pin card's project chip ("New
/// project…") and from the Pins screen (New project, Edit). Changes apply
/// on Create / Save (Return in the name field); Cancel or Escape closes
/// just this sheet. Archive and Delete act at once (Delete is soft, with
/// Undo).
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
    let close: () -> Void

    @State private var name = ""
    @State private var colour = PinColour.standard
    @State private var note = ""
    @State private var loaded = false
    /// What the fields held when the sheet opened (changes = a difference).
    @State private var original: Fields?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, note }

    private var project: PinProject? { Self.project(mode, in: store) }
    /// From the mode, never from the lookup: a project that went away while
    /// its editor was open must not turn the sheet into "New Project".
    private var isNew: Bool { mode == .new }

    private var fields: Fields { Fields(name: name, colour: colour, note: note) }
    /// Something typed or picked that Save would keep (swipe-down is then
    /// off; Cancel stays the explicit discard).
    private var hasChanges: Bool { original.map { $0 != fields } ?? false }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        KeyBox(hex: colour.hex, opacity: 1, width: 28, height: 28)
                        TextField("Name", text: $name, prompt: Text("Name, e.g. the site").foregroundStyle(DesignColor.secondaryInk))
                            .font(.headline)
                            .foregroundStyle(DesignColor.ink)
                            .focused($focus, equals: .name)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityIdentifier("project-name")
                    }
                    .frame(minHeight: 44)
                }

                Section {
                    SwatchRow(selected: colour.rawValue) { colour = $0 }
                        .padding(.vertical, 2)
                } header: {
                    Text("Colour").foregroundStyle(DesignColor.secondaryInk)
                } footer: {
                    Text("Its pins take this colour, unless a pin has its own.")
                        .foregroundStyle(DesignColor.secondaryInk)
                }

                if let project {
                    Section {
                        TextField("Note", text: $note, prompt: Text("Add a note").foregroundStyle(DesignColor.secondaryInk),
                                  axis: .vertical)
                            .font(.body)
                            .foregroundStyle(DesignColor.ink)
                            .lineLimit(2 ... 8)
                            .focused($focus, equals: .note)
                            .accessibilityIdentifier("project-note")
                    } header: {
                        Text("Note").foregroundStyle(DesignColor.secondaryInk)
                    }

                    Section {
                        Button {
                            Self.toggleArchived(mode, fields: fields, in: store)
                            close()
                        } label: {
                            Label(project.archivedAt == nil ? "Archive Project" : "Unarchive Project",
                                  systemImage: project.archivedAt == nil ? "archivebox" : "tray.and.arrow.up")
                                .foregroundStyle(DesignColor.ink)
                        }
                        .accessibilityIdentifier("project-archive")
                        Button(role: .destructive) {
                            model.deleteProject(project)
                            close()
                            deleted()
                        } label: {
                            Label("Delete Project", systemImage: "trash")
                                .foregroundStyle(Color(uiColor: .systemRed))
                        }
                        .accessibilityIdentifier("project-delete")
                    } footer: {
                        Text(Self.footer(project, pins: store.pins(in: project).count))
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                }
            }
            .navigationTitle(isNew ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: close)
                        .accessibilityIdentifier("project-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save", action: save)
                        .buttonStyle(.glassProminent)
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("project-save")
                }
            }
        }
        .onAppear(perform: load)
        .interactiveDismissDisabled(hasChanges)
        // the project went away while its editor was open (another window,
        // later iCloud): nothing left to edit
        .onChange(of: store.revision, initial: true) {
            if !isNew, project == nil { close() }
        }
        .accessibilityIdentifier("project-editor")
    }

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
    /// The project editor's presentation: the large (opaque) sheet on a
    /// phone — at medium it would be glass over a busy list or card — and
    /// a form sheet that fits its content on an iPad.
    func projectEditorPresentation() -> some View {
        presentationDetents([.large])
            .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    }
}
