import IzzyKit
import MapKit
import SwiftUI
import UIKit

/// A saved pin's card (docs/PINS_PLAN.md §5, photos to come): the glance —
/// the map's mark, the title edited in place, the project chip — then
/// colour, note, facts and the actions Move / Open in Maps / Delete.
/// Title and note save as she types (`PinStore`, flushed when the card
/// goes); nothing here is a modal.
struct PinCard: View {
    let model: AppModel
    let store: PinStore
    let pinID: UUID
    @Environment(\.panelActions) private var actions
    @FocusState private var focus: Field?
    /// Which fact was just copied ("Copied" stands in for it briefly).
    @State private var copied: String?

    private enum Field: Hashable { case title, note }

    var body: some View {
        if let pin = store.pin(pinID) {
            VStack(alignment: .leading, spacing: 12) {
                header(pin)
                ProjectChip(store: store, pin: pin) {
                    focus = nil
                    model.pinProjectForm = true
                } allPins: {
                    model.present(.pins)
                }
                // the bottom of the glance: the compact sheet's resting height
                Color.clear.frame(height: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PanelContent.space)).minY } action: {
                        actions.peek($0)
                    }
                colourRow(pin)
                note(pin)
                facts(pin)
                actionRow(pin)
                    .padding(.top, 4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pin-card")
            .onAppear {
                if model.pinTitleFocus == pinID {
                    model.pinTitleFocus = nil
                    focus = .title
                }
                #if DEBUG
                // screenshots: `-debugPinNewProject YES` opens the editor
                if UserDefaults.standard.bool(forKey: "debugPinNewProject") { model.pinProjectForm = true }
                #endif
            }
            // the editing state carries this pin's id: a card going away
            // clears only its own, never the next card's (a long-press while
            // a card is open)
            .onChange(of: focus) { _, field in
                if field != nil {
                    model.pinEditing = pinID
                } else if model.pinEditing == pinID {
                    model.pinEditing = nil
                }
            }
            // "New project…": the one project editor; Escape closes just
            // that (`EscapeStep.closeProjectForm`)
            .sheet(isPresented: projectEditorShown) {
                ProjectEditor(model: model, store: store, mode: .new, created: { store.setProject(pin, $0) },
                              close: { model.pinProjectForm = false })
                    .projectEditorPresentation()
            }
            .onDisappear {
                store.flush()
                if model.pinEditing == pinID { model.pinEditing = nil }
            }
        }
    }

    private var projectEditorShown: Binding<Bool> {
        Binding(get: { model.pinProjectForm }, set: { if !$0 { model.pinProjectForm = false } })
    }

    // MARK: Header

