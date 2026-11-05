import IzzyKit
import SwiftUI

/// Step 3: the answer ladder (DESIGN.md "Plant ID", UX_VISUAL_REVIEW §3.16).
/// The real decision is visual — "is it this one?" — so her crop sits
/// beside each candidate's photo at the same size, swipeable through the
/// top 5; the ladder is drawn as ink bars per genus split into species,
/// with the 50 % line; the headline says what the ladder says. Ink only:
/// no traffic-light colours, no reward for an unsure answer.
struct PlantIDResults: View {
    let session: PlantIDSession
    let result: PlantIDResult
    let open: (PlantIDRoute) -> Void
    @State private var page = 0
    @Environment(\.horizontalSizeClass) private var widthClass

    private var library: PlantLibrary { .shared }
    /// Results beside the photo: a regular-width window wide enough for two columns.
    private func twoColumns(_ width: CGFloat) -> Bool { widthClass == .regular && width >= 700 }

    /// The width comes from a GeometryReader around the scroll view — it
    /// takes the space offered whatever the content does — not from
    /// `onGeometryChange` into @State: that fed the content's width back
    /// into the measured view, and under the accessibility audit's text-size
    /// pass the two never settled (the main thread pinned at 100 % for
    /// minutes, width setter firing every frame; profiled 2026-11-04).
    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
        .task { _ = await library.load() }
        .accessibilityIdentifier("plant-id-results")
    }

    private func content(width: CGFloat) -> some View {
        let twoColumns = twoColumns(width)
        return ScrollView {
            Group {
                if twoColumns {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 16) {
                            compare(width: (width - 32 - 40) * 0.5)
                            locationLine
                        }
                        .frame(width: (width - 32 - 40) * 0.5)
                        VStack(alignment: .leading, spacing: 24) {
                            headline
                            ladder
                            candidates
                            footer
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        compare(width: width - 32)
                        headline
                        locationLine
                        ladder
                        candidates
                        footer
                    }
                }
            }
            .padding(.horizontal, twoColumns ? 20 : 16)
            .padding(.vertical, 16)
        }
    }

    private func label(_ i: Int) -> PlantIDLabel? { session.label(i) }
    private func plant(_ i: Int) -> Plant? {
        guard let l = label(i), let catalog = library.catalog else { return nil }
        if let un = l.un { return catalog.plant(for: un.key) ?? un.ids.lazy.compactMap { catalog.plant(id: $0) }.first }
        return nil
    }

    /// The common name as a headline: the UN profile's, else the label table's.
    private func headlineCommon(_ i: Int) -> String? {
        plant(i)?.headlineCommon ?? label(i)?.common.flatMap(CommonName.headline)
    }

    /// The class's reference photo (the `refphotos` pack), if any.
    private func refPhoto(_ i: Int) -> PlantIDRefPhoto? { PlantIDRefPhotos.shared.photo(for: i, name: label(i)?.name) }

    private func threshold(_ i: Int) -> Double {
        (result.candidates + result.genusSpecies).first { $0.label == i }?.threshold ?? PlantIDResult.defaultThreshold
    }

    private func route(_ i: Int) -> PlantIDRoute {
        if let p = plant(i) { return .plant(id: p.id, key: p.species ?? p.name) }
        return .noProfile(label: i)
    }

    // MARK: Her crop beside the candidates

    private func compare(width w: CGFloat) -> some View {
        let s = max(100, (w - 8) / 2)
        let current = min(page, max(result.candidates.count - 1, 0))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let crop = session.cropImage {
                    Image(uiImage: crop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: s, height: s)
                        .clipped()
                        .accessibilityLabel("Your photo")
                        .accessibilityIdentifier("plant-id-crop")
                }
                TabView(selection: $page) {
                    ForEach(Array(result.candidates.enumerated()), id: \.offset) { i, c in
                        Button { open(route(c.label)) } label: {
                            CandidatePhoto(plant: plant(c.label), label: label(c.label), ref: refPhoto(c.label), side: s)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .tag(i)
                        .accessibilityLabel("Candidate \(i + 1) of \(result.candidates.count), \(label(c.label)?.name ?? "")")
                        .accessibilityHint("Opens its plant sheet")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: s, height: s)
                .accessibilityIdentifier("plant-id-compare")
            }
            HStack(spacing: 8) {
                Text("Your photo")
                    .frame(width: s, alignment: .leading)
                HStack(spacing: 6) {
                    Text("\(current + 1) of \(result.candidates.count)")
                        .monospacedDigit()
                    if let c = result.candidates.indices.contains(current) ? result.candidates[current] : nil,
                       let l = label(c.label) {
                        Text(BotanicalNames.species(l.name))
                            .fontDesign(.serif)
                            .lineLimit(1)
                    }
                }
                .frame(width: s, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(DesignColor.secondaryInk)
            if result.candidates.count > 1 {
                PageDots(count: result.candidates.count, current: current)
                    .frame(width: s)
                    .offset(x: s + 8)
            }
            // the reference photo's credit, under it
            if result.candidates.indices.contains(current), let ref = refPhoto(result.candidates[current].label) {
                RefPhotoCredit(photo: ref)
                    .frame(width: s, alignment: .leading)
                    .offset(x: s + 8)
            }
        }
    }

    // MARK: Headline

    @ViewBuilder private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.answer {
            case let .species(i, p):
                if let l = label(i) {
                    Text(BotanicalNames.species(l.name))
                        .font(.title2)
                        .fontDesign(.serif)
                        .foregroundStyle(DesignColor.ink)
                    // a headline: first letter up ("Christmas bells");
                    // the candidate rows below keep UN's lowercase
                    if let common = headlineCommon(i) {
                        Text(common)
                            .font(.title3)
                            .foregroundStyle(DesignColor.ink)
                    }
                    if plant(i) == nil {
                        NotInGuideLine(label: l)
                    }
                    ConfidenceBar(p: p, threshold: threshold(i), emphasis: true)
                        .padding(.top, 4)
                }
            case let .genus(g, p):
                Text("Genus \(Text(g).italic()) — species unsure")
                    .font(.title2)
                    .fontDesign(.serif)
                    .foregroundStyle(DesignColor.ink)
                Text("No single species is sure enough, but together the \(g) candidates make \(Self.percent(p)). The likeliest:")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                GenusTop(species: result.genusSpecies, label: label, plant: plant, ref: refPhoto) { open(route($0)) }
                    .padding(.top, 4)
            case .notSure:
                Text("Not sure — here are the closest matches")
                    .font(.title2)
                    .fontDesign(.serif)
                    .foregroundStyle(DesignColor.ink)
                Text("No species or genus is sure enough. Framing flowers or a whole branch more closely often helps.")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plant-id-answer")
    }

    private var locationLine: some View {
        let km = result.scope == .tasmania ? 5 : 10
        let text: String = switch session.place {
        case .none: "No location: ranked on the photo and how common each plant is across Australia."
        case .photo: result.usedLocation ? "Location from the photo: plants recorded within about \(km) km rank higher."
            : "The photo was taken outside Australia’s records: ranked on the photo alone."
        case .current: result.usedLocation ? "Using where you are now: plants recorded within about \(km) km rank higher."
            : "You’re outside Australia’s records: ranked on the photo alone."
        }
        return Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: result.usedLocation ? "mappin.and.ellipse" : "mappin.slash")
        }
        .font(.footnote)
        .foregroundStyle(DesignColor.secondaryInk)
        .accessibilityIdentifier("plant-id-location")
    }

    // MARK: The ladder, drawn

    private var ladder: some View {
        let genera = result.genera.filter { $0.p >= 0.01 }.prefix(3)
        return VStack(alignment: .leading, spacing: 14) {
            Text("How sure")
                .font(.headline)
                .foregroundStyle(DesignColor.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(genera.enumerated()), id: \.element.id) { i, g in
                GenusBar(share: g, labels: session.labels, threshold: result.ladder.genus, showsThreshold: i == 0)
            }
            Text(ladderCaption)
                .font(.caption)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plant-id-ladder")
    }

    // MARK: Candidates

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Closest matches")
                .font(.headline)
                .foregroundStyle(DesignColor.ink)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(result.candidates.enumerated()), id: \.element.id) { i, c in
                Button { open(route(c.label)) } label: {
                    CandidateRow(candidate: c, label: label(c.label), plant: plant(c.label), ref: refPhoto(c.label),
                                 showing: i == page, nearbyKm: result.nearbyKm)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("plant-id-candidate-\(i)")
                if i < result.candidates.count - 1 { Divider() }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Frame Again", systemImage: "crop") { session.reframe() }
                    .accessibilityIdentifier("plant-id-reframe")
                Button("New Photo", systemImage: "camera") { session.retake() }
            }
            .buttonStyle(.bordered)
            .tint(DesignColor.ink)
            Text("Suggestions from the photo, worked out on this \(DeviceNoun.current) — check the plant sheet before relying on a name.")
                .font(.caption)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button { open(.credits) } label: {
                Label("Model & training photos", systemImage: "info.circle")
                    .font(.footnote)
            }
            .foregroundStyle(DesignColor.ink)
            .accessibilityIdentifier("plant-id-credits")
        }
        .padding(.top, 8)
    }

    private var ladderCaption: String {
        let t = result.ladder
        let lo = t.species.min() ?? 0.5, hi = t.species.max() ?? 0.5
        let species = lo == hi ? Self.percent(lo) : "\(Int((lo * 100).rounded()))–\(Self.percent(hi))"
        return "A genus bar is its species’ shares added up; the line marks \(Self.percent(t.genus)), where IzzyMap names a genus. A species is named at \(species) — the more photos the model learnt it from, the higher its line."
    }

    static func percent(_ p: Double) -> String {
        let v = p * 100
        if v >= 99.5 { return ">\u{00A0}99\u{00A0}%" }
        if v < 1 { return "<\u{00A0}1\u{00A0}%" }
        return "\(Int(v.rounded()))\u{00A0}%"
    }
}

