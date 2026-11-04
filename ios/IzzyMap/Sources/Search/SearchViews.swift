import IzzyKit
import SwiftUI

// The search interface: the field in the panel header, the result list that
// replaces the card while searching, and the picked place's chip.
// docs/DESIGN.md "Search results"; docs/UX_VISUAL_REVIEW.md §3.9.

/// The header's search field. A tap raises the keyboard at once (the
/// field takes focus in the tap itself); focus starts search mode. At rest
/// the field is empty; the last query comes back when search reopens.
struct SearchField: View {
    @Bindable var search: SearchModel
    var onFocus: () -> Void = {}
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldHeight = 48

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DesignColor.secondaryInk)
                .accessibilityHidden(true)
            // The prompt in secondaryInk (≥ 7.7:1 on the light field), not
            // the system placeholder grey (≈ 1.8:1): "Search places" is the
            // panel's resting label and must read over any map.
            TextField(text: text, prompt: Text("Search places").foregroundStyle(DesignColor.secondaryInk)) {
                Text("Search places")
            }
            .focused($focused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { search.submit() }
            // hardware keyboard: ↑/↓ move the highlight (Return is onSubmit)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard search.isActive else { return .ignored }
                search.moveHighlight(press.key == .upArrow ? -1 : 1)
                return .handled
            }
            // Escape's first step if the focused field gets the key itself
            // rather than the Map menu's command (same step either way:
            // leave the field; results, then the pin, follow through
            // AppModel.escape). XCUITest's Escape never reaches the app
            // in the simulator: check on a real keyboard.
            .onKeyPress(.escape) {
                // only while typing: otherwise the Map menu's Escape walks on
                guard focused else { return .ignored }
                search.fieldFocused = false
                return .handled
            }
            .accessibilityIdentifier("search-field")

            if search.isActive {
                if search.status == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading place names")
                } else if !search.query.isEmpty {
                    Button {
                        search.clearQuery()
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignColor.secondaryInk)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear text")
                    .accessibilityIdentifier("search-clear-text")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: fieldHeight)
        .background(.fill.tertiary, in: .capsule)
        .contentShape(.capsule)
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, now in
            search.fieldFocused = now
            if now {
                search.begin()
                onFocus()
            }
        }
        // Escape's first step and a pick drop focus through the model
        .onChange(of: search.fieldFocused) { _, now in
            if !now, focused { focused = false }
        }
        .onChange(of: search.focusRequest) { _, _ in focused = true }
    }

    /// The field shows the query only while searching.
    private var text: Binding<String> {
        Binding(get: { search.isActive ? search.query : "" },
                set: { new in
                    if !search.isActive {
                        // the field echoing its empty resting text as it
                        // takes focus must not wipe the query to restore
                        guard !new.isEmpty else { return }
                        search.begin()
                    }
                    search.query = new
                })
    }
}

/// The picked place, under the field at rest: pin glyph, name and place
/// re-fly; × clears the pin. Replaces the web app's pill on the map. (Its
/// own row, not a token inside the field: there the field's tap target
/// shrank to a sliver beside a long name.)
struct SearchPlaceChip: View {
    let result: SearchResult
    var onTap: () -> Void
    var onClear: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var height = 40