    private func header(_ pin: SavedPin) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PinMark(hex: PinColour.hex(forName: pin.effectiveColourName))
                .padding(.top, 6)
            TextField("Title", text: Binding(get: { pin.title }, set: { store.setTitle(pin, $0) }),
                      // the name it goes by meanwhile (the note's first line, or
                      // "Pin · 24 Nov") — the same as the map label and the lists
                      prompt: Text(pin.displayTitle).foregroundStyle(DesignColor.secondaryInk), axis: .vertical)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .lineLimit(1 ... 3)
                .focused($focus, equals: .title)
                .submitLabel(.done)
                .onChange(of: pin.title) { _, title in
                    // a vertical field takes Return as a newline: it means Done
                    if title.contains("\n") {
                        store.setTitle(pin, title.replacingOccurrences(of: "\n", with: ""))
                        focus = nil
                    }
                }
                .frame(minHeight: 32)
                .accessibilityIdentifier("pin-title")
            Spacer(minLength: 0)
            CloseButton { model.clearSelection() }
        }
    }

    // MARK: Colour

    private func colourRow(_ pin: SavedPin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Colour")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                Spacer()
                Button {
                    store.setColour(pin, nil)
                } label: {
                    Label(pin.project == nil ? "Standard colour" : "Project colour",
                          systemImage: pin.colour == nil ? "checkmark" : "arrow.uturn.backward")
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.ink)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(pin.colour == nil ? .isSelected : [])
                .accessibilityIdentifier("pin-colour-project")
            }
            SwatchRow(selected: pin.colour) { store.setColour(pin, $0.rawValue) }
        }
    }

    // MARK: Note

    private func note(_ pin: SavedPin) -> some View {
        TextField("Note", text: Binding(get: { pin.note }, set: { store.setNote(pin, $0) }),
                  prompt: Text("Add a note").foregroundStyle(DesignColor.secondaryInk), axis: .vertical)
            .font(.body)
            .foregroundStyle(DesignColor.ink)
            .lineLimit(2 ... 12)
            .focused($focus, equals: .note)
            .padding(12)
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .accessibilityIdentifier("pin-note")
    }

    // MARK: Facts

    private func facts(_ pin: SavedPin) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Position")
                copyable(GridReadout.latLon.text(latitude: pin.lat, longitude: pin.lon), id: "pin-latlon")
            }
            GridRow {
                label("Grid ref")
                copyable(GridReadout.mga.text(latitude: pin.lat, longitude: pin.lon), id: "pin-mga")
            }
            GridRow {
                label("Placed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                        .font(.body)
                        .foregroundStyle(DesignColor.ink)
                    Text(Self.source(pin))
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .accessibilityIdentifier("pin-source")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "GPS ± 5 m · 312 m altitude" or "On the map".
    static func source(_ pin: SavedPin) -> String {
        switch pin.placement {
        case .gps:
            var parts = [pin.accuracy.map { "GPS ± \(Self.metres($0))" } ?? "GPS"]
            if let altitude = pin.altitude { parts.append("\(Self.metres(altitude)) altitude") }
            return parts.joined(separator: " · ")
        case .map:
            return "On the map"
        }
    }

    private static func metres(_ value: Double) -> String {
        "\(Int(value.rounded()).formatted(.number.grouping(.never)))\u{00A0}m"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(DesignColor.secondaryInk)
            .gridColumnAlignment(.leading)
    }

    /// A figure she may paste into LISTmap or a GPS: a tap copies it.
    private func copyable(_ text: String, id: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            copied = id
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copied == id { copied = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Text(copied == id ? "Copied" : text)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(DesignColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: copied == id ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityHint("Copies it")
        .accessibilityIdentifier(id)
    }

    // MARK: Actions

    private func actionRow(_ pin: SavedPin) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    focus = nil
                    model.startMovingPin()
                } label: {
                    Label("Tap the Map at the New Spot", systemImage: "hand.tap")
                }
                Button {
                    model.movePinToMyLocation()
                } label: {
                    Label("To My Location", systemImage: "location")
                }
            } label: {
                ActionLabel(title: "Move", symbol: "arrow.up.and.down.and.arrow.left.and.right")
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("pin-move")

            Button { openInMaps(pin) } label: {
                ActionLabel(title: "Open in Maps", symbol: "map")
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("pin-open-maps")

            Button(role: .destructive) {
                model.deletePin(pin.id)
            } label: {
                ActionLabel(title: "Delete", symbol: "trash", destructive: true)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("pin-delete")
        }
    }

    private func openInMaps(_ pin: SavedPin) {
        let item = MKMapItem(location: CLLocation(latitude: pin.lat, longitude: pin.lon), address: nil)
        item.name = pin.title.isEmpty ? "Pin" : pin.title
        item.openInMaps()
    }
}

/// An action under the card (and in a project's header): glyph over a
/// one-line caption, on a quiet fill — chrome, so concentric and ink
/// (Delete in the system's red).
struct ActionLabel: View {
    let title: String
    let symbol: String
    var destructive = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                // one glyph box, so every caption sits on the same line
                .frame(height: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(destructive ? AnyShapeStyle(Color(uiColor: .systemRed)) : AnyShapeStyle(DesignColor.ink))
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Color(uiColor: .tertiarySystemFill), in: ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true))
        .contentShape(.rect)
    }
}

