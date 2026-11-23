import SwiftUI
import UIKit

/// One photo in the full-screen viewer: how to get it big, and the credit
/// that goes with it (the licences want the credit wherever the photo is).
struct ViewerPhoto: Identifiable {
    let id: String
    let caption: String
    /// What is already decoded for the plate (shown at once, sharpened
    /// when `load` answers).
    let quick: () -> UIImage?
    /// The photo at about this many pixels on its longer side.
    let load: (Int) async -> UIImage?
}

/// The plant sheet's photos full screen: pinch or double-tap to zoom (a
/// UIScrollView, the system's own zooming), swipe between photos, tap to
/// hide or show the bar and credit. × or Escape closes it (Escape through
/// the window's chain, `EscapeStep.closePhoto`), and so does a swipe down
/// while the photo is at its fit; ← → page on a keyboard.
struct PhotoViewer: View {
    let model: AppModel
    let title: AttributedString
    let photos: [ViewerPhoto]
    @Binding var page: Int
    /// New York for names of living things; a pin's title is SF.
    var serifTitle = true
    /// Replaces the credit line for page i (a pin's photo: caption field,
    /// date, Delete). Hidden with the rest of the chrome.
    var footer: ((Int) -> AnyView)?
    @State private var chrome = true
    @FocusState private var focused: Bool
    /// Each photo's width ÷ height once it is drawn (where it sits on the
    /// screen decides whether the text needs a scrim).
    @State private var aspects: [String: CGFloat] = [:]
    /// Photos zoomed past their fit (they may cover anything).
    @State private var zoomed: Set<String> = []
    /// The screen, and the text rows on it (window coordinates).
    @State private var screen: CGRect = .zero
    @State private var topText: CGRect = .zero
    @State private var bottomText: CGRect = .zero
    /// Swipe down to close: how far the photo has followed the finger,
    /// and which way this drag was read (vertical = closing).
    @State private var pull: CGFloat = 0
    @State private var pullAxis: Axis?

