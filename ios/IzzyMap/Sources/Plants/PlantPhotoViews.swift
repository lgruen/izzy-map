import IzzyKit
import SwiftUI

/// A square thumbnail, photo aspect-filled (data is square: no radius);
/// the growth-form pictogram until a photo arrives, and for good when
/// there is none or it can't be had (offline, not stored).
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
        .task(id: PhotoLoad(id: plant.id, online: Connectivity.shared.online)) {
            guard let photo = plant.photos.first else { image = nil; return }
            if image != nil, loaded == plant.id { return }
            if loaded != plant.id { image = nil }
            loaded = plant.id
            if let hit = PlantPhotoStore.shared.cached(photo, size: .thumb, pixels: pixels) {
                image = hit
                return
            }
            let fetched = await PlantPhotoStore.shared.image(photo, size: .thumb, pixels: pixels)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = fetched }
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
                    GrowthFormGlyph(shape: shape, ink: DesignColor.inkSecondary.opacity(0.6))
                        .frame(width: width * 0.22, height: width * 0.22)
                    if settled {
                        Text("This photo isn’t on the \(DeviceNoun.current) yet. Connect, or get all plant photos in Storage.")
                            .font(.footnote)
                            .foregroundStyle(DesignColor.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
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
}