/// The map's mark on a key box's white plate: the pin's colour in its
/// white halo and ink keyline, as the map draws it.
struct PinMark: View {
    let hex: String
    var body: some View {
        Circle()
            .fill(Color(uiColor: PinColour.uiColor(hex: hex)))
            .overlay { Circle().strokeBorder(.black.opacity(0.22), lineWidth: 0.5) }
            .padding(2)
            .background(Circle().fill(.white))
            .overlay { Circle().strokeBorder(Color(uiColor: PinPresenter.ink), lineWidth: 0.75) }
            .frame(width: 14, height: 14)
            .frame(width: 28, height: 18)
            .background(DesignColor.keyPlate)
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

/// The Layers sheet's Pins tile: three marks over the base map's picture,
/// drawn as the map draws them (disc, white halo, ink keyline) — the tile
/// previews what the switch shows.
struct PinTileMarks: View {
    private static let marks: [(x: CGFloat, y: CGFloat, colour: PinColour)] = [
        (0.24, 0.42, .orange), (0.50, 0.26, .violet), (0.64, 0.70, .teal),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(Self.marks.enumerated()), id: \.offset) { _, mark in
                Circle()
                    .fill(mark.colour.color)
                    .overlay { Circle().strokeBorder(.black.opacity(0.22), lineWidth: 0.5) }
                    .padding(2)
                    .background(Circle().fill(.white))
                    .overlay { Circle().strokeBorder(Color(uiColor: PinPresenter.ink), lineWidth: 0.75) }
                    .frame(width: 13, height: 13)
                    .position(x: proxy.size.width * mark.x, y: proxy.size.height * mark.y)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The eight palette colours as square keylined swatches; the selected
/// one framed in ink (the selection idiom in chrome). One row of eight
/// whenever eight 44 pt targets fit, else two rows of four — either way
/// the first swatch flush with the text above and the last with the right
/// edge, evenly spaced (`SwatchLayout`).
struct SwatchRow: View {
    /// The selected colour's NAME (nil: none of them).
    let selected: String?
    let pick: (PinColour) -> Void

    var body: some View {
        SwatchLayout(visual: Self.visual) {
            ForEach(PinColour.allCases) { colour in
                let isSelected = PinColour.named(selected) == colour
                Button { pick(colour) } label: {
                    // on a key plate, like every key box (glass would tint it)
                    KeyBox(hex: colour.hex, opacity: 1, width: 26, height: 26)
                        .padding(3)
                        .overlay { if isSelected { Rectangle().strokeBorder(DesignColor.ink, lineWidth: 2.5) } }
                        .frame(maxWidth: .infinity, minHeight: SwatchLayout.target)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(colour.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("pin-colour-\(colour.rawValue)")
            }
        }
    }

    /// The drawn swatch with its selection frame.
    static let visual: CGFloat = 32
}

/// Lays square swatches out on an even step: the first one's drawing at
/// the leading edge, the last one's at the trailing edge, each tap target
/// as wide as the step (≥ 44 pt), reaching half a gap into the margins.
/// All in one row when that step is ≥ 44 pt, else in rows of half as many.
nonisolated struct SwatchLayout: Layout {
    /// Width of each swatch as drawn.
    var visual: CGFloat
    static let target: CGFloat = 44

    static func columns(width: CGFloat, count: Int, visual: CGFloat) -> Int {
        guard count > 1 else { return count }
        return (width - visual) / CGFloat(count - 1) >= target ? count : (count + 1) / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(subviews.count) * Self.target
        let columns = max(1, Self.columns(width: width, count: subviews.count, visual: visual))
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * Self.target)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = max(1, Self.columns(width: bounds.width, count: subviews.count, visual: visual))
        let step = columns > 1 ? (bounds.width - visual) / CGFloat(columns - 1) : Self.target
        for (i, subview) in subviews.enumerated() {
            let x = bounds.minX + visual / 2 + CGFloat(i % columns) * step
            let y = bounds.minY + Self.target / 2 + CGFloat(i / columns) * Self.target
            subview.place(at: CGPoint(x: x, y: y), anchor: .center,
                          proposal: ProposedViewSize(width: max(Self.target, step), height: Self.target))
        }
    }
}

/// The pin's project as a chip: a menu of projects (swatch + name),
/// Unfiled, "New project…" (the project editor) and "All pins…" (the Pins
/// screen).
private struct ProjectChip: View {
    let store: PinStore
    let pin: SavedPin
    let newProject: () -> Void
    let allPins: () -> Void

    var body: some View {
        Menu {
            ForEach(store.activeProjects) { project in
                Button {
                    store.setProject(pin, project)
                } label: {
                    Label {
                        Text(PinText.projectName(project.name))
                    } icon: {
                        Image(uiImage: PinColour.swatchImage(hex: PinColour.hex(forName: project.colour)))
                    }
                }
            }
            Button {
                store.setProject(pin, nil)
            } label: {
                Label("Unfiled", systemImage: pin.project == nil ? "checkmark" : "tray")
            }
            Divider()
            Button(action: newProject) {
                Label("New Project…", systemImage: "plus")
            }
            Button(action: allPins) {
                Label("All Pins…", systemImage: "list.bullet")
            }
        } label: {
            HStack(spacing: 8) {
                if let project = pin.project {
                    Rectangle()
                        .fill(Color(uiColor: PinColour.uiColor(hex: PinColour.hex(forName: project.colour))))
                        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                        .frame(width: 12, height: 12)
                    Text(PinText.projectName(project.name))
                        .foregroundStyle(DesignColor.ink)
                } else {
                    Image(systemName: "tray")
                        .foregroundStyle(DesignColor.secondaryInk)
                    Text("Unfiled")
                        .foregroundStyle(DesignColor.ink)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Project")
        .accessibilityValue(pin.project?.name ?? "Unfiled")
        .accessibilityIdentifier("pin-project")
    }
}