    private var current: ViewerPhoto? { photos.isEmpty ? nil : photos[min(max(page, 0), photos.count - 1)] }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(0.6, pull / 500))
                .ignoresSafeArea()
                // the whole screen, keyboard or not, where the photo is
                // fitted (it ignores every safe area): the frame grown by
                // the insets it reports
                .onGeometryChange(for: CGRect.self) { proxy in
                    let f = proxy.frame(in: .global), s = proxy.safeAreaInsets
                    return CGRect(x: f.minX - s.leading, y: f.minY - s.top,
                                  width: f.width + s.leading + s.trailing, height: f.height + s.top + s.bottom)
                } action: { screen = $0 }
            TabView(selection: $page) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                    ZoomablePhoto(photo: photo, onTap: toggleChrome,
                                  onAspect: { aspects[photo.id] = $0 },
                                  onZoom: { if $0 { zoomed.insert(photo.id) } else { zoomed.remove(photo.id) } })
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // the photo crisp to its edges: no soft scroll-edge band under
            // the status bar (the black margins carry the bars)
            .scrollEdgeEffectHidden(true, for: .all)
            .ignoresSafeArea()
            .offset(y: pull)
            .simultaneousGesture(pullToClose)
        }
        .overlay(alignment: .top) {
            if chrome {
                topBar
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { topText = $0 }
                    .background(alignment: .top) { if scrims(over: topText) { topShade } }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if chrome, !photos.isEmpty {
                Group {
                    if let footer {
                        footer(min(max(page, 0), photos.count - 1))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 28)
                            .padding(.bottom, 12)
                            // a pin photo's footer band takes its own taps (a
                            // tap meant for the caption never falls through to
                            // the photo and hides the chrome) — the plants'
                            // credit doesn't: a tap or swipe there is the photo's
                            .contentShape(.rect)
                    } else {
                        credit
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bottomText = $0 }
                // the scrim travels with the text (up with the keyboard too)
                .background(alignment: .bottom) { if scrims(over: bottomText) { shade } }
                .transition(.opacity)
            }
        }
        // beside a pillarboxed photo the text keeps to the black margin
        .environment(\.photoViewerMeasure, sideMargin.map { max(160, $0 - 32) } ?? PhotoViewerMeasure.full)
        // (every scroll view in here: the pages' and each photo's zoom)
        .scrollEdgeEffectHidden(true, for: .all)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        // a container: its own identifier, the close button keeps its own
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-viewer")
        #if DEBUG
            // UI tests: what the window's Escape does now
            .accessibilityValue(model.escapeStep?.title ?? "")
        #endif
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .fontDesign(serifTitle ? .serif : .default)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if photos.count > 1 {
                    Text("\(page + 1) of \(photos.count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .accessibilityIdentifier("photo-viewer-page")
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(maxWidth: sideMargin.map { max(160, $0 - 32) } ?? .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark") { model.photoViewer = nil }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("photo-viewer-close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var credit: some View {
        Text(photos[min(max(page, 0), photos.count - 1)].caption)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: sideMargin.map { max(160, $0 - 32) } ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("photo-viewer-credit")
    }

    /// The scrims: full width behind their text rows, black 0 → 45 %, so
    /// white text holds over a bright sky. They travel with the text (the
    /// bottom one rides up with the keyboard), and they appear only where
    /// the photo actually lies under the text — on the black margins of a
    /// letter- or pillarboxed photo there is nothing to darken.
    private var topShade: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(minHeight: 88)
            .padding(.bottom, -24)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
    }

    private var shade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                               .init(color: .black.opacity(0.45), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(minHeight: 120)
            // under the home indicator, never stretched under the keyboard
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
    }

    /// The current photo at its fit, nil while its shape is unknown or it
    /// is zoomed (then it may cover anything).
    private var fitted: CGRect? {
        guard let current, let aspect = aspects[current.id], aspect > 0, screen.width > 0, screen.height > 0,
              !zoomed.contains(current.id) else { return nil }
        return PhotoFit.rect(aspect: aspect, in: screen)
    }

    /// A pillarboxed photo's black margin, when there is room in it for the
    /// text (a portrait photo on a landscape iPad: ~300 pt each side).
    private var sideMargin: CGFloat? {
        guard let fitted else { return nil }
        let margin = fitted.minX - screen.minX
        return margin >= PhotoViewerMeasure.marginForText ? margin : nil
    }

    /// Whether a text row needs its scrim: the photo lies under it. On the
    /// black of a letterbox (above and below) or a pillarbox margin (the
    /// text keeps to it) there is nothing to darken. Not knowing the
    /// photo's shape yet, or zoomed, counts as yes.
    private func scrims(over text: CGRect) -> Bool {
        guard let fitted else { return true }
        if sideMargin != nil { return false }
        return fitted.insetBy(dx: 1, dy: 1).intersects(text)
    }

    /// Swipe down (at the photo's fit) to close: the photo follows the
    /// finger and the black thins; let go past 100 pt, or flicked, and it
    /// closes — the way it came from the thumbnail. A sideways drag pages,
    /// a zoomed photo pans: neither closes.
    private var pullToClose: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if pullAxis == nil {
                    let t = value.translation
                    pullAxis = t.height > abs(t.width) * 1.5 ? .vertical : .horizontal
                }
                guard pullAxis == .vertical, let current, !zoomed.contains(current.id) else {
                    // a pinch that zoomed mid-drag: nothing left to close with
                    if pull != 0 { pull = 0 }
                    return
                }
                pull = max(0, value.translation.height)
            }
            .onEnded { value in
                defer { pullAxis = nil }
                // a fast pinch-out that began as a drag ends zoomed: no close
                guard pullAxis == .vertical, pull > 0, let current, !zoomed.contains(current.id) else {
                    if pull != 0 { withAnimation(.snappy) { pull = 0 } }
                    return
                }
                if pull > 100 || value.predictedEndTranslation.height > 260 {
                    model.photoViewer = nil
                } else {
                    withAnimation(.snappy) { pull = 0 }
                }
            }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let next = page + by
        guard photos.indices.contains(next) else { return .ignored }
        withAnimation { page = next }
        return .handled
    }
}

