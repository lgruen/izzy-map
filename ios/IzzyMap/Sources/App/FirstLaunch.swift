import IzzyKit
import SwiftUI

// MARK: - Maps arriving

/// The core packs that come with the install but may finish after the first
/// launch (topo, relief, plant ID; `Pack.Policy.prefetch` — and the
/// essential vector pack if a dropout left it out). While any is missing,
/// one small chip on the map says how far they are and opens Storage
/// (docs/DESIGN.md §3 "States": first launch). Pure, so the unit tests
/// drive it.
nonisolated struct CoreArrival: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        /// Downloading: the share of the bytes of the packs that ARE
        /// downloading and report progress (nil until one does). Packs on
        /// the device, waiting, failed or unpublished never fold in — on
        /// 2026-11-04 "Plant ID arriving · 83 %" was the maps already here
        /// over maps + a model that wasn't downloading at all.
        case arriving(Double?)
        /// Asked for, not started: nothing reports progress yet.
        case queued
        /// Nothing moving: no connection (`offline`), or iOS paused it.
        case waiting(offline: Bool)
        /// A core download failed; a tap retries.
        case failed
        /// A core pack is here but unusable (`PackStore.unusable`): no
        /// retry helps — a tap opens Storage, which names the fix.
        case unusable
    }

    let phase: Phase
    /// The core packs not on the device yet (the ones the App Store offers).
    let missing: [Pack]

    /// The packs it watches: everything that isn't one-tap on demand —
    /// except the reference photos: Identify works without them (a
    /// placeholder until they arrive), so they never hold up "Plant ID".
    static let core = Pack.allCases.filter { $0.policy != .onDemand && $0 != .refphotos }

    /// nil when there is nothing to say: every core pack is here (or not
    /// published yet — that can't arrive), the packs aren't known yet, or
    /// nothing can fetch them (a developer folder).
    static func of(states: [Pack: PackState], sizes: [Pack: Int] = PackSizes.nominal,
                   resolved: Bool, canFetch: Bool, online: Bool, unusable: Set<Pack> = []) -> CoreArrival? {
        guard resolved, canFetch else { return nil }
        let missing = core.filter {
            let state = states[$0] ?? .notInstalled
            return !state.isInstalled && state != .unpublished
        }
        guard !missing.isEmpty else { return nil }
        var done = 0.0, total = 0.0, moving = false, measured = false, failed = false
        let broken = missing.contains { unusable.contains($0) }
        for pack in missing {
            let bytes = Double(max(1, sizes[pack] ?? 1))
            switch states[pack] ?? .notInstalled {
            case let .downloading(f?):
                moving = true
                measured = true
                total += bytes
                done += bytes * min(max(f, 0), 1)
            case .downloading(nil): moving = true
            case .failed: failed = true
            default: break
            }
        }
        let phase: Phase
        if broken, !moving {
            phase = .unusable
        } else if moving {
            phase = .arriving(measured && total > 0 ? done / total : nil)
        } else if failed {
            phase = .failed
        } else if !online {
            phase = .waiting(offline: true)
        } else if missing.contains(where: { states[$0] == .paused }) {
            phase = .waiting(offline: false)
        } else {
            // asked for, not started yet (the system queues prefetches)
            phase = .queued
        }
        return CoreArrival(phase: phase, missing: missing)
    }

    /// What is missing, in one word: "Maps" while any map pack is, else
    /// the plant ID model on its own.
    var noun: String { missing.allSatisfy { $0 == .plantid } ? "Plant ID" : "Maps" }

    /// The chip's words: short, figures that don't jump about.
    var text: String {
        switch phase {
        case let .arriving(f?) where f >= 0.01: "\(noun) arriving · \(StorageText.percent(f))"
        case .arriving: "\(noun) arriving"
        case .queued: "\(noun) not here yet"
        case .waiting(offline: true): "\(noun) arrive\(noun == "Maps" ? "" : "s") when online"
        case .waiting(offline: false): "\(noun) arriving · paused by iOS"
        case .failed: "\(noun) didn’t finish · Retry"
        case .unusable: "\(noun) can’t be opened · Fix"
        }
    }

    /// VoiceOver: what is coming and what the tap does.
    var spoken: String {
        let list = ListFormatter.localizedString(byJoining: missing.map(\.spokenTitle))
        let what = list.prefix(1).uppercased() + list.dropFirst()
        switch phase {
        case let .arriving(f): return "\(what) arriving" + (f.map { ", \(StorageText.percentValue($0)) percent" } ?? "")
        case .queued: return "\(what) not here yet"
        case .waiting(offline: true): return "\(what) arrive when there’s a connection"
        case .waiting(offline: false): return "\(what) paused by iOS; it resumes on its own"
        case .failed: return "\(what) didn’t finish downloading"
        case .unusable: return "\(what) can’t be opened; Storage says how to fix it"
        }
    }
}