/// One candidate's UN photo, square, at her crop's size: the large file
/// (thumbnails are 150 px), the growth-form pictogram until it arrives —
/// and for a plant the guide doesn't have, its name set as a plate.
struct CandidatePhoto: View {
    let plant: Plant?
    var label: PlantIDLabel?
    /// The reference photo (refphotos pack): shown first when there is one.
    var ref: PlantIDRefPhoto?
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        if let ref {
            RefPhotoImage(photo: ref, side: side)
                .overlay { Rectangle().strokeBorder(DesignColor.keyline.opacity(0.5), lineWidth: 0.5) }
        } else {
            guidePhoto
        }
    }

    private var guidePhoto: some View {
        ZStack {
            if let plant {
                FormPlaceholder(shape: plant.silhouette)
            } else {
                NamePlate(label: label, side: side)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay { Rectangle().strokeBorder(DesignColor.keyline.opacity(0.5), lineWidth: 0.5) }
        .task(id: PhotoLoad(id: plant?.id ?? -1, online: Connectivity.shared.online)) {
            guard let photo = plant?.photos.first else { image = nil; return }
            let pixels = Int(side * scale)
            if let hit = PlantPhotoStore.shared.cached(photo, size: .large, pixels: pixels) { image = hit; return }
            let fetched = await PlantPhotoStore.shared.image(photo, size: .large, pixels: pixels)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = fetched }
        }
    }
}

