import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// The pin card's photos (docs/PINS_PLAN.md §5): under the project chip,
/// above the fold, so they show at the fit detent. With photos: a strip —
/// the add button first, then square thumbnails NEWEST first (the photo
/// she just took lands beside the button, in view, without scrolling).
/// Without: just a compact "Add photo" capsule beside the chip. The add
/// button is a menu — Take Photo / Choose from Library — so the camera is
/// two taps away; where there is no camera it opens the library at once.
/// A thumbnail opens the full-screen viewer, paging across this pin's
/// photos, with the caption (editable), the date and Delete.
struct PinPhotos<Chip: View>: View {
    let model: AppModel
    let store: PinStore
    let pin: SavedPin
    @ViewBuilder let chip: () -> Chip

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var cameraDenied = false
    @State private var viewerID = UUID()
    /// The photo the viewer shows (followed by id, never by position).
    @State private var selected: UUID?

    var body: some View {
        let photos = pin.sortedPhotos
        let progress = store.photoImports[pin.id]
        VStack(alignment: .leading, spacing: 10) {
            if photos.isEmpty, progress == nil || progress?.finished == true {
                // "Add photo" beside the chip while both fit (a narrow iPad
                // card or a long project name: the glyph alone)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        chip()
                        Spacer(minLength: 0)
                        addButton(.capsule, progress: nil)
                    }
                    HStack(spacing: 8) {
                        chip()
                        Spacer(minLength: 0)
                        addButton(.glyph, progress: nil)
                    }
                }
            } else {
                chip()
                strip(photos, progress: progress)
            }
            if cameraDenied { deniedNote }
            if let progress, progress.finished, progress.failed > 0 { failedNote(progress) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            PlantIDCamera { image, metadata in
                showCamera = false
                guard let image else { return }
                let position = model.usableFix.map(PinPhotoPipeline.Position.init)
                store.importPhotos([.camera(image, metadata: metadata.map(PinStore.CameraMetadata.init), position: position,
                                            date: store.now())], to: pin.id)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $picks, maxSelectionCount: PinStore.photosPerPick,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            cameraDenied = false
            store.dismissPhotoImport(pin.id)
            store.importPhotos(items.map { item in
                .file {
                    // a failed hand-over is almost always a photo kept only in
                    // iCloud while offline: say that, not "not a photo"
                    let data: Data?
                    do { data = try await item.loadTransferable(type: Data.self) } catch {
                        throw PinPhotoPipeline.ImportError.notOnDevice
                    }
                    guard let data else { throw PinPhotoPipeline.ImportError.notOnDevice }
                    return data
                }
            }, to: pin.id)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.photoViewer == viewerID },
            set: { if !$0, model.photoViewer == viewerID { model.photoViewer = nil } }
        )) {
            PinPhotoViewer(model: model, store: store, pinID: pin.id, selected: $selected)
        }
        .animation(.snappy, value: photos.count)
        .animation(.snappy, value: cameraDenied)
    }

    // MARK: Strip

    private func strip(_ photos: [PinPhoto], progress: PinStore.PhotoImport?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                addButton(.tile, progress: progress.flatMap { $0.finished ? nil : $0 })
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                    Button {
                        open(i)
                    } label: {
                        PinPhotoThumb(photo: photo, side: PinPhotoMetrics.side)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel(photo.caption.isEmpty ? "Photo \(i + 1)" : photo.caption)
                    .accessibilityIdentifier("pin-photo-\(i)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityIdentifier("pin-photos")
    }

    private func open(_ index: Int) {
        guard model.photoViewer == nil else { return }
        store.flush()
        let photos = pin.sortedPhotos
        selected = photos.indices.contains(index) ? photos[index].id : nil
        model.photoViewer = viewerID
    }

    // MARK: Add

    @ViewBuilder
    private func addButton(_ style: AddPhotoLabel.Style, progress: PinStore.PhotoImport?) -> some View {
        let label = AddPhotoLabel(style: style, progress: progress)
        if progress != nil {
            label.accessibilityIdentifier("pin-photo-progress")
        } else if Self.hasCamera {
            Menu {
                Button { takePhoto() } label: { Label("Take Photo", systemImage: "camera") }
                    .accessibilityIdentifier("pin-photo-take")
                Button { chooseFromLibrary() } label: { Label("Choose from Library", systemImage: "photo.on.rectangle") }
                    .accessibilityIdentifier("pin-photo-library")
            } label: { label }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Add photo")
                .accessibilityIdentifier("pin-photo-add")
        } else {
            Button { chooseFromLibrary() } label: { label }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Add photo")
                .accessibilityIdentifier("pin-photo-add")
        }
    }

    private static var hasCamera: Bool { PinPhotoMetrics.hasCamera }

    private func takePhoto() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "debugPinCamera") == "denied" {
            cameraDenied = true
            return
        }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
            showCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraDenied = !granted
                showCamera = granted
            }
        default:
            cameraDenied = true
        }
    }

    private func chooseFromLibrary() {
        #if DEBUG
        // UI tests: the system picker runs in another process; drawn
        // photos go through the real pipeline instead (`-pinPhotoStub N`)
        let stub = UserDefaults.standard.integer(forKey: "pinPhotoStub")
        if stub > 0 {
            cameraDenied = false
            store.dismissPhotoImport(pin.id)
            let base = (pin.photos?.count ?? 0)
            store.importPhotos((0 ..< stub).map { i in
                .file { PinTestPhoto.jpeg(seed: base + i, portrait: (base + i) % 3 == 2) }
            }, to: pin.id)
            return
        }
        // measurements: `-pinPhotoStubDir <folder>` imports that folder's
        // files (the first 20) as if picked from the library
        if let dir = UserDefaults.standard.string(forKey: "pinPhotoStubDir"),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir).sorted() {
            store.importPhotos(names.map { name in
                let url = URL(filePath: dir).appending(path: name)
                return .file { try Data(contentsOf: url) }
            }, to: pin.id)
            return
        }
        #endif
        showLibrary = true
    }

    // MARK: Notes

    /// The camera refused: say so where she tapped, with the way to fix it;
    /// the library still works.
    private var deniedNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "camera")
                .foregroundStyle(DesignColor.secondaryInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("IzzyMap isn’t allowed to use the camera. Turn it on in Settings — photos from the library still work.")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 20) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                            .accessibilityIdentifier("pin-camera-settings")
                    }
                    Button("Choose a Photo") { chooseFromLibrary() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignColor.ink)
                .lineLimit(1)
                .frame(minHeight: 44)
            }
            Spacer(minLength: 0)
            CloseButton { cameraDenied = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-camera-denied")
    }

    private func failedNote(_ progress: PinStore.PhotoImport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: StateSymbol.failed)
                .foregroundStyle(DesignColor.secondaryInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.failed == 1 ? "1 photo couldn’t be added." : "\(progress.failed) photos couldn’t be added.")
                    .font(.subheadline)
                    .foregroundStyle(DesignColor.ink)
                // why (the first failure's reason, in plain words)
                if let reason = progress.reason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .accessibilityIdentifier("pin-photo-failed-reason")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            CloseButton { store.dismissPhotoImport(pin.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-photo-failed")
    }
}

