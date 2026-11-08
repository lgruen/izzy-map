import CoreML
import Foundation
import IzzyKit
import os
import Synchronization

/// Turns the 1 × 3 × 224 × 224 input into the 1024-value embedding.
nonisolated protocol PlantEncoding: Sendable {
    func embedding(_ tensor: [Float]) async throws -> [Float]
}

/// Where the identifier's files are.
nonisolated enum PlantIDSource: Sendable, Equatable {
    /// The `plantid` pack (or the DEBUG `-plantIDDir` folder): the compiled
    /// encoder and the scorer's tables side by side.
    case files(URL)
    #if DEBUG
    /// `-plantIDFake <species|genus|unsure>`: a synthetic scorer over real
    /// UN species and a fixed embedding (UI tests, screenshots).
    case fake(String)
    #endif
}

nonisolated enum PlantIDFailure: LocalizedError, Equatable {
    case missingFiles
    /// The pack's files are cut short (`PackVerification`): the store marks
    /// the pack unusable (reinstalling IzzyMap downloads it again).
    case damaged(String)
    case model(String)
    case prediction(String)

    /// What Identify says about a damaged model.
    static let incomplete = "The identification model is incomplete on this device."

    var errorDescription: String? {
        switch self {
        case .missingFiles: "The identification model’s files aren’t complete on this device."
        case .damaged: Self.incomplete
        case let .model(why): "The identification model couldn’t be loaded (\(why))."
        case let .prediction(why): "The photo couldn’t be identified (\(why))."
        }
    }
}

/// The Core ML image encoder (BioCLIP 2.5, 8-bit weights), compute units
/// CPU + Neural Engine unless the benchmark asks otherwise. Loaded on first
/// use, released when Identify closes and on a memory warning: ~1.1 GB of
/// app memory while loaded, ~0.3 s to load again (device, build 12).
nonisolated final class CoreMLPlantEncoder: PlantEncoding, @unchecked Sendable {
    let model: MLModel
    /// Explicitly CPU+ANE, not .all (device benchmark, build 12: .all's first
    /// load took 35-45 s; 315 ms load, 53 ms predictions, ~1.1 GB loaded).
    static let defaultUnits: MLComputeUnits = .cpuAndNeuralEngine

    static func load(_ url: URL, units: MLComputeUnits = defaultUnits) async throws -> CoreMLPlantEncoder {
        let config = MLModelConfiguration()
        config.computeUnits = units
        config.modelDisplayName = "PlantEncoder-w8"
        do {
            return CoreMLPlantEncoder(model: try await MLModel.load(contentsOf: url, configuration: config))
        } catch {
            throw PlantIDFailure.model(error.localizedDescription)
        }
    }

    private init(model: MLModel) { self.model = model }

    /// An all-zero input (the warm-up prediction).
    static let blank = [Float](repeating: 0, count: 3 * PlantIDPreprocess.size * PlantIDPreprocess.size)

    func embedding(_ tensor: [Float]) async throws -> [Float] {
        let input = MLMultiArray(MLShapedArray<Float>(scalars: tensor, shape: [1, 3, PlantIDPreprocess.size, PlantIDPreprocess.size]))
        let features = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": MLFeatureValue(multiArray: input)])
        let out = try await model.prediction(from: features)
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw PlantIDFailure.prediction("no embedding output")
        }
        return MLShapedArray<Float>(e).scalars
    }

    static func name(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "CPU only"
        case .cpuAndGPU: "CPU+GPU"
        case .all: "all"
        case .cpuAndNeuralEngine: "CPU+ANE"
        @unknown default: "units \(units.rawValue)"
        }
    }
}

