import IzzyKit
import SwiftUI

/// A square thumbnail, photo aspect-filled (data is square: no radius):
/// the guide's photo, else — only when the guide has none — the plant-ID
/// reference photo (the plant sheet then shows it with its credit); the
/// growth-form pictogram until a photo arrives, and for good when there
/// is none or the guide's can't be had (offline, not stored).
struct PlantThumb: View {
    let plant: Plant
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    /// The plant `image` shows.
    @State private var loaded: Int?

    private var pixels: Int { Int(side * scale) }

    var body: some View {
        ZStack {
            FormPlaceholder(shape: plant.silhouette)
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
        .accessibilityHidden(true)
        .task(id: PhotoLoad(id: plant.id, online: Connectivity.shared.online, refs: PlantIDRefPhotos.shared.revision)) {
            if image != nil, loaded == plant.id { return }
            if loaded != plant.id { image = nil }
            loaded = plant.id
            if let photo = plant.photos.first {
                if let hit = PlantPhotoStore.shared.cached(photo, size: .thumb, pixels: pixels) {
                    image = hit
                    return
                }
                let fetched = await PlantPhotoStore.shared.image(photo, size: .thumb, pixels: pixels)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = fetched }
                return
            }
            guard let ref = PlantIDRefPhotos.shared.photo(forPlant: plant) else { return }
            await RefPhotoLoad.run(ref, pixels: pixels) { img in
                guard let img else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = img }
            }
        }
    }
}

/// One photo on the plant sheet's plate: a fixed 4:3 box (the large
/// file's pixel size is unknown), the photo contained in it on the sheet's
/// own ground (no pillarbox colour: the photo's square edges carry the
/// plate), nothing written on the photo.
struct PlantPhotoPlate: View {
    let photo: PlantPhoto
    let shape: PlantSilhouette
    let width: CGFloat
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var settled = false
    /// The photo `image` shows.
    @State private var loaded: PlantPhoto?

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    GrowthFormGlyph(shape: shape, ink: DesignColor.secondaryInk.opacity(0.6))
                        .frame(width: width * 0.22, height: width * 0.22)
                    if settled {
                        // the states' one icon language (App/FirstLaunch.swift)
                        let offline = !Connectivity.shared.online
                        Label {
                            Text(offline
                                 ? "Not on this \(DeviceNoun.current) yet — it needs reception, or get all plant photos in Storage."
                                 : "This photo didn’t load. It tries again next time; all plant photos are in Storage.")
                        } icon: {
                            Image(systemName: offline ? StateSymbol.offline : StateSymbol.failed)
                        }
                        .font(.footnote)
                        .foregroundStyle(DesignColor.secondaryInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("photo-state")
                    }
                }
            }
        }
        .frame(width: width, height: width * 3 / 4)
        .clipped()
        .task(id: PhotoLoad(id: photo.storedName.hashValue, online: Connectivity.shared.online)) {
            if image != nil, loaded == photo { return }
            if loaded != photo { image = nil; settled = false }
            loaded = photo
            let pixels = Int(width * scale)
            if let hit = PlantPhotoStore.shared.cached(photo, size: .large, pixels: pixels) {
                image = hit
                return
            }
            let fetched = await PlantPhotoStore.shared.image(photo, size: .large, pixels: pixels)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                image = fetched
                settled = true
            }
        }
    }
}

/// A photo view's load key: the photo and the network state, so a photo
/// that couldn't be had offline (or behind a captive portal) is asked for
/// again when the connection comes back.
nonisolated struct PhotoLoad: Hashable, Sendable {
    var id: Int
    var online: Bool
    /// The reference photos' index revision (a stand-in may now exist).
    var refs = 0
}

/// The plant sheet's plate for a plant whose guide profile has no photo:
/// the plant-ID reference photo in the same 4:3 box, contained; what it
/// shows when it isn't a field photo ("Herbarium specimen") and its full
/// credit go under it (PlantSheet).
struct RefPhotoPlate: View {
    let photo: PlantIDRefPhoto
    let shape: PlantSilhouette
    let width: CGFloat
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var failed = false
    /// The request `image` belongs to (a re-appear doesn't fade it in again).
    @State private var loaded: PhotoRequestKey?

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    GrowthFormGlyph(shape: shape, ink: DesignColor.secondaryInk.opacity(0.6))
                        .frame(width: width * 0.22, height: width * 0.22)
                    if failed {
                        Label("Couldn’t show the photo.", systemImage: StateSymbol.failed)
                            .font(.footnote)
                            .foregroundStyle(DesignColor.secondaryInk)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .accessibilityIdentifier("photo-state")
                    }
                }
            }
        }
        .frame(width: width, height: width * 3 / 4)
        .clipped()
        .task(id: PhotoRequestKey(url: photo.url, revision: PlantIDRefPhotos.shared.revision)) {
            let key = PhotoRequestKey(url: photo.url, revision: PlantIDRefPhotos.shared.revision)
            if image != nil, loaded == key { return }
            image = nil
            failed = false
            await RefPhotoLoad.run(photo, pixels: Int(width * scale)) { img in
                if img != nil { loaded = key }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    image = img
                    failed = img == nil
                }
            }
        }
    }
}

private struct PhotoRequestKey: Equatable {
    let url: URL
    let revision: Int
}
