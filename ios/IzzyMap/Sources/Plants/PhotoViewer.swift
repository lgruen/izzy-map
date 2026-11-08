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
/// the window's chain, `EscapeStep.closePhoto`); ← → page on a keyboard.
struct PhotoViewer: View {
    let model: AppModel
    let title: AttributedString
    let photos: [ViewerPhoto]
    @Binding var page: Int
    @State private var chrome = true
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                    ZoomablePhoto(photo: photo, onTap: toggleChrome)
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if chrome { topBar.transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if chrome, !photos.isEmpty { credit.transition(.opacity) }
        }
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
                    .fontDesign(.serif)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if photos.count > 1 {
                    Text("\(page + 1) of \(photos.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .accessibilityIdentifier("photo-viewer-page")
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("photo-viewer-credit")
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

/// One page: the plate's image at once, the sharp one when it is decoded.
private struct ZoomablePhoto: View {
    let photo: ViewerPhoto
    let onTap: () -> Void
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    ZoomScroll(image: image, onTap: onTap)
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

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onTap = onTap
        view.set(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        if view.imageView.image !== image { view.set(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: (() -> Void)?
    private var fittedTo: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
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

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

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
