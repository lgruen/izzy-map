import IzzyKit
import PhotosUI
import SwiftUI

/// What the Identify screen's navigation stack can push.
nonisolated enum PlantIDRoute: Hashable, Sendable {
    /// The existing plant sheet (a label with an Understorey Network profile).
    case plant(id: Int, key: String)
    /// A label without a UN profile: name, family, the iNaturalist link.
    case noProfile(label: Int)
    case credits
    /// The hidden pack Diagnostics (long-press "Model & training photos").
    case diagnostics
}

/// Identify a plant (docs/NATIVE_PLAN.md §4, DESIGN.md "Plant ID"): take
/// or pick a photo → frame the plant in a square → the answer ladder, her
/// crop beside each candidate's photo. Everything runs on the device; the
/// model (the `plantid` pack) loads when this screen opens and goes when
/// it closes.
struct PlantIDView: View {
    let model: AppModel
    @State private var session = PlantIDSession()
    @State private var path: [PlantIDRoute] = []
    @Environment(\.dismiss) private var dismiss

    private var packs: PackStore { model.shared.packs }
    private var source: PlantIDSource? { PlantIDSession.source(packs: packs) }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(session.step == .result ? "Suggestions" : "Identify a Plant")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("plant-id-close")
                    }
                    if session.step != .capture {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("New Photo", systemImage: "camera") { session.retake() }
                                .accessibilityIdentifier("plant-id-new-photo")
                        }
                    }
                }
                .navigationDestination(for: PlantIDRoute.self) { route in
                    destination(route)
                }
        }
        // Escape: plant sheet / credits → the suggestions, then closes
        .modalEscape(model, depth: path.count) { if !path.isEmpty { path.removeLast() } }
        .onAppear {
            PlantIDOpenTiming.appeared()
            session.use(source)
            PlantIDRefPhotos.shared.use(packs: packs)
        }
        .onChange(of: source) { _, new in session.use(new) }
        .onChange(of: packs.state(.refphotos)) { _, _ in PlantIDRefPhotos.shared.use(packs: packs) }
        // not while the camera covers Identify: that is still Identify
        .onDisappear { if !session.cameraOpen { session.close() } }
        // DESIGN.md "Haptics": success only for a species; a genus gets a
        // selection tick; "not sure" gets nothing (the system setting rules)
        .sensoryFeedback(trigger: session.resultCount) { _, _ in
            switch session.result?.answer {
            case .species: .success
            case .genus: .selection
            default: nil
            }
        }
        #if DEBUG
        .task { await debugLaunch() }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .capture:
            PlantIDCapture(session: session, packs: packs, hasSource: source != nil,
                           showCredits: { path.append(.credits) }, showDiagnostics: { path.append(.diagnostics) })
        case .framing, .identifying:
            PlantIDFraming(session: session, packs: packs, hasSource: source != nil)
        case .result:
            if let result = session.result {
                PlantIDResults(session: session, result: result) { route in path.append(route) }
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t identify this photo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .foregroundStyle(DesignColor.secondaryInk)
            } actions: {
                Button("Try Again") { session.identify() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignColor.ink)
                Button("Frame Again") { session.reframe() }
            }
        }
    }

    @ViewBuilder private func destination(_ route: PlantIDRoute) -> some View {
        switch route {
        case let .plant(id, key):
            // the sheet's records and mini-map are Tasmania's: a mainland
            // place would only ring a point off the map
            let here = session.place.point.flatMap { PlantIDModel.inTasmania($0) ? $0 : nil }
            PlantSheet(model: model, plantID: id, key: key,
                       context: PlantContext(code: nil, latitude: here?.latitude, longitude: here?.longitude),
                       source: "plant-id-\(id)", onClose: { dismiss() })
                .navigationTitle("")
        case let .noProfile(label):
            if let l = session.label(label) {
                PlantIDNoProfile(label: l, crop: session.cropImage,
                                 p: session.result.flatMap { r in (r.candidates + r.genusSpecies).first { $0.label == label }?.p },
                                 ref: PlantIDRefPhotos.shared.photo(for: label, name: l.name))
            }
        case .credits:
            PlantIDCreditsView(source: source)
        case .diagnostics:
            PackDiagnosticsView(packs: packs)
        }
    }

    #if DEBUG
    /// `-plantIDPhoto <path>`: start from that photo; `-plantIDAutoIdentify
    /// YES`: identify it straight away (screenshots); `-plantIDCrop
    /// x,y,w,h`: the framed square (unit coordinates).
    private func debugLaunch() async {
        let d = UserDefaults.standard
        guard session.photo == nil, let file = d.string(forKey: "plantIDPhoto"), !file.isEmpty else { return }
        let url = URL(filePath: file)
        guard let photo = try? await Task.detached(operation: { try PlantIDPhoto.decode(Data(contentsOf: url)) }).value
        else { return }
        session.accept(photo)
        if let raw = d.string(forKey: "plantIDCrop") {
            let v = raw.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { session.crop = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        }
        guard d.bool(forKey: "plantIDAutoIdentify") else { return }
        while !session.hasModel { try? await Task.sleep(for: .milliseconds(100)) }
        session.identify()
    }
    #endif
}