/// How wide the viewer's text may run: a readable measure on an iPad's
/// full width, or a pillarboxed photo's black margin (`photoViewerMeasure`).
enum PhotoViewerMeasure {
    static let full: CGFloat = 640
    /// A side margin at least this wide takes the text.
    static let marginForText: CGFloat = 200
}

extension EnvironmentValues {
    /// The width the viewer's text (a pin photo's caption) may take.
    @Entry var photoViewerMeasure: CGFloat = PhotoViewerMeasure.full
}

/// Where a photo of `aspect` (width ÷ height) sits when fitted to `bounds`.
nonisolated enum PhotoFit {
    static func rect(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let size = bounds.width / bounds.height > aspect
            ? CGSize(width: bounds.height * aspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / aspect)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// One page: the plate's image at once, the sharp one when it is decoded.
private struct ZoomablePhoto: View {
    let photo: ViewerPhoto
    let onTap: () -> Void
    /// The image's width ÷ height, once there is one.
    var onAspect: (CGFloat) -> Void = { _ in }
    /// Zoomed past the fit, or back at it.
    var onZoom: (Bool) -> Void = { _ in }
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    ZoomScroll(image: image, onTap: onTap, onZoom: onZoom)
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTap)
                    if settled {
                        Label("Couldn’t show the photo.", systemImage: StateSymbol.failed)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            }
            .task(id: photo.id) {
                if image == nil { image = photo.quick() }
                // room to zoom in: up to twice the screen's longer side
                // (ImageIO never enlarges, so a small photo stays its size)
                let side = max(geo.size.width, geo.size.height) * scale
                let pixels = Int(min(4096, max(1024, side * 2)))
                if let sharp = await photo.load(pixels), !Task.isCancelled { image = sharp }
                settled = true
            }
            .onChange(of: image?.size, initial: true) { _, size in
                if let size, size.width > 0, size.height > 0 { onAspect(size.width / size.height) }
            }
        }
    }
}

/// The system's zooming: a UIScrollView around an image view, fitted to
/// the screen at 1×, up to 2 screen pixels per photo pixel (at least
/// 3×); double tap zooms in there or back out; content centred
/// while it is smaller than the screen.
private struct ZoomScroll: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    var onZoom: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onTap = onTap
        view.onZoom = onZoom
        view.set(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        view.onZoom = onZoom
        if view.imageView.image !== image { view.set(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: (() -> Void)?
    /// Told when the photo leaves its fit (zoomed in) or comes back to it.
    var onZoom: ((Bool) -> Void)?
    private var isZoomed = false
    private var fittedTo: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        // no soft scroll-edge band over the photo's top (or bottom) edge
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        addSubview(imageView)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A new image (the sharp one replacing the plate's): same fit, the
    /// zoom kept where it was.
    func set(_ image: UIImage) {
        let keep = zoomScale > minimumZoomScale + 0.01
        let zoom = zoomScale
        let offset = contentOffset
        imageView.image = image
        fittedTo = .zero
        setNeedsLayout()
        layoutIfNeeded()
        if keep {
            zoomScale = min(zoom, maximumZoomScale)
            contentOffset = offset
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // (re-said once in a window: the system sets up the edge effects then)
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedTo, bounds.width > 0, bounds.height > 0 { fit() }
        centre()
    }

    /// The image at 1× fills the screen's width or height (aspect fit).
    private func fit() {
        fittedTo = bounds.size
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        minimumZoomScale = 1
        zoomScale = 1
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        // 2 screen pixels per photo pixel, never less than 3×
        let pixelZoom = image.size.width * image.scale * 2 / max(size.width, 1) / max(traitCollection.displayScale, 1)
        maximumZoomScale = max(3, pixelZoom)
    }

    /// While smaller than the screen, the photo sits in its middle.
    private func centre() {
        let size = imageView.frame.size
        let x = max(0, (bounds.width - size.width) / 2)
        let y = max(0, (bounds.height - size.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
        let now = zoomScale > minimumZoomScale + 0.01
        if now != isZoomed {
            isZoomed = now
            onZoom?(now)
        }
    }

    @objc private func singleTapped() { onTap?() }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let target = min(maximumZoomScale, 3)
        let point = tap.location(in: imageView)
        let w = bounds.width / target, h = bounds.height / target
        zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
    }
}
