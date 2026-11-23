import SwiftUI
import UIKit

/// The system camera, full screen (UIImagePickerController: the supported
/// way to take one still photo without building a camera). nil = cancelled.
/// Identify and the pin card's "Take Photo" share it; the pin card also
/// keeps the capture's metadata (lens, exposure — `mediaMetadata`).
struct PlantIDCamera: UIViewControllerRepresentable {
    let done: (UIImage?, [String: Any]?) -> Void

    init(done: @escaping (UIImage?, [String: Any]?) -> Void) { self.done = done }
    init(done: @escaping (UIImage?) -> Void) { self.done = { image, _ in done(image) } }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?, [String: Any]?) -> Void
        init(done: @escaping (UIImage?, [String: Any]?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage, info[.mediaMetadata] as? [String: Any])
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil, nil) }
    }
}

#if DEBUG
/// A drawn stand-in for a photo (UI tests: no photo is ever committed):
/// leaves on a dark ground, 1200 × 900, PNG.
nonisolated enum PlantIDTestPhoto {
    static func png() -> Data {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.12, green: 0.16, blue: 0.10, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            for i in 0 ..< 18 {
                let t = Double(i) / 18
                let centre = CGPoint(x: 600 + 380 * cos(t * 2 * .pi), y: 450 + 300 * sin(t * 2 * .pi))
                c.saveGState()
                c.translateBy(x: centre.x, y: centre.y)
                c.rotate(by: t * 2 * .pi)
                UIColor(red: 0.25 + 0.3 * t, green: 0.5 + 0.2 * sin(t * 6), blue: 0.2, alpha: 1).setFill()
                c.fillEllipse(in: CGRect(x: -140, y: -40, width: 280, height: 80))
                c.restoreGState()
            }
            UIColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 540, y: 390, width: 120, height: 120))
        }
    }
}
#endif
