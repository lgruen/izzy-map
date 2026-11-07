import IzzyKit
import SwiftUI

/// The field-guide page for one plant, pushed over the card: a photo
/// plate (swipe; credit under every photo), names, the bloom chart, its
/// height drawn against a person, where it is recorded statewide, then
/// the descriptive facts, habitats and the Understorey Network link.
struct PlantSheet: View {
    let model: AppModel
    let plantID: Int
    let key: String
    let context: PlantContext
    let source: String
    /// × closes this instead of the card (the sheet opened from Identify).
    var onClose: (() -> Void)?
    @Environment(\.cardNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var page = 0
    @State private var distribution: [RecordCell]?
    @State private var squares: [GridSquare]?

    private var library: PlantLibrary { .shared }
    private var plant: Plant? { library.catalog?.plant(id: plantID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let plant {
                    content(plant)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            #if DEBUG
            // screenshots of the scroll edge: `-debugScrollSheet YES`
            // (the elevation) or `habitats` (the habitat key)
            .task {
                let to = UserDefaults.standard.string(forKey: "debugScrollSheet")
                guard to == "habitats" || UserDefaults.standard.bool(forKey: "debugScrollSheet") else { return }
                try? await Task.sleep(for: .seconds(2))
                let anchor = to == "habitats" ? "sheet-habitats" : "sheet-height"
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(anchor, anchor: to == "habitats" ? .center : .top) }
            }
            #endif
        }
        .scrollBounceBehavior(.basedOnSize)
        // content passes under the system bar (back, close) behind its soft
        // edge, never bare under hand-placed discs
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .containerBackground(.clear, for: .navigation)
        .toolbar { SheetCloseItem(model: model, action: onClose) }
        .modifier(ZoomDestination(id: source, namespace: reduceMotion ? nil : namespace))
        .accessibilityIdentifier("plant-sheet")
        .task(id: plantID) {
            guard let catalog = await library.load() else { return }
            let key = self.key
            let (cells, grid) = await Task.detached(priority: .userInitiated) {
                let cells = catalog.distribution(of: key)
                return (cells, GridSquare.squares(cells))
            }.value
            distribution = cells
            squares = grid
        }
    }

    @ViewBuilder private func content(_ plant: Plant) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if !plant.photos.isEmpty, width > 0 {
                photos(plant)
            } else if width > 0, let ref = PlantIDRefPhotos.shared.photo(forPlant: plant) {
                refPhoto(ref, plant: plant)
            }
            titleBlock(plant)
            if !plant.flowering.isEmpty {
                BloomChart(months: plant.flowering)
            }
            if let height = plant.heightRange {
                ElevationDrawing(shape: plant.silhouette, height: height)
                    .frame(maxWidth: 560, alignment: .leading)
                    .id("sheet-height")
            }
            distributionMap
            factsGrid(plant)
            prose(plant)
            if !plant.habitats.isEmpty {
                habitats(plant)
                    .id("sheet-habitats")
            }
            if let url = plant.profileURL {
                Link(destination: url) {
                    Label("Understorey Network page", systemImage: "arrow.up.right.square")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .accessibilityIdentifier("un-link")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(plant.photos.isEmpty ? PlantCredits.profiles : PlantCredits.plants)
                Text(PlantCredits.records)
            }
            .font(.caption)
            .foregroundStyle(DesignColor.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Photos

    private func photos(_ plant: Plant) -> some View {
        let plateWidth = width - 32
        return VStack(alignment: .leading, spacing: 6) {
            TabView(selection: $page) {
                ForEach(Array(plant.photos.enumerated()), id: \.offset) { i, photo in
                    PlantPhotoPlate(photo: photo, shape: plant.silhouette, width: plateWidth)
                        .tag(i)
                        .accessibilityLabel("Photo \(i + 1) of \(plant.photos.count), \(plant.name). \(photo.caption)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: plateWidth, height: plateWidth * 3 / 4)
            if plant.photos.count > 1 {
                PageDots(count: plant.photos.count, current: page)
                    .frame(maxWidth: .infinity)
            }
            Text(plant.photos[min(page, plant.photos.count - 1)].caption)
                .font(.caption2)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("photo-credit")
        }
    }

    /// No photo in the guide: the plant-ID reference photo stands in, with
    /// its own credit (author, licence, source) and what it shows.
    private func refPhoto(_ ref: PlantIDRefPhoto, plant: Plant) -> some View {
        let plateWidth = width - 32
        return VStack(alignment: .leading, spacing: 6) {
            RefPhotoPlate(photo: ref, shape: plant.silhouette, width: plateWidth)
                .accessibilityLabel("Reference photo, \(plant.name). \(ref.attribution)")
            // what it is: the plant-ID reference photo (of the species, for a
            // subspecies profile), not one of the guide's own
            Text((["Reference photo" + (ref.matchedSpecies.map { " of \($0)" } ?? ""), ref.caption, ref.attribution] as [String?])
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("photo-credit")
        }
    }

    // MARK: Names

    private func titleBlock(_ plant: Plant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(BotanicalNames.species(plant.name))
                    .font(.title2)
                    .fontDesign(.serif)
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("plant-name")
                if let status = plant.conservationStatus {
                    // an upright mark, never a coloured badge
                    Text(status.rawValue)
                        .font(.footnote.weight(.semibold).uppercaseSmallCaps())
                        .tracking(0.5)
                        .foregroundStyle(DesignColor.codeInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                        .accessibilityLabel("Threatened: \(status.rawValue)")
                        .accessibilityIdentifier("plant-status")
                }
            }
            if let common = plant.headlineCommon {
                Text(common)
                    .font(.title3)
                    .foregroundStyle(DesignColor.ink)
                    .accessibilityIdentifier("plant-common")
            }
            if let family = plant.family {
                Text(family)
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
            }
        }
    }

    // MARK: Where recorded

    @ViewBuilder private var distributionMap: some View {
        if let outline = library.outline, distribution?.isEmpty != true {
            VStack(alignment: .leading, spacing: 6) {
                SheetHeading("Where recorded")
                TasmaniaMiniMap(outline: outline, marks: .squares(squares ?? [], size: GridSquare.size),
                                ring: context.latitude.flatMap { lat in context.longitude.map { (lat, $0) } })
                    .frame(maxWidth: 360)
                InkKey(items: [(TasmaniaMiniMap.squareInk[1], "1 site"), (TasmaniaMiniMap.squareInk[2], "2–4"),
                               (TasmaniaMiniMap.squareInk[3], "5 or more per 5 km square")])
                Text(distributionCaption)
                    .font(.footnote)
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MiniMapCredits.records)
                    .font(.caption2)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map of where it is recorded. \(distributionCaption)")
            .accessibilityIdentifier("distribution-map")
        }
    }

    private var distributionCaption: String {
        guard let cells = distribution, let squares else { return " " }
        let sites = cells.reduce(0) { $0 + $1.sites }
        return "Recorded at \(sites.formatted()) site\(sites == 1 ? "" : "s") in \(squares.count.formatted()) five-kilometre square\(squares.count == 1 ? "" : "s"). Blank doesn’t mean absent — only that nobody recorded it there."
    }

    // MARK: Facts

    private func factsGrid(_ plant: Plant) -> some View {
        let catalog = library.catalog
        let near = context.latitude.flatMap { lat in
            context.longitude.flatMap { lon in catalog?.nearby(latitude: lat, longitude: lon).sites[key] }
        }
        let inCommunity = context.code.flatMap { code in catalog?.communitySites(code)[key] }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            if !plant.growthForms.isEmpty {
                GridRow {
                    label("Growth form")
                    HStack(spacing: 8) {
                        ForEach(plant.growthForms, id: \.self) { form in
                            HStack(spacing: 4) {
                                GrowthFormGlyph(shape: form == plant.primaryForm ? plant.silhouette
                                    : PlantSilhouette(form: form, name: plant.name))
                                    .frame(width: 22, height: 22)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                                Text(form.title)
                            }
                        }
                    }
                    .font(.body)
                    .foregroundStyle(DesignColor.ink)
                }
                .accessibilityElement(children: .combine)
            }
            if let code = context.code, let inCommunity {
                row("Recorded in \(code)", "\(inCommunity) site\(inCommunity == 1 ? "" : "s")")
            }
            if let near {
                row("Recorded near here", "\(near) site\(near == 1 ? "" : "s")")
                    .accessibilityIdentifier("recorded-near")
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.subheadline)
            .foregroundStyle(DesignColor.secondaryInk)
            .gridColumnAlignment(.leading)
    }

    private func row(_ l: String, _ v: String) -> some View {
        GridRow {
            label(l)
            Text(v)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(DesignColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func prose(_ plant: Plant) -> some View {
        let facts = [("Form", plant.form), ("Flowers", plant.flowers), ("Fruit", plant.fruit),
                     ("Habitat", plant.habitat), ("Notes", plant.notes)]
            .compactMap { l, v in v.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (l, $0) } }
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(facts, id: \.0) { l, v in
                    VStack(alignment: .leading, spacing: 2) {
                        SheetHeading(l)
                        Text(v)
                            .font(.body)
                            .lineSpacing(3)
                            .foregroundStyle(DesignColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("plant-facts")
        }
    }

    /// Habitats as a printed key (decided by the user, 2026-11-04): each
    /// UN class beside a key box in the map colour of its TASVEG group
    /// (`HabitatKey`), Riparian hatched — no group of its own.
    private func habitats(_ plant: Plant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetHeading("Habitats")
            FlowLayout(spacing: 14, lineSpacing: 8) {
                ForEach(plant.habitats, id: \.self) { h in
                    let key = HabitatKey.entry(h)
                    HStack(spacing: 6) {
                        HabitatBox(entry: key)
                        Text(h)
                            .font(.footnote)
                            .foregroundStyle(DesignColor.ink)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(key.spoken)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plant-habitats")
    }
}

/// `navigationTransition(.zoom)` from the row it left, when allowed
/// (Reduce Motion: the system's default transition).
struct ZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// Wrapping row layout for short tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Between lines (default: `spacing`).
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + (lineSpacing ?? spacing); line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + (lineSpacing ?? spacing); line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A broad-sense group's species, ordered by local evidence: recorded in
/// this community, then near the tapped point, then the rest A–Z — the
/// headings carry the counts, so the order explains itself.
struct GroupList: View {
    let model: AppModel
    let key: String
    let context: PlantContext
    @State private var sections: PlantCatalog.GroupSections?

    private var group: PlantCatalog.Group? { PlantLibrary.shared.catalog?.group(key) }

    var body: some View {
        ScrollView {
            if let group {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let common = group.headlineCommon {
                            Text(common)
                                .font(.title2)
                                .fontDesign(.serif)
                                .foregroundStyle(DesignColor.ink)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Text(BotanicalNames.species(group.key) + AttributedString(" (broad sense) · \(group.size) species"))
                            .font(.subheadline)
                            .fontDesign(.serif)
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                    // the members' faces, as a planting board
                    HStack(spacing: 6) {
                        ForEach(group.members, id: \.key) { m in PlantThumb(plant: m.plant, side: 44) }
                    }
                    if let s = sections {
                        let code = context.code ?? ""
                        if !s.here.isEmpty {
                            PlantListSection(model: model, id: "g-here", title: "Recorded in \(code)",
                                             subtitle: Text("Sites (~100 m) with a record inside this community."),
                                             entries: s.here, context: context)
                        }
                        if !s.near.isEmpty {
                            PlantListSection(model: model, id: "g-near", title: "Recorded near here",
                                             subtitle: Text("Sites with a record within roughly 1–1.5 km."),
                                             entries: s.near, context: context)
                        }
                        if !s.rest.isEmpty {
                            PlantListSection(model: model, id: "g-rest",
                                             title: s.here.isEmpty && s.near.isEmpty ? "Species in the group" : "Other species in the group",
                                             subtitle: Text("No records in this community or nearby."),
                                             entries: s.rest, context: context, metric: .none)
                        }
                    }
                    Text("The description names the group as a whole; the Understorey Network profiles its species separately.")
                        .font(.caption)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .containerBackground(.clear, for: .navigation)
        .toolbar { SheetCloseItem(model: model) }
        .accessibilityIdentifier("group-list")
        .task(id: key) {
            guard let catalog = await PlantLibrary.shared.load(), let group = catalog.group(key) else { return }
            let near = context.latitude.flatMap { lat in context.longitude.map { catalog.nearby(latitude: lat, longitude: $0) } }
            sections = catalog.groupSections(group, code: context.code, nearby: near)
        }
    }
}

/// The pushed views' close button: the system's close role in the
/// navigation bar (glass, placement and the scroll edge are the system's).
struct SheetCloseItem: ToolbarContent {
    let model: AppModel
    /// Instead of closing the card.
    var action: (() -> Void)?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(role: .close) { if let action { action() } else { model.clearSelection() } }
                .accessibilityIdentifier("sheet-close")
        }
    }
}

/// Page dots under the photo plate (the pager is otherwise invisible).
struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
                Circle()
                    .fill(i == current ? DesignColor.ink : DesignColor.keyline.opacity(0.6))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
