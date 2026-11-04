import Foundation
import IzzyKit
import Observation
import os
import UIKit

/// One open Identify screen: photo → framing → result. Owns the engine,
/// which loads the model lazily (when the screen opens and the model is on
/// the device) and lets go of it when the screen closes or memory runs low.
@MainActor @Observable
final class PlantIDSession {
    enum Step: Equatable {
        case capture
        case framing
        case identifying
        case result
        case failed(String)
    }

    private(set) var step: Step = .capture
    private(set) var photo: PlantIDPhoto?
    /// The framed square, unit coordinates of the upright photo.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private(set) var place: PlantIDPlace = .none
    private(set) var placeResolved = false
    private(set) var result: PlantIDResult?
    /// The framed part as shown (her crop beside the candidates).
    private(set) var cropImage: UIImage?
    private(set) var labels: [PlantIDLabel] = []
    /// The model is being loaded (the first Identify waits for it).
    private(set) var preparing = false
    private(set) var prepareFailed: String?
    /// A photo that couldn't be read.
    var photoError: String?
    /// Bumped per result, for the haptic.
    private(set) var resultCount = 0
    /// The system camera is up (full screen over Identify, whose views then
    /// disappear without Identify closing).
    @ObservationIgnored var cameraOpen = false

    @ObservationIgnored private var engine: PlantIDEngine?
    @ObservationIgnored private let locator = PlantIDLocator()
    @ObservationIgnored private var placeTask: Task<Void, Never>?
    @ObservationIgnored private var identifyTask: Task<Void, Never>?
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")

    private func observeMemory() {
        guard memoryObserver == nil else { return }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        }
    }

    // MARK: Model

    /// Where the identifier comes from now (nil: the `plantid` pack isn't on
    /// this device yet).
    static func source(packs: PackStore) -> PlantIDSource? {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let fake = defaults.string(forKey: "plantIDFake"), !fake.isEmpty { return .fake(fake) }
        if let dir = defaults.string(forKey: "plantIDDir"), !dir.isEmpty {
            return .files(URL(filePath: dir, directoryHint: .isDirectory))
        }
        // a developer run with `-dataDir`: the pack as build_packs.py staged it
        if case let .debugDirectory(data) = packs.mode {
            let staged = PlantIDFiles.staged(in: data)
            if FileManager.default.fileExists(atPath: staged.appending(path: PlantIDFiles.head).path(percentEncoded: false)) {
                return .files(staged)
            }
        }
        #endif
        return packs.plantIDDirectory.map(PlantIDSource.files)
    }

    /// The model's source became known (or changed): start loading it in the
    /// background, so Identify is quick by the time she has framed.
    func use(_ source: PlantIDSource?) {
        observeMemory()
        guard let source else { engine = nil; return }
        if let engine, engine.source == source { return }
        let engine = PlantIDEngine(source: source)
        self.engine = engine
        prepareFailed = nil
        preparing = true
        Task {
            do {
                let labels = try await engine.labels()
                try await engine.prepare()
                guard self.engine === engine else { return }
                self.labels = labels
                preparing = false
            } catch {
                guard self.engine === engine else { return }
                preparing = false
                prepareFailed = error.localizedDescription
            }
        }
    }

    var hasModel: Bool { engine != nil }

    /// Identify closed: everything goes (the model is ~0.4 GB of memory).
    func close() {
        placeTask?.cancel()
        identifyTask?.cancel()
        if let engine { Task { await engine.release() } }
        engine = nil
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
    }

    private func memoryWarning() {
        guard step != .identifying, let engine else { return }
        Self.logger.notice("memory warning: releasing the encoder")
        Task { await engine.release(keepScorer: true) }
    }

    // MARK: Steps

    func accept(_ photo: PlantIDPhoto) {
        self.photo = photo
        crop = Self.defaultCrop(aspect: photo.aspect)
        result = nil
        step = .framing
        locate(photo)
    }

    /// The photo couldn't be had (picker error, unreadable file).
    func reject(_ message: String) {
        photoError = message
    }

    /// The largest centred square: what open_clip's centre crop would take.
    static func defaultCrop(aspect a: CGFloat) -> CGRect {
        a >= 1 ? CGRect(x: (1 - 1 / a) / 2, y: 0, width: 1 / a, height: 1)
            : CGRect(x: 0, y: (1 - a) / 2, width: 1, height: a)
    }

    private func locate(_ photo: PlantIDPhoto) {
        placeTask?.cancel()
        placeResolved = false
        #if DEBUG
        if let forced = PlantIDLocator.debugOverride {
            place = photo.location.map(PlantIDPlace.photo) ?? forced
            placeResolved = true
            return
        }
        #endif
        if let p = photo.location {
            place = .photo(p)
            placeResolved = true
            return
        }
        place = .none
        placeTask = Task {
            let p = await locator.current()
            guard !Task.isCancelled, self.photo?.display === photo.display else { return }
            place = p.map(PlantIDPlace.current) ?? .none
            placeResolved = true
        }
    }

    func retake() {
        identifyTask?.cancel()
        placeTask?.cancel()
        photo = nil
        result = nil
        cropImage = nil
        step = .capture
    }

    func reframe() {
        identifyTask?.cancel()
        result = nil
        step = .framing
    }

    func identify() {
        guard let photo, let engine, step != .identifying else { return }
        step = .identifying
        let crop = crop
        cropImage = photo.displayCrop(crop)
        identifyTask = Task {
            // the location has a few seconds' head start (framing); wait a
            // little more for a first fix, then go without
            let waitUntil = ContinuousClock.now + .seconds(4)
            while !placeResolved, ContinuousClock.now < waitUntil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let point = place.point
            do {
                let pixels = await Task.detached(priority: .userInitiated) { photo.pixels(in: crop) }.value
                let r = try await engine.identify(pixels, location: point)
                let labels = try await engine.labels()
                guard !Task.isCancelled, self.engine === engine else { return }
                self.labels = labels
                result = r
                resultCount += 1
                step = .result
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("identify failed: \(String(describing: error), privacy: .public)")
                step = .failed(error.localizedDescription)
            }
        }
    }

    func label(_ i: Int) -> PlantIDLabel? { labels.indices.contains(i) ? labels[i] : nil }
}