/// The add button: compact, a capsule beside the chip ("Add photo"); in the
/// strip, a tile as tall as a thumbnail. Chrome, so concentric/capsule and
/// ink; while photos are coming in, their count and a progress ring.
private struct AddPhotoLabel: View {
    enum Style: Hashable { case capsule, glyph, tile }
    let style: Style
    let progress: PinStore.PhotoImport?

    var body: some View {
        if style != .tile {
            HStack(spacing: 6) {
                Image(systemName: "camera")
                if style == .capsule { Text("Add photo") }
            }
            .fixedSize()
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DesignColor.ink)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
            .contentShape(.capsule)
        } else {
            VStack(spacing: 6) {
                if let progress {
                    ProgressView(value: Double(progress.done + progress.failed), total: Double(max(1, progress.total)))
                        .progressViewStyle(.circular)
                        .tint(DesignColor.ink)
                        .frame(height: 22)
                    Text("\(min(progress.done + progress.failed + 1, progress.total)) of \(progress.total)")
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                } else {
                    Image(systemName: "camera")
                        .font(.body.weight(.medium))
                        .frame(height: 22)
                    Text("Add")
                        .font(.footnote.weight(.medium))
                }
            }
            .foregroundStyle(DesignColor.ink)
            .frame(width: 64, height: PinPhotoMetrics.side)
            .background(Color(uiColor: .tertiarySystemFill), in: ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true))
            .contentShape(.rect)
        }
    }
}