// MARK: - Capture

/// Step 1: the camera or a photo from the library.
struct PlantIDCapture: View {
    let session: PlantIDSession
    let packs: PackStore
    let hasSource: Bool
    let showCredits: () -> Void
    var showDiagnostics: () -> Void = {}
    @State private var pick: PhotosPickerItem?
    @State private var showCamera = false
    @State private var loading = false
    @ScaledMetric(relativeTo: .largeTitle) private var glyph = 64

    /// Asked once per run (it was asked on every body evaluation: a device
    /// query, on the main thread, while the sheet opened).
    private static let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
    private var cameraAvailable: Bool { Self.hasCamera }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    LeafViewfinder(pointSize: glyph)
                        .foregroundStyle(DesignColor.ink)
                        .padding(.top, 24)
                    Text("Identify a plant")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DesignColor.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Photograph one plant — a leaf, a flower or the whole shrub. IzzyMap suggests what it is, on this \(DeviceNoun.current), offline.")
                        .font(.body)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                VStack(spacing: 12) {
                    if cameraAvailable {
                        Button {
                            session.cameraOpen = true
                            showCamera = true
                        } label: {
                            Label("Take a Photo", systemImage: "camera")
                                .frame(maxWidth: 320, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignColor.ink)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .accessibilityIdentifier("plant-id-camera")
                    }
                    libraryButton
                }
                .controlSize(.large)
                if loading {
                    ProgressView("Opening the photo…")
                }
                if let error = session.photoError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                }
                if !hasSource {
                    PlantIDModelStatus(packs: packs)
                        .frame(maxWidth: 420)
                }
                Button(action: showCredits) {
                    Label("Model & training photos", systemImage: "info.circle")
                        .font(.footnote)
                }
                .foregroundStyle(DesignColor.secondaryInk)
                // hidden: what the system and the app think of each pack
                .simultaneousGesture(LongPressGesture(minimumDuration: 1.2).onEnded { _ in showDiagnostics() })
                .accessibilityIdentifier("plant-id-credits")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .fullScreenCover(isPresented: $showCamera) {
            PlantIDCamera { image in
                showCamera = false
                session.cameraOpen = false
                guard let image else { return }
                load { try PlantIDPhoto.decode(camera: image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            loading = true
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw PlantIDPhoto.DecodeError.notAnImage
                    }
                    load { try PlantIDPhoto.decode(data) }
                } catch {
                    loading = false
                    session.reject("That photo couldn’t be opened.")
                }
            }
        }
    }

    private var label: some View {
        Label("Choose a Photo", systemImage: "photo.on.rectangle")
            .frame(maxWidth: 320, minHeight: 36)
    }

    @ViewBuilder private var libraryButton: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "plantIDPickStub") {
            // UI tests: the system picker runs in another process; this
            // stands in with a drawn (synthetic) photo
            Button { load { try PlantIDPhoto.decode(PlantIDTestPhoto.png()) } } label: { label }
                .buttonStyle(.bordered)
                .tint(DesignColor.ink)
                .accessibilityIdentifier("plant-id-library")
        } else {
            picker
        }
        #else
        picker
        #endif
    }

    private var picker: some View {
        PhotosPicker(selection: $pick, matching: .images, preferredItemEncoding: .current) {
            Label("Choose a Photo", systemImage: "photo.on.rectangle")
                .frame(maxWidth: 320, minHeight: 36)
        }
            .buttonStyle(.bordered)
            .tint(DesignColor.ink)
            .accessibilityIdentifier("plant-id-library")
    }

    /// Decodes off the main thread, then frames it.
    private func load(_ decode: @escaping @Sendable () throws -> PlantIDPhoto) {
        loading = true
        session.photoError = nil
        Task {
            do {
                let photo = try await Task.detached(priority: .userInitiated) { try decode() }.value
                loading = false
                session.accept(photo)
            } catch {
                loading = false
                session.reject(error.localizedDescription)
            }
        }
    }
}

