import SwiftUI
import UIKit

/// Identify's photos in the full-screen viewer (`PhotoViewer`, as on the
/// plant sheet): her photo first — whole, at the size kept for display,
/// not just the framed square — then the candidates' photos, each with the
/// species and its credit.
extension ViewerPhoto {
    static func yours(_ session: PlantIDSession) -> ViewerPhoto? {
        guard let image = session.photo?.display ?? session.cropImage else { return nil }
        return ViewerPhoto(id: "your-photo", caption: "Your photo", quick: { image }, load: { _ in image })
    }

    static func reference(_ ref: PlantIDRefPhoto, name: String) -> ViewerPhoto {
        ViewerPhoto(
            id: ref.url.absoluteString,
            caption: ([name, ref.caption, ref.attribution] as [String?]).compactMap { $0 }.joined(separator: " · "),
            quick: { nil },
            load: { await PlantIDRefPhotos.image(ref, pixels: $0) }
        )
    }

    static func shown(_ shown: ShownPhoto, name: String) -> ViewerPhoto {
        switch shown {
        case let .ref(ref): return reference(ref, name: name)
        case let .guide(_, photo):
            return ViewerPhoto(
                id: photo.storedName,
                caption: "\(name) · \(photo.caption)",
                quick: { nil },
                load: { await PlantPhotoStore.shared.image(photo, size: .large, pixels: $0) }
            )
        }
    }
}
