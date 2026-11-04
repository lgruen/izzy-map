import SwiftUI

/// Step 2: the photo with a fixed square she moves and zooms the photo
/// under (the way Photos crops). The square is what gets identified — in the
/// evaluation many mistakes were photos with several plants in them. It
/// starts as the largest centred square (the model's own centre crop) and
/// zooms in no further than the photo's own pixels (224 per side).
struct PlantIDFraming: View {
    let session: PlantIDSession
    let packs: PackStore
    let hasSource: Bool
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let photo = session.photo {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    frame(photo, in: geo.size)
                }
                .background(Color.black)
                .clipped()
                bar
            }
            .onAppear { restore(photo) }
        }
    }

    // MARK: Geometry

    /// Square side in points.
    private func side(_ size: CGSize) -> CGFloat { max(80, min(size.width, size.height) - 48) }

    private func maxZoom(_ photo: PlantIDPhoto) -> CGFloat {
        max(1, CGFloat(min(photo.pixels.width, photo.pixels.height)) / 224)
    }

    /// The photo's size on screen at `z` (its short side = the square at 1).
    private func shown(_ photo: PlantIDPhoto, _ s: CGFloat, _ z: CGFloat) -> CGSize {
        let a = photo.aspect
        return a >= 1 ? CGSize(width: s * z * a, height: s * z) : CGSize(width: s * z, height: s * z / a)
    }

    private func clamp(_ o: CGSize, _ shown: CGSize, _ s: CGFloat) -> CGSize {
        let mx = max(0, (shown.width - s) / 2), my = max(0, (shown.height - s) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    private func liveZoom(_ photo: PlantIDPhoto) -> CGFloat { min(max(zoom * pinch, 1), maxZoom(photo)) }

    /// The square in unit coordinates of the photo.
    private func crop(_ photo: PlantIDPhoto, _ s: CGFloat, _ z: CGFloat, _ o: CGSize) -> CGRect {
        let d = shown(photo, s, z)
        let w = s / d.width, h = s / d.height
        let cx = 0.5 - o.width / d.width, cy = 0.5 - o.height / d.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Zoom and offset back from the session's crop (returning from results).
    private func restore(_ photo: PlantIDPhoto) {
        let c = session.crop
        let shortUnit = photo.aspect >= 1 ? c.height : c.width
        guard shortUnit > 0 else { return }
        zoom = min(max(1 / shortUnit, 1), maxZoom(photo))
        // offset is resolved per size in `frame` from the crop's centre
        restoredCentre = CGPoint(x: c.midX, y: c.midY)
    }

    @State private var restoredCentre: CGPoint?

    @ViewBuilder private func frame(_ photo: PlantIDPhoto, in size: CGSize) -> some View {
        let s = side(size)
        let z = liveZoom(photo)
        let d = shown(photo, s, z)
        let o = clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), d, s)
        ZStack {
            Image(uiImage: photo.display)
                .resizable()
                .frame(width: d.width, height: d.height)
                .offset(o)
                .accessibilityHidden(true)
            // outside the square dimmed; the square keylined with viewfinder corners
            SquareMask(side: s)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            ViewfinderCorners()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: s, height: s)
                .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(Color.white.opacity(0.8), lineWidth: 0.5)
                .frame(width: s, height: s)
                .allowsHitTesting(false)
            if session.step == .identifying {
                identifying
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(.rect)
        .gesture(
            SimultaneousGesture(
                DragGesture(minimumDistance: 1).updating($drag) { v, state, _ in state = v.translation }
                    .onEnded { v in
                        offset = clamp(CGSize(width: offset.width + v.translation.width,
                                              height: offset.height + v.translation.height), d, s)
                        commit(photo, s)
                    },
                MagnifyGesture().updating($pinch) { v, state, _ in state = v.magnification }
                    .onEnded { v in
                        let old = zoom
                        zoom = min(max(zoom * v.magnification, 1), maxZoom(photo))
                        // keep the square's centre where it was
                        offset = CGSize(width: offset.width * zoom / old, height: offset.height * zoom / old)
                        offset = clamp(offset, shown(photo, s, zoom), s)
                        commit(photo, s)
                    }
            ),
            isEnabled: session.step == .framing
        )
        .onTapGesture(count: 2) {
            guard session.step == .framing else { return }
            withAnimation(reduceMotion ? nil : .snappy) {
                zoom = 1
                offset = .zero
            }
            commit(photo, s)
        }
        .onAppear {
            if let c = restoredCentre {
                let dd = shown(photo, s, zoom)
                offset = clamp(CGSize(width: (0.5 - c.x) * dd.width, height: (0.5 - c.y) * dd.height), dd, s)
                restoredCentre = nil
            }
            commit(photo, s)
        }
        .onChange(of: size) { commit(photo, side(size)) }
        .accessibilityElement()
        .accessibilityLabel("Your photo, framed")
        .accessibilityValue(zoom > 1.01 ? "Zoomed in \(String(format: "%.1f", zoom)) times" : "Whole photo width")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 1.25 : 0.8
            zoom = min(max(zoom * step, 1), maxZoom(photo))
            offset = clamp(offset, shown(photo, s, zoom), s)
            commit(photo, s)
        }
        .accessibilityIdentifier("plant-id-frame")
    }

    private func commit(_ photo: PlantIDPhoto, _ s: CGFloat) {
        session.crop = crop(photo, s, zoom, offset)
    }

    private var identifying: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
            Text(session.preparing ? "Getting the identifier ready…" : "Identifying…")
                .font(.headline)
                .foregroundStyle(.white)
            if session.preparing {
                Text("The first time takes a few seconds.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plant-id-identifying")
    }

    // MARK: Bar

    private var bar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frame one plant — only the square is identified. Drag to move, pinch to zoom.")
                .font(.subheadline)
                .foregroundStyle(DesignColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !hasSource {
                PlantIDModelStatus(packs: packs)
            } else if let failed = session.prepareFailed {
                Label(failed, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            HStack {
                Spacer()
                Button {
                    session.identify()
                } label: {
                    Label("Identify", systemImage: "leaf")
                        .frame(minWidth: 140, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignColor.ink)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .controlSize(.large)
                .disabled(!session.hasModel || session.step == .identifying)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("plant-id-identify")
            }
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
    }
}

/// The whole area minus the centred square (even-odd fill = the surround).
nonisolated struct SquareMask: Shape {
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRect(CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        return p
    }
}

/// Four corner ticks, like the camera's viewfinder.
nonisolated struct ViewfinderCorners: Shape {
    func path(in r: CGRect) -> Path {
        let l = min(r.width, r.height) * 0.12
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * l, y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + dy * l))
        }
        return p
    }
}