/// p as an ink bar with the 50 % line, the percentage beside it.
struct ConfidenceBar: View {
    let p: Double
    /// Where the ladder names it (0.5 in Tasmania).
    var threshold = 0.5
    var emphasis = false

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(DesignColor.keyline.opacity(0.25))
                    Rectangle().fill(DesignColor.ink).frame(width: w * min(max(p, 0), 1))
                    ThresholdMark(height: geo.size.height)
                        .offset(x: w * threshold - 0.75)
                }
            }
            .frame(height: emphasis ? 8 : 5)
            Text(PlantIDResults.percent(p))
                .font(emphasis ? .headline : .subheadline)
                .monospacedDigit()
                .foregroundStyle(DesignColor.ink)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(PlantIDResults.percent(p).replacingOccurrences(of: "%", with: "percent"))
    }
}

/// One genus: its summed p as a bar split into its species (ink at falling
/// strengths), the 50 % hairline across, the species' epithets below.
struct GenusBar: View {
    let share: PlantIDResult.GenusShare
    let labels: [PlantIDLabel]
    var threshold = 0.5
    let showsThreshold: Bool

    private static let tones: [Double] = [1, 0.62, 0.42, 0.3, 0.22, 0.16]

    private func epithet(_ i: Int) -> String {
        guard labels.indices.contains(i) else { return "" }
        let words = labels[i].name.split(separator: " ")
        return words.count > 1 ? words.dropFirst().joined(separator: " ") : labels[i].name
    }

    var body: some View {
        let shown = share.species.filter { $0.p >= 0.005 }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(share.name)
                    .italic()
                    .fontDesign(.serif)
                    .font(.body)
                    .foregroundStyle(DesignColor.ink)
                Spacer()
                Text(PlantIDResults.percent(share.p))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.ink)
            }
            if showsThreshold {
                // the threshold's label, over the hairline
                GeometryReader { geo in
                    Text(PlantIDResults.percent(threshold))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize()
                        .position(x: geo.size.width * threshold, y: 7)
                }
                .frame(height: 14)
                .accessibilityHidden(true)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(DesignColor.keyline.opacity(0.22))
                    HStack(spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                            Rectangle()
                                .fill(DesignColor.ink.opacity(Self.tones[min(i, Self.tones.count - 1)]))
                                .frame(width: max(1, w * c.p - 1))
                        }
                    }
                    ThresholdMark(height: geo.size.height)
                        .offset(x: w * threshold - 0.75)
                }
            }
            .frame(height: 12)
            .padding(.bottom, 3)
            Text(shown.map { "\(epithet($0.label)) \(Int(($0.p * 100).rounded()))" }.joined(separator: " · "))
                .font(.caption)
                .fontDesign(.serif)
                .italic()
                .foregroundStyle(DesignColor.secondaryInk)
                .lineLimit(2)
        }
        .accessibilityElement()
        .accessibilityLabel("\(share.name), \(Int((share.p * 100).rounded())) percent: "
            + shown.map { "\(epithet($0.label)) \(Int(($0.p * 100).rounded()))" }.joined(separator: ", "))
    }
}