extension Pack {
    /// How a core pack is named in a sentence.
    nonisolated var spokenTitle: String {
        switch self {
        case .vector: "the vegetation map"
        case .topo: "the topographic map"
        case .relief: "relief shading"
        case .plantid: "the plant identification model"
        case .refphotos: "the plant reference photos"
        default: rawValue
        }
    }
}

/// "Maps arriving · 62 %": one glass capsule on the map, a ring in ink that
/// fills as the core packs come in. Tap → Storage (after a failure: retry
/// first, then Storage, where each row shows its own state).
struct MapsArrivingChip: View {
    let arrival: CoreArrival
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                glyph
                    .frame(width: 18, height: 18)
                Text(arrival.text)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .hoverEffect(.highlight)
        .mapChrome()
        .accessibilityLabel(arrival.spoken)
        .accessibilityHint(arrival.phase == .failed || arrival.phase == .queued ? "Asks for it again and opens Storage" : "Opens Storage")
        .accessibilityIdentifier("maps-arriving")
    }

    @ViewBuilder private var glyph: some View {
        switch arrival.phase {
        case let .arriving(f): ProgressRing(fraction: f, lineWidth: 2.5)
        case .queued: Image(systemName: StateSymbol.get).font(.footnote.weight(.semibold))
        case .waiting(offline: true): Image(systemName: StateSymbol.offline).font(.footnote.weight(.semibold))
        case .waiting(offline: false): Image(systemName: "pause.circle").font(.footnote.weight(.semibold))
        case .failed, .unusable: Image(systemName: StateSymbol.failed).font(.footnote.weight(.semibold))
        }
    }
}

// MARK: - The map's top status slot

/// What sits at the top of the map, newest concern last: the one-time
/// welcome, the "Maps arriving" chip, a location message. Its own view so
/// the pack progress it reads (every whole percent) re-renders only this,
/// not the root. Also the home of the app-wide haptics for things that
/// finish on their own: a pack installed, a detailed area downloaded
/// (DESIGN.md "Haptics" — never for data arriving as such).
struct MapStatusStack: View {
    let model: AppModel
    var reduceMotion: Bool
    /// Framing an area or "Show on map": their bar has the slot, so the
    /// welcome and chip step aside (a location message still shows).
    var showsModeBar: Bool
    @Binding var frames: [ChromePiece: CGRect]

    private var packs: PackStore { model.shared.packs }

    private var arrival: CoreArrival? {
        CoreArrival.of(states: packs.states, resolved: packs.isResolved, canFetch: packs.canFetch,
                       online: Connectivity.shared.online, unusable: Set(packs.unusable.keys))
    }

    private var welcome: Bool { model.showsWelcome && !showsModeBar }

    var body: some View {
        let arrival = showsModeBar ? nil : arrival
        let transition: AnyTransition = reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
        VStack(alignment: .leading, spacing: 8) {
            if welcome {
                WelcomeCard { model.dismissWelcome() }
                    .transition(transition)
            }
            if let arrival {
                MapsArrivingChip(arrival: arrival) { open(arrival) }
                    .transition(.opacity)
            }
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.dismissNotice() }
                    .transition(transition)
            }
        }
        .reportFrame(.notice, into: $frames, when: welcome || arrival != nil || model.notice != nil)
        .animation(.snappy, value: model.notice)
        .animation(.snappy, value: welcome)
        .animation(.snappy, value: arrival == nil)
        .sensoryFeedback(.success, trigger: PackTally(packs)) { old, new in
            old.resolved && new.resolved && new.installed > old.installed
        }
        .sensoryFeedback(.success, trigger: model.shared.areas.areas.filter(\.isComplete).count) { old, new in new > old }
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(1))
            model.debugShowNotice()
        }
        #endif
    }

    private func open(_ arrival: CoreArrival) {
        if arrival.phase == .failed || arrival.phase == .queued {
            for pack in arrival.missing where packs.state(pack) != .installed && packs.unusable[pack] == nil { packs.fetch(pack) }
        }
        // the plant ID model alone: Storage opens on its row, highlighted
        model.openStorage(at: arrival.missing == [.plantid] ? StorageTarget.row(.plantid) : StorageTarget.core)
    }
}

/// Installed packs, once known (the haptic's trigger: the launch lookup
/// going from "nothing known" to "these are here" is not an arrival).
private nonisolated struct PackTally: Equatable, Sendable {
    let resolved: Bool
    let installed: Int

    @MainActor init(_ packs: PackStore) {
        resolved = packs.isResolved
        installed = packs.states.values.filter(\.isInstalled).count
    }
}

// MARK: - Welcome

/// The one-time welcome (docs/DESIGN.md §3 "States"): three small drawings
/// of the three core gestures — tap a community, Layers, Identify — each
/// with a two-word caption, and the real Layers and Identify buttons ringed
/// in ink while it shows. No pages, no carousel: one glance, one "OK".
/// Doing any of the three dismisses it too.
struct WelcomeCard: View {
    let onDismiss: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var art = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                vignette("Tap a community") { TapVignette() }
                vignette("Layers") { ControlVignette(symbol: "square.3.layers.3d") }
                vignette("Identify a plant") { IdentifyVignette() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tap a community on the map to see what grows there. Layers changes the map. Identify a plant names one from a photo.")
            HStack {
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Text("OK")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.glassProminent)
                .tint(DesignColor.ink)
                .frame(minHeight: 44)
                .accessibilityIdentifier("welcome-ok")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .mapChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
    }

