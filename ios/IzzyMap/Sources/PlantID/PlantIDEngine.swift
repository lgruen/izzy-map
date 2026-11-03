import CoreML
import Foundation
import IzzyKit
import os

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
    case model(String)
    case prediction(String)

    var errorDescription: String? {
        switch self {
        case .missingFiles: "The identification model’s files aren’t complete on this device."
        case let .model(why): "The identification model couldn’t be loaded (\(why))."
        case let .prediction(why): "The photo couldn’t be identified (\(why))."
        }
    }
}

/// The Core ML image encoder (BioCLIP 2.5, 8-bit weights), compute units
/// ALL (Neural Engine where it can). Loaded on first use, released by its
/// owner when Identify closes or memory runs short: the model holds ~0.4 GB
/// of app memory once loaded.
nonisolated final class CoreMLPlantEncoder: PlantEncoding, @unchecked Sendable {
    let model: MLModel

    static func load(_ url: URL) async throws -> CoreMLPlantEncoder {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            return CoreMLPlantEncoder(model: try await MLModel.load(contentsOf: url, configuration: config))
        } catch {
            throw PlantIDFailure.model(error.localizedDescription)
        }
    }

    private init(model: MLModel) { self.model = model }

    func embedding(_ tensor: [Float]) async throws -> [Float] {
        let input = MLMultiArray(MLShapedArray<Float>(scalars: tensor, shape: [1, 3, PlantIDPreprocess.size, PlantIDPreprocess.size]))
        let features = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": MLFeatureValue(multiArray: input)])
        let out = try await model.prediction(from: features)
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw PlantIDFailure.prediction("no embedding output")
        }
        return MLShapedArray<Float>(e).scalars
    }
}

/// Loads the scorer and encoder on demand and identifies photos, all off
/// the main thread. One per open Identify screen.
actor PlantIDEngine {
    let source: PlantIDSource
    private var scorer: PlantIDScorer?
    private var encoder: (any PlantEncoding)?
    private var loading: Task<(PlantIDScorer, any PlantEncoding), Error>?
    private var busy = 0
    nonisolated private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "PlantID")

    init(source: PlantIDSource) { self.source = source }

    var isLoaded: Bool { scorer != nil && encoder != nil }

    /// Loads everything (a no-op when loaded; joins a load in flight).
    @discardableResult
    func prepare() async throws -> (PlantIDScorer, any PlantEncoding) {
        if let scorer, let encoder { return (scorer, encoder) }
        if let loading { return try await loading.value }
        let source = source
        let known = scorer
        let task = Task.detached(priority: .userInitiated) { () throws -> (PlantIDScorer, any PlantEncoding) in
            let start = ContinuousClock.now
            let pair = try await Self.load(source, scorer: known)
            Self.logger.info("loaded in \(start.duration(to: .now), privacy: .public)")
            return pair
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

    private static func load(_ source: PlantIDSource, scorer known: PlantIDScorer?) async throws -> (PlantIDScorer, any PlantEncoding) {
        switch source {
        case let .files(dir):
            let encoderURL = dir.appending(path: PlantIDFiles.encoder, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: encoderURL.appending(path: "coremldata.bin").path(percentEncoded: false))
            else { throw PlantIDFailure.missingFiles }
            let scorer: PlantIDScorer
            if let known { scorer = known } else {
                do { scorer = try PlantIDScorer(directory: dir, bank: PlantIDFiles.bank) } catch {
                    throw PlantIDFailure.model(error.localizedDescription)
                }
            }
            return (scorer, try await CoreMLPlantEncoder.load(encoderURL))
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