enum PinPhotoMetrics {
    /// A thumbnail in the card's strip (and the add tile's height).
    static let side: CGFloat = 76
    /// A pin row's lead box on a project page.
    static let row: CGFloat = 40

    /// Asked once per run (a device query).
    static let hasCamera: Bool = {
        #if DEBUG
        // screenshots on a camera-less simulator: `-debugPinCamera YES|denied`
        if UserDefaults.standard.string(forKey: "debugPinCamera") != nil { return true }
        #endif
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }()
}

// MARK: - Thumbnails

/// A photo's thumbnail as a square: cropped to fill, 0 radius, keyline —
/// printed matter, like the key boxes.
struct PinPhotoThumb: View {
    let photo: PinPhoto
    let side: CGFloat

    var body: some View {
        Group {
            if let image = PinThumbnails.image(photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(uiColor: .tertiarySystemFill)
                    .overlay { Image(systemName: "photo").foregroundStyle(DesignColor.secondaryInk) }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// Decoded thumbnails by photo id (a photo's thumbnail never changes), so
/// lists and the strip don't decode JPEGs on every redraw.
enum PinThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    static func image(_ photo: PinPhoto) -> UIImage? {
        image(id: photo.id) { photo.thumbnail }
    }

    /// By id: `data` is asked only on a miss (rows read one record, once).
    static func image(id: UUID, data: () -> Data?) -> UIImage? {
        let key = id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let bytes = data(), let image = UIImage(data: bytes)?.preparingForDisplay() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A pin row's lead: its newest photo's thumbnail with the pin's colour as
/// a small key box in the corner (colour is data; the photo says which
/// pin) — else the map's mark, centred in the same box, so the columns
/// line up either way. The cover comes from the store's photo index, so a
/// long list never walks every pin's photos.
struct PinRowMark: View {
    let store: PinStore
    let pin: SavedPin
    let side: CGFloat

    var body: some View {
        if let cover = store.coverPhoto(of: pin) {
            Group {
                if let image = PinThumbnails.image(id: cover, data: { store.thumbnail(cover) }) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(uiColor: .tertiarySystemFill)
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .overlay { Rectangle().strokeBorder(DesignColor.keyline, lineWidth: 0.5) }
                .overlay(alignment: .bottomTrailing) {
                    Rectangle()
                        .fill(Color(uiColor: PinColour.uiColor(hex: PinColour.hex(forName: pin.effectiveColourName))))
                        .overlay { Rectangle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5) }
                        .frame(width: side / 4, height: side / 4)
                        .padding(1.5)
                        .background(.white)
                }
                .accessibilityHidden(true)
        } else {
            PinMark(hex: PinColour.hex(forName: pin.effectiveColourName))
                .frame(width: side)
        }
    }
}

// MARK: - Viewer

/// The pin's photos full screen (the app's one `PhotoViewer`), newest
/// first like the strip; the footer edits the caption and deletes. It
/// follows the PHOTO she opened, not a position: photos arriving from an
/// import (or deleted in another window) never swap what she is looking
/// at — and the caption field and Delete with it — for another one.
private struct PinPhotoViewer: View {
    let model: AppModel
    let store: PinStore
    let pinID: UUID
    @Binding var selected: UUID?
    /// Where the selected photo was, for a neighbour when it goes.
    @State private var lastIndex = 0
    /// The screen's longer side in pixels: originals are decoded to that.
    @State private var screenPixels = 2048
    @Environment(\.displayScale) private var scale

    var body: some View {
        let pin = store.anyPin(pinID)
        let photos = pin?.sortedPhotos.filter { !$0.isDeleted } ?? []
        let ids = photos.map(\.id)
        let index = PinViewerSelection.index(of: selected, in: ids, lastIndex: lastIndex)
        let container = store.container
        let target = screenPixels
        PhotoViewer(
            model: model,
            title: AttributedString(pin?.displayTitle ?? "Photos"),
            photos: photos.map { photo in
                let id = photo.id
                return ViewerPhoto(id: id.uuidString, caption: photo.caption, quick: { PinThumbnails.image(photo) },
                                   // what the screen shows, never more (the viewer asks for room to zoom)
                                   load: { pixels in await PinStore.originalImage(photo: id, in: container, pixels: min(pixels, target)) })
            },
            page: Binding(get: { index }, set: { i in
                guard ids.indices.contains(i) else { return }
                selected = ids[i]
                lastIndex = i
            }),
            serifTitle: false,
            footer: { i in AnyView(PinPhotoFooter(store: store, photo: photos[i])) }
        )
        .onGeometryChange(for: CGFloat.self) { max($0.size.width, $0.size.height) } action: {
            screenPixels = max(1024, Int(($0 * scale).rounded()))
        }
        .onAppear { lastIndex = index }
        .onChange(of: ids) { _, ids in
            guard let next = PinViewerSelection.resolve(selected: selected, in: ids, lastIndex: lastIndex) else {
                model.photoViewer = nil
                return
            }
            selected = next.id
            lastIndex = next.index
        }
        .onDisappear { store.flush() }
    }
}

/// Which page the viewer shows when its list changes underneath.
nonisolated enum PinViewerSelection {
    /// The selected photo's page; if it is gone, its neighbour's (the page
    /// it was on, or the last).
    static func index(of selected: UUID?, in ids: [UUID], lastIndex: Int) -> Int {
        if let selected, let i = ids.firstIndex(of: selected) { return i }
        return min(max(0, lastIndex), max(0, ids.count - 1))
    }

    /// The photo to show after the list changed: the same one, else the
    /// neighbour in its place; nil when none is left (the viewer closes).
    static func resolve(selected: UUID?, in ids: [UUID], lastIndex: Int) -> (id: UUID, index: Int)? {
        guard !ids.isEmpty else { return nil }
        let i = index(of: selected, in: ids, lastIndex: lastIndex)
        return (ids[i], i)
    }
}

/// Under a pin's photo: its caption (typed in place, saved like the note),
/// when it was taken, its size, and Delete (asks first; for good — the
/// viewer then shows the neighbour, or closes after the last).
private struct PinPhotoFooter: View {
    let store: PinStore
    let photo: PinPhoto
    @State private var confirm = false
    @FocusState private var editing: Bool


    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Caption", text: Binding(get: { photo.caption }, set: { store.setCaption(photo, $0) }),
                          prompt: Text("Add a caption").foregroundStyle(.white.opacity(0.7)), axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .lineLimit(1 ... 4)
                    .focused($editing)
                    .submitLabel(.done)
                    .onChange(of: photo.caption) { _, text in
                        // Return means Done in a one-line caption
                        if text.contains("\n") {
                            store.setCaption(photo, text.replacingOccurrences(of: "\n", with: ""))
                            editing = false
                        }
                    }
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("pin-photo-caption")
                Text(Self.facts(photo))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("pin-photo-facts")
            }
            .shadow(color: .black.opacity(0.5), radius: 3)
            // a readable measure on an iPad's full width
            .frame(maxWidth: 640, alignment: .leading)
            Spacer(minLength: 0)
            Button("Delete Photo", systemImage: "trash") { confirm = true }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityIdentifier("pin-photo-delete")
                // anchored on the button (a popover's arrow points at it)
                .confirmationDialog("Delete this photo?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Delete Photo", role: .destructive) {
                        store.deletePhoto(photo)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("It’s deleted for good. This can’t be undone.")
                }
        }
        .id(photo.id)
    }

    /// "24 Nov 2026, 10:42 · 4032 × 3024 · 2.1 MB".
    static func facts(_ photo: PinPhoto) -> String {
        let date = photo.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        var parts = [date]
        if photo.width > 0, photo.height > 0 { parts.append("\(photo.width) × \(photo.height)") }
        if photo.bytes > 0 { parts.append(PinsStorageSection.size(photo.bytes) ?? "") }
        return parts.joined(separator: " · ")
    }
}

extension PinStore {
    /// A photo's original, downsampled by ImageIO to about `pixels` on its
    /// long side, read and decoded off the main actor (`@concurrent`). A
    /// plain async call, not a detached task: a page paged past cancels its
    /// `.task`, and a cancelled load stops before reading and before decoding.
    @concurrent
    nonisolated static func originalImage(photo id: UUID, in container: ModelContainer, pixels: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PinPhoto>(predicate: #Predicate { $0.id == id })
        guard let data = (try? context.fetch(descriptor))?.first?.original?.data, !Task.isCancelled else { return nil }
        return PinPhotoPipeline.image(data, pixels: pixels)
    }

    /// A photo's thumbnail bytes, read once by id (`PinThumbnails` caches).
    func thumbnail(_ photoID: UUID) -> Data? { photo(photoID)?.thumbnail }
}

#if DEBUG
/// Drawn stand-ins for photos (UI tests and screenshots: no photo is ever
/// committed): a landscape of sky, ridges and foliage specks, varied by
/// `seed`, 1600 × 1200 (or 1200 × 1600 portrait), as JPEG.
nonisolated enum PinTestPhoto {
    static func jpeg(seed: Int, portrait: Bool = false, size: CGSize? = nil) -> Data {
        image(seed: seed, size: size ?? (portrait ? CGSize(width: 1200, height: 1600) : CGSize(width: 1600, height: 1200)))
            .jpegData(compressionQuality: 0.85) ?? Data()
    }

    static func image(seed: Int, size: CGSize) -> UIImage {
        var rng = SplitMix(seed: UInt64(seed &+ 1) &* 0x9E37_79B9)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let palettes: [[UIColor]] = [
            [UIColor(red: 0.55, green: 0.72, blue: 0.86, alpha: 1), UIColor(red: 0.30, green: 0.40, blue: 0.24, alpha: 1)],
            [UIColor(red: 0.93, green: 0.74, blue: 0.52, alpha: 1), UIColor(red: 0.36, green: 0.30, blue: 0.20, alpha: 1)],
            [UIColor(red: 0.70, green: 0.75, blue: 0.78, alpha: 1), UIColor(red: 0.18, green: 0.30, blue: 0.22, alpha: 1)],
        ]
        let pal = palettes[seed % palettes.count]
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            let w = size.width, h = size.height
            // sky
            let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                pal[0].cgColor, UIColor.white.withAlphaComponent(0.9).cgColor,
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h * 0.55), options: [.drawsAfterEndLocation])
            // ridges, far to near, darker
            for layer in 0 ..< 4 {
                let t = CGFloat(layer) / 3
                let base = h * (0.38 + 0.14 * t)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: h))
                var x: CGFloat = 0
                var y = base
                while x <= w {
                    y = min(h, max(h * 0.25, y + CGFloat(rng.next(-1, 1)) * h * 0.03))
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += w / 40
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.close()
                pal[1].withAlphaComponent(0.35 + 0.65 * t).setFill()
                path.fill()
            }
            // foliage specks in the foreground
            for _ in 0 ..< 2200 {
                let x = CGFloat(rng.next(0, 1)) * w
                let y = h * (0.55 + 0.45 * CGFloat(rng.next(0, 1)))
                let r = CGFloat(rng.next(2, 9)) * w / 1600
                let g = rng.next(0.25, 0.6)
                UIColor(red: g * 0.6, green: g, blue: g * 0.45, alpha: rng.next(0.4, 0.9)).setFill()
                c.fillEllipse(in: CGRect(x: x, y: y, width: r * 2.2, height: r))
            }
            // a sun or a flower, so each photo reads differently
            UIColor(red: 0.98, green: 0.88, blue: 0.40, alpha: 0.95).setFill()
            let s = min(w, h) * CGFloat(rng.next(0.05, 0.1))
            c.fillEllipse(in: CGRect(x: w * CGFloat(rng.next(0.15, 0.85)), y: h * CGFloat(rng.next(0.08, 0.25)), width: s, height: s))
        }
    }

    /// A small deterministic generator (the photos are the same every run).
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ lo: Double, _ hi: Double) -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return lo + (hi - lo) * Double(z >> 11) / Double(1 << 53)
        }
    }
}
#endif