    /// "Clarence" from "Beach · Clarence".
    private var place: String? {
        let parts = result.meta.components(separatedBy: " · ")
        return parts.count > 1 ? parts[1] : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(result.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let place {
                        Text(place)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(DesignColor.ink)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(minHeight: height)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel([result.name, place].compactMap(\.self).joined(separator: ", "))
            .accessibilityHint("Shows the place on the map again")
            .accessibilityIdentifier("search-chip")

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(DesignColor.secondaryInk)
                    .frame(width: 40, height: height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear \(result.name)")
            .accessibilityIdentifier("search-chip-clear")
        }
        // a solid token in the translucent field: legible over any map
        // (a second translucent fill turned muddy over aerial photos)
        .background(Color(uiColor: .systemBackground).opacity(0.92), in: .capsule)
        .overlay { Capsule().strokeBorder(DesignColor.keyline.opacity(0.4), lineWidth: 0.5) }
        .hoverEffect(.highlight)
    }
}

/// While searching, in place of the card: results as you type, recent
/// picks for an empty field, and the one-line states.
struct SearchResultsView: View {
    @Bindable var search: SearchModel
    @Environment(\.panelActions) private var panel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // ↑/↓ keep the highlighted row in view, two rows of context above
        .onChange(of: search.highlighted) { _, h in
            guard let h else { return }
            let rows = search.visibleRows
            guard rows.indices.contains(h) else { return }
            panel.scrollTo(rows[max(0, h - 2)].id)
        }
    }

    @ViewBuilder private var content: some View {
        if case let .failed(message) = search.status {
            StateLine(symbol: StateSymbol.failed, text: message)
                .accessibilityIdentifier("search-failure")
        } else if search.query.isEmpty {
            if search.recents.isEmpty {
                StateLine(symbol: "mappin.and.ellipse", text: emptyHint)
            } else {
                Text("Recent")
                    .font(.headline)
                    .foregroundStyle(DesignColor.ink)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                rows(search.recentRows)
            }
        } else if search.status == .loading || search.status == .idle {
            // quiet: the field's spinner says it; results follow on their own
            EmptyView()
        } else if !search.queryIsSearchable {
            EmptyView()
        } else if search.results.isEmpty {
            StateLine(symbol: "magnifyingglass",
                      text: "No places match “\(search.query.trimmingCharacters(in: .whitespaces))”. Try a street, suburb or peak name.")
                .accessibilityIdentifier("search-no-results")
        } else {
            rows(search.results)
            Text(SearchIndex.credit)
                .font(.caption2)
                .foregroundStyle(DesignColor.secondaryInk)
                .padding(.top, 12)
        }
    }

    private var emptyHint: String {
        if let counts = search.counts {
            "\(counts.places.formatted()) places and \(counts.streets.formatted()) streets, all on this device"
        } else {
            "Places, streets and addresses, all on this device"
        }
    }

    private func rows(_ list: [SearchResult]) -> some View {
        let twins = SearchResultRow.twins(list)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, result in
                SearchResultRow(result: result, highlighted: search.highlighted == i,
                                showsKind: twins.contains(result.id)) {
                    search.pick(result)
                }
                .id(result.id)
            }
        }
    }
}

/// One result: kind glyph · name over its place ("North Hobart, Hobart") ·
/// distance from the map centre. The glyph says the kind, so the line under
/// the name is the place alone and wraps rather than truncating — two
/// Elizabeth Streets differ by their suburbs. (A tiny Tasmania locator per
/// row was tried and dropped: a grey blob at 22 pt, every nearby result's
/// dot in the same corner, and its width truncated the localities.)
struct SearchResultRow: View {
    let result: SearchResult
    var highlighted: Bool
    /// Spell the kind out ("Locality · Southern Midlands"): another row
    /// has the same name and place, and the glyphs may agree.
    var showsKind = false
    var onPick: () -> Void
    @ScaledMetric(relativeTo: .body) private var glyphBox = 34

    /// "North Hobart, Hobart" from "Road · North Hobart, Hobart"; the kind
    /// itself when there is no place.
    static func place(_ r: SearchResult) -> String {
        let parts = r.meta.components(separatedBy: " · ").filter { !$0.isEmpty }
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : parts.first ?? ""
    }

    /// Ids of rows sharing name and place with another row.
    static func twins(_ list: [SearchResult]) -> Set<String> {
        var seen: [String: [String]] = [:]
        for r in list { seen["\(r.name)\u{1F}\(place(r))", default: []].append(r.id) }
        return Set(seen.values.filter { $0.count > 1 }.joined())
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(systemName: result.kind.systemImage)
                    .font(.body)
                    .foregroundStyle(DesignColor.ink)
                    .frame(width: glyphBox, height: glyphBox)
                    .background(.fill.tertiary, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.body)
                        .foregroundStyle(DesignColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    let place = showsKind ? result.meta : Self.place(result)
                    if !place.isEmpty {
                        Text(place)
                            .font(.subheadline)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let distance = result.distanceText {
                    Text(distance)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize()
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background {
                if highlighted {
                    ConcentricRectangle().fill(.fill.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .padding(.horizontal, -8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(result))
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("search-result")
    }

    /// "Road, Salamanca Place, Battery Point, Hobart, 300 m away": kind,
    /// name, place, distance.
    static func spoken(_ r: SearchResult) -> String {
        var parts = r.meta.components(separatedBy: " · ")
        let kind = parts.isEmpty ? r.type : parts.removeFirst()
        var out = [kind.isEmpty ? r.type : kind, r.name]
        out += parts.filter { !$0.isEmpty }
        if let d = r.distanceText { out.append("\(d) away") }
        return out.joined(separator: ", ")
    }
}