/// A candidate in the list: thumbnail, names, its bar, "recorded within 5 km".
struct CandidateRow: View {
    let candidate: PlantIDResult.Candidate
    let label: PlantIDLabel?
    let plant: Plant?
    var ref: PlantIDRefPhoto?
    let showing: Bool
    var nearbyKm = 10.0
    @ScaledMetric(relativeTo: .body) private var thumb = 52

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let ref {
                    RefPhotoImage(photo: ref, side: thumb)
                } else if let plant {
                    PlantThumb(plant: plant, side: thumb)
                } else {
                    NamePlate(label: label, side: thumb)
                }
            }
            .overlay(alignment: .leading) {
                // the candidate the compare row shows
                if showing { Rectangle().fill(DesignColor.ink).frame(width: 3).offset(x: -8) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(BotanicalNames.species(label?.name ?? "?"))
                    .font(.body)
                    .fontDesign(.serif)
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let common = plant?.common ?? label?.common {
                    Text(common)
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.secondaryInk)
                }
                if plant == nil, let label {
                    NotInGuideLine(label: label, compact: true)
                }
                ConfidenceBar(p: candidate.p, threshold: candidate.threshold)
                    .padding(.top, 2)
                if candidate.nearbyRecords > 0 {
                    Label("Recorded within \(Int(nearbyKm)) km", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .accessibilityIdentifier("plant-id-nearby")
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DesignColor.secondaryInk)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The 50 % line on a bar: ink ticks above and below, a gap in the
/// sheet's own colour across the bar — visible over the ink fill and the
/// light track alike.
struct ThresholdMark: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DesignColor.ink).frame(width: 1.5, height: 4)
            Rectangle().fill(Color(uiColor: .systemBackground)).frame(width: 1.5, height: height)
            Rectangle().fill(DesignColor.ink).frame(width: 1.5, height: 4)
        }
        .accessibilityHidden(true)
    }
}

/// A plant the guide has no photo of: its name set as a plate — the genus
/// initial on a small tile, the full name (and family) on a large one.
/// Typographic and quiet, never a broken image.
struct NamePlate: View {
    let label: PlantIDLabel?
    let side: CGFloat

    private var initial: String { String((label?.genusName ?? "?").prefix(1)) }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .tertiarySystemFill))
            if side >= 120, let label {
                VStack(spacing: 8) {
                    Image(systemName: "leaf")
                        .font(.title3)
                        .foregroundStyle(DesignColor.secondaryInk)
                    Text(BotanicalNames.species(label.name))
                        .font(.title3)
                        .fontDesign(.serif)
                        .foregroundStyle(DesignColor.ink)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                    if let family = label.family {
                        Text(family)
                            .font(.caption)
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                    Text("No photo in the guide")
                        .font(.caption2)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .padding(.top, 2)
                }
                .padding(12)
            } else {
                Text(initial)
                    .font(.system(size: side * 0.5, design: .serif))
                    .italic()
                    .foregroundStyle(DesignColor.secondaryInk)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// For a plant with no Understorey Network profile (most of the 22,000
/// Australian natives): its family and that fact, said once, quietly —
/// "Myrtaceae · not in the guide" in a row; family, then "Not in the
/// Understorey Network guide" under a headline.
struct NotInGuideLine: View {
    let label: PlantIDLabel
    var compact = false

    var body: some View {
        Group {
            if compact {
                Text([label.family, "not in the guide"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let family = label.family {
                        Text(family).font(.subheadline)
                    }
                    Text("Not in the Understorey Network guide").font(.footnote)
                }
            }
        }
        .foregroundStyle(DesignColor.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("plant-id-not-in-guide")
    }
}

/// A genus answer's likeliest species: three tiles — the reference photo
/// (else the guide's photo or a name plate), the name, its share. A tap
/// opens the species.
struct GenusTop: View {
    let species: [PlantIDResult.Candidate]
    let label: (Int) -> PlantIDLabel?
    let plant: (Int) -> Plant?
    let ref: (Int) -> PlantIDRefPhoto?
    let open: (Int) -> Void
    @ScaledMetric(relativeTo: .body) private var side = 92

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(species) { c in
                Button { open(c.label) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        CandidatePhoto(plant: plant(c.label), label: label(c.label), ref: ref(c.label), side: side)
                        Text(BotanicalNames.species(label(c.label)?.name ?? "?"))
                            .font(.footnote)
                            .fontDesign(.serif)
                            .foregroundStyle(DesignColor.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PlantIDResults.percent(c.p))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(DesignColor.secondaryInk)
                    }
                    .frame(width: side, alignment: .leading)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .accessibilityIdentifier("plant-id-genus-top")
    }
}