/// "The model isn't here yet" with a one-tap Get (the `plantid` pack is
/// prefetched with the install, so this mostly shows its progress).
struct PlantIDModelStatus: View {
    let packs: PackStore

    var body: some View {
        let state = packs.state(.plantid)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(headline(state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
            } icon: {
                // the states' one icon language (App/FirstLaunch.swift)
                Image(systemName: symbol(state))
                    .foregroundStyle(DesignColor.secondaryInk)
            }
            Text(detail(state))
                .font(.footnote)
                .foregroundStyle(DesignColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            switch state {
            case let .downloading(f):
                if let f {
                    ProgressView(value: f)
                        .tint(DesignColor.ink)
                        .accessibilityLabel("Downloading the model, \(Int(f * 100)) percent")
                } else {
                    ProgressView().tint(DesignColor.ink)
                }
            case .notInstalled, .failed:
                if packs.canFetch {
                    Button {
                        packs.fetch(.plantid)
                    } label: {
                        Label(getTitle, systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignColor.ink)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .accessibilityIdentifier("plant-id-get-model")
                }
            case .paused:
                Button("Resume") { packs.resume(.plantid) }
                    .buttonStyle(.bordered)
                    .tint(DesignColor.ink)
            case .unpublished:
                // the catalogue on the device may predate the upload: a tap
                // asks the server again (PackStore refreshes it on "not found")
                if packs.canFetch {
                    Button("Check Again") { packs.fetch(.plantid) }
                        .buttonStyle(.bordered)
                        .tint(DesignColor.ink)
                        .accessibilityIdentifier("plant-id-check-again")
                }
            case .installed:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Rectangle().strokeBorder(DesignColor.keyline.opacity(0.5), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plant-id-model-status")
    }

    private var getTitle: String {
        let bytes = packs.downloadSizes[.plantid] ?? PackSizes.nominal[.plantid] ?? 0
        return bytes > 0 ? "Get the model · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" : "Get the model"
    }

    private func symbol(_ s: PackState) -> String {
        switch s {
        case .downloading, .installed: "leaf"
        case .paused: Connectivity.shared.online ? "pause.circle" : StateSymbol.offline
        case .failed: StateSymbol.failed
        case .notInstalled: StateSymbol.get
        case .unpublished: "clock"
        }
    }

    /// An older model on the device (v1), its replacement on its way.
    private var updating: Bool { packs.outdated.contains(.plantid) }

    /// Its files were found cut short: removed, downloading again.
    private var repairing: Bool { packs.repairing.contains(.plantid) }

    private func headline(_ s: PackState) -> String {
        if repairing { return PlantIDFailure.repairing }
        if updating {
            if case let .downloading(f?) = s { return "Model update on its way · \(StorageText.percent(f))" }
            return "Model update on its way"
        }
        return switch s {
        case let .downloading(f?): "Getting the identification model · \(StorageText.percent(f))"
        case .downloading: "Getting the identification model…"
        case .paused: "The model download is paused"
        case .failed: "The model download didn’t finish"
        case .installed: "The identification model is on this \(DeviceNoun.current)"
        case .notInstalled: "The identification model isn’t on this \(DeviceNoun.current) yet"
        case .unpublished: "The identification model isn’t published for this version yet"
        }
    }

    private func detail(_ s: PackState) -> String {
        if repairing, s != .paused {
            let progress = if case let .downloading(f?) = s { " (\(StorageText.percent(f)))" } else { "" }
            return "Its files on this \(DeviceNoun.current) were incomplete\(progress). You can take or choose the photo now — Identify works once it’s in."
        }
        if updating, s != .paused {
            return "This \(DeviceNoun.current) has an older identification model; the new one downloads by itself. You can take or choose the photo now — Identify works once it’s in."
        }
        return switch s {
        case .downloading: "You can take or choose the photo now; Identify works once it’s in."
        case .paused: Connectivity.shared.online ? "iOS paused it; it carries on by itself." : "It carries on by itself when there’s reception."
        case let .failed(why): why
        case .installed: ""
        case .unpublished: "It will download by itself once it’s published."
        case .notInstalled: packs.canFetch
            ? "Identification runs on the \(DeviceNoun.current), so it needs its model once, over Wi-Fi."
            : "This build can’t download it."
        }
    }
}

/// A plant the identifier knows but the Understorey Network has no page
/// for — most of the Australia-wide model's 22,000 natives, and the
/// Tasmanian model's mosses, weeds and spelling variants. Her photo is the
/// visual (there is no reference photo to show), then the name set
/// properly, the family and genus, and one honest line about the guide.
struct PlantIDNoProfile: View {
    let label: PlantIDLabel
    var crop: UIImage?
    var p: Double?
    /// Its reference photo (refphotos pack), shown beside hers.
    var ref: PlantIDRefPhoto?
    @Environment(\.horizontalSizeClass) private var widthClass

    private var explanation: String {
        label.isTasmanian
            ? "IzzyMap’s plant pages come from the Understorey Network Tasmania database, which has no page for this species. Many of these are mosses, liverworts, weeds or names the database spells differently."
            : "The guide covers Tasmania’s plants; this one grows elsewhere in Australia. IzzyMap recognises it from photos taken across the country — compare your photo with the reference before relying on the name."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let ref {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            let s = (geo.size.width - 8) / 2
                            HStack(spacing: 8) {
                                Group {
                                    if let crop {
                                        Image(uiImage: crop).resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                                    }
                                }
                                .frame(width: s, height: s)
                                .clipped()
                                .accessibilityLabel("Your photo")
                                RefPhotoImage(photo: ref, side: s, label: label)
                                    .accessibilityIdentifier("plant-id-noprofile-ref")
                            }
                        }
                        .aspectRatio(2, contentMode: .fit)
                        HStack(alignment: .top, spacing: 8) {
                            Text("Your photo")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reference")
                                RefPhotoCredit(photo: ref)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                        .foregroundStyle(DesignColor.secondaryInk)
                    }
                    .frame(maxWidth: widthClass == .regular ? 620 : .infinity)
                } else if let crop {
                    Image(uiImage: crop)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(maxWidth: widthClass == .regular ? 420 : .infinity)
                        .clipped()
                        .overlay { Rectangle().strokeBorder(DesignColor.keyline.opacity(0.5), lineWidth: 0.5) }
                        .overlay(alignment: .bottomLeading) {
                            Text("Your photo")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45))
                                .padding(8)
                        }
                        .accessibilityLabel("Your photo")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(BotanicalNames.species(label.name))
                        .font(.title2)
                        .fontDesign(.serif)
                        .foregroundStyle(DesignColor.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("plant-id-noprofile-name")
                    if let common = label.common.flatMap(CommonName.headline) {
                        Text(common)
                            .font(.title3)
                            .foregroundStyle(DesignColor.ink)
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    if let family = label.family { fact("Family", Text(family)) }
                    fact("Genus", Text(label.genusName).italic().fontDesign(.serif))
                    if let p { fact("Match", Text(PlantIDResults.percent(p)).monospacedDigit()) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not in the Understorey Network guide")
                        .font(.headline)
                        .foregroundStyle(DesignColor.ink)
                    Text(explanation)
                        .font(.body)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                // a web link only while it can open
                if Connectivity.shared.online, let id = label.inat, let url = URL(string: "https://www.inaturalist.org/taxa/\(id)") {
                    Link(destination: url) {
                        Label("Photos on iNaturalist", systemImage: "arrow.up.right.square")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignColor.ink)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("plant-id-noprofile")
    }

    private func fact(_ name: String, _ value: Text) -> some View {
        GridRow {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(DesignColor.secondaryInk)
            value
                .font(.body)
                .foregroundStyle(DesignColor.ink)
        }
    }
}

#if DEBUG
enum PlantIDDebug {
    /// `-debugPlantID` opened Identify once this launch.
    static var opened = false
}
#endif