    private func vignette(_ caption: String, @ViewBuilder _ drawing: () -> some View) -> some View {
        VStack(spacing: 6) {
            drawing()
                .frame(width: art * 1.3, height: art)
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A scrap of printed map: two communities in their Light tint (DAM's
/// dry-forest green, WRE's wet-forest teal over white), the tapped one in
/// the selection's red, a fingertip ring where it was tapped.
private struct TapVignette: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var left = Path()
            left.move(to: CGPoint(x: 0, y: 0))
            left.addLine(to: CGPoint(x: w * 0.52, y: 0))
            left.addCurve(to: CGPoint(x: w * 0.42, y: h), control1: CGPoint(x: w * 0.36, y: h * 0.35),
                          control2: CGPoint(x: w * 0.6, y: h * 0.7))
            left.addLine(to: CGPoint(x: 0, y: h))
            left.closeSubpath()
            var right = Path()
            right.move(to: CGPoint(x: w * 0.52, y: 0))
            right.addLine(to: CGPoint(x: w, y: 0))
            right.addLine(to: CGPoint(x: w, y: h))
            right.addLine(to: CGPoint(x: w * 0.42, y: h))
            right.addCurve(to: CGPoint(x: w * 0.52, y: 0), control1: CGPoint(x: w * 0.6, y: h * 0.7),
                           control2: CGPoint(x: w * 0.36, y: h * 0.35))
            right.closeSubpath()
            func tint(_ hex: String) -> Color {
                guard let c = MapColour.overWhite(hex, alpha: LayerState.fillOpacity(base: .topo, strength: .light)) else { return .gray }
                return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
            }
            ctx.fill(left, with: .color(tint("#98fe00")))
            ctx.fill(right, with: .color(tint("#00cbcb")))
            ctx.stroke(right, with: .color(Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)), lineWidth: 2.5)
            let tap = CGPoint(x: w * 0.74, y: h * 0.52)
            let r = min(w, h) * 0.17
            ctx.fill(Path(ellipseIn: CGRect(x: tap.x - r, y: tap.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.black.opacity(0.12)))
            ctx.stroke(Path(ellipseIn: CGRect(x: tap.x - r, y: tap.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.black.opacity(0.8)), lineWidth: 1.25)
        }
        .background(DesignColor.keyPlate)
        .overlay { Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5) }
    }
}

/// The map control as it looks: a white glass-like disc with the glyph.
private struct ControlVignette: View {
    let symbol: String
    @ScaledMetric(relativeTo: .footnote) private var side = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.42, weight: .medium))
            .foregroundStyle(Color.black)
            .frame(width: side, height: side)
            .background(Color.white, in: .circle)
            .overlay { Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5) }
            .overlay { WelcomeRing().padding(-4) }
    }
}

/// The Identify button as it looks beside the search field.
private struct IdentifyVignette: View {
    @ScaledMetric(relativeTo: .footnote) private var side = 36

    var body: some View {
        LeafViewfinder(pointSize: side * 0.46)
            .foregroundStyle(Color.black)
            .frame(width: side, height: side)
            .background(Color.black.opacity(0.07), in: .circle)
            .overlay { WelcomeRing().padding(-4) }
    }
}

/// The ink ring the welcome puts round a real control (and its drawing):
/// "this one". Static — nothing pulses (DESIGN.md "Motion").
struct WelcomeRing: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.black.opacity(0.85), lineWidth: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Whether the welcome was seen (one bool in UserDefaults; DEBUG and UI
/// tests set it with `-welcomeSeen YES|NO`).
struct WelcomeStore {
    var defaults: UserDefaults = .standard
    static let key = "welcomeSeen"

    var seen: Bool { defaults.bool(forKey: Self.key) }
    func markSeen() { defaults.set(true, forKey: Self.key) }
}

// MARK: - One icon language for states

/// The glyphs every state uses, so "offline", "not on the device" and "try
/// again" look the same wherever they appear (docs/DESIGN.md "States").
nonisolated enum StateSymbol {
    /// Needs reception, and there is none: live layers, photos, documents.
    static let offline = "antenna.radiowaves.left.and.right.slash"
    /// Not on the device; one tap gets it (DESIGN.md iconography).
    static let get = "arrow.down.circle"
    /// On the device.
    static let onDevice = "checkmark.circle"
    /// Something she started didn't finish; the line says what to do.
    static let failed = "exclamationmark.arrow.circlepath"
}

/// A quiet one-line state: a glyph and a sentence, an optional action
/// under it. Empty lists, offline notes and failures all use it.
struct StateLine: View {
    let symbol: String
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            .accessibilityElement(children: .combine)
            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 8)
    }
}