/// Loads the scorer and encoder on demand and identifies photos, all off
/// the main thread. One per open Identify screen.
actor PlantIDEngine {
    let source: PlantIDSource
    private var scorer: PlantIDModel?
    private var encoder: (any PlantEncoding)?
    private var loading: Task<(PlantIDModel, any PlantEncoding), Error>?
    private var busy = 0
    /// Loads running anywhere in the app (the benchmark waits for none).
    nonisolated static let loadsInFlight = Mutex(0)
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")

    init(source: PlantIDSource) { self.source = source }

    var isLoaded: Bool { scorer != nil && encoder != nil }

    /// Loads everything (a no-op when loaded; joins a load in flight).
    @discardableResult
    func prepare() async throws -> (PlantIDModel, any PlantEncoding) {
        if let scorer, let encoder { return (scorer, encoder) }
        if let loading { return try await loading.value }
        let source = source
        let known = scorer
        // utility: the photo picker, the camera and framing come first (an
        // Identify that waits for the load raises its priority by awaiting)
        let task = Task.detached(priority: .utility) { () throws -> (PlantIDModel, any PlantEncoding) in
            Self.loadsInFlight.withLock { $0 += 1 }
            defer { Self.loadsInFlight.withLock { $0 -= 1 } }
            return try await Self.load(source, scorer: known)
        }
        loading = task
        do {
            let pair = try await task.value
            loading = nil
            scorer = pair.0
            encoder = pair.1
            return pair
        } catch {
            loading = nil
            Self.logger.error("load failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Timed (the Diagnostics line): the scorer's files, Core ML's load,
    /// a first prediction (warm-up: the first one carries one-off setup
    /// costs that would otherwise land on her first Identify).
    private static func load(_ source: PlantIDSource, scorer known: PlantIDModel?) async throws -> (PlantIDModel, any PlantEncoding) {
        switch source {
        case let .files(dir):
            let start = ContinuousClock.now
            var mark = start
            var steps: [String] = []
            func step(_ name: String) {
                let now = ContinuousClock.now
                steps.append("\(name) \(Int(((now - mark) / .milliseconds(1)).rounded())) ms")
                mark = now
            }
            let encoderURL = dir.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: encoderURL.appending(path: "coremldata.bin").path(percentEncoded: false))
            else { throw PlantIDFailure.missingFiles }
            guard PlantIDModel.available(in: dir) else { throw PlantIDFailure.missingFiles }
            // complete files only: a model cut short (storage ran out
            // mid-download, yet the system said "downloaded") fails deep in
            // the scorer or Core ML with a baffling error — the store
            // marks the pack unusable instead (a few ms: sizes and blob headers)
            let report = PackVerification.plantID(dir)
            if report.isDamaged {
                Self.logger.error("plant ID files damaged: \(report.summary ?? "", privacy: .public)")
                NotificationCenter.default.post(name: PackVerification.damagedNotification, object: Pack.plantid.rawValue)
                throw PlantIDFailure.damaged(report.summary ?? "")
            }
            step("integrity")
            let scorer: PlantIDModel
            if let known { scorer = known } else {
                do { scorer = try PlantIDModel(directory: dir) } catch {
                    throw PlantIDFailure.model(error.localizedDescription)
                }
                step("scorer")
                let m = scorer.parameters
                Self.logger.info("model: \(scorer.labels.count) classes, T \(m.temperature), ladder \(m.ladder.species) / \(m.ladder.genus)")
            }
            // the app's own copy of the encoder (made on first use of a model)
            let placed = await PlantIDModelCopy.place(dir)
            step("app copy \(placed.note)")
            let units = CoreMLPlantEncoder.defaultUnits
            var location = placed.location
            let encoder: CoreMLPlantEncoder
            do {
                encoder = try await CoreMLPlantEncoder.load(placed.url, units: units)
            } catch where placed.location == .appCopy {
                // a damaged copy: gone (made again next time), the pack's own now
                Self.logger.error("app copy failed to load (\(String(describing: error), privacy: .public)); loading from the pack")
                await PlantIDModelCopy.discard(placed.url)
                encoder = try await CoreMLPlantEncoder.load(encoderURL, units: units)
                location = .pack
            }
            step("Core ML load")
            _ = try? await encoder.embedding(CoreMLPlantEncoder.blank)
            step("warm-up prediction")
            let took = start.duration(to: .now)
            Self.logger.info("loaded in \(took, privacy: .public) from \(location.rawValue, privacy: .public): \(steps.joined(separator: ", "), privacy: .public)")
            PlantIDLoadLog.record(dir: dir, took: took, steps: steps, location: location, units: CoreMLPlantEncoder.name(units))
            Self.logger.info("memory after load: \(MemoryUse.line(), privacy: .public)")
            return (scorer, encoder)
        #if DEBUG
        case let .fake(mode):
            try await Task.sleep(for: .milliseconds(300))
            return try await PlantIDFake.make(mode)
        #endif
        }
    }

    /// The answer for one framed photo.
    func identify(_ image: RGBImage, location: GeoPoint?) async throws -> PlantIDResult {
        busy += 1
        defer { busy -= 1 }
        let (scorer, encoder) = try await prepare()
        let start = ContinuousClock.now
        let tensor = PlantIDPreprocess.tensor(image)
        let pre = start.duration(to: .now)
        let embedding: [Float]
        do { embedding = try await encoder.embedding(tensor) } catch let e as PlantIDFailure { throw e } catch {
            throw PlantIDFailure.prediction(error.localizedDescription)
        }
        guard embedding.count == scorer.dimension, embedding.allSatisfy(\.isFinite) else {
            throw PlantIDFailure.prediction("the model returned \(embedding.count) values")
        }
        let enc = start.duration(to: .now)
        let result = scorer.identify(embedding: embedding, location: location)
        Self.logger.info("identified: preprocess \(pre, privacy: .public), encoder \(enc - pre, privacy: .public), scoring \(start.duration(to: .now) - enc, privacy: .public)")
        return result
    }

    /// The scorer alone (labels for the UI), loading it if needed.
    func labels() async throws -> [PlantIDLabel] { try await prepare().0.labels }

    /// Lets go of the encoder (and the scorer unless `keepScorer`): a
    /// memory warning, or Identify closing. Not while a photo is running.
    func release(keepScorer: Bool = false) {
        guard busy == 0 else { return }
        loading?.cancel()
        loading = nil
        encoder = nil
        if !keepScorer { scorer = nil }
        Self.logger.info("released (scorer kept: \(keepScorer))")
    }
}
