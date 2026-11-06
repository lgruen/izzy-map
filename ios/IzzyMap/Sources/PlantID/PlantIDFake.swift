#if DEBUG
import Foundation
import IzzyKit

/// DEBUG `-plantIDFake <species|genus|unsure|mainland>`: identification
/// without the 0.7 GB model, for UI tests and screenshots — a synthetic
/// single model over eight real UN species and two mainland natives the
/// guide doesn't have, and an encoder that ignores the photo and returns
/// the embedding giving the mode's answer. Records around Hobart mark some
/// "recorded within 10 km".
nonisolated enum PlantIDFake {
    struct Encoder: PlantEncoding {
        let embedding: [Float]
        func embedding(_ tensor: [Float]) async throws -> [Float] {
            precondition(tensor.count == 3 * 224 * 224)
            return embedding
        }
    }

    static let names: [(String, String)] = [
        ("Acacia dealbata", "Acacia"), ("Eucalyptus amygdalina", "Eucalyptus"),
        ("Eucalyptus pulchella", "Eucalyptus"), ("Eucalyptus viminalis", "Eucalyptus"),
        ("Eucalyptus nitens", "Eucalyptus"), ("Banksia marginata", "Banksia"),
        ("Leptospermum scoparium", "Leptospermum"), ("Acacia melanoxylon", "Acacia"),
        ("Eucalyptus melliodora", "Eucalyptus"), ("Eucalyptus sideroxylon", "Eucalyptus"),
    ]

    /// The answer each mode should give, as probabilities in `names` order.
    static func target(_ mode: String) -> [Double] {
        switch mode {
        case "genus": [0.04, 0.36, 0.22, 0.12, 0.08, 0.06, 0.07, 0.05, 0.03, 0.02]
        case "unsure": [0.28, 0.12, 0.06, 0.04, 0.03, 0.22, 0.17, 0.08, 0.02, 0.01]
        case "mainland": [0.02, 0.03, 0.02, 0.03, 0.02, 0.01, 0.01, 0.02, 0.8, 0.06]
        default: [0.78, 0.04, 0.03, 0.02, 0.01, 0.03, 0.02, 0.07, 0.01, 0.01]
        }
    }

    /// `-plantIDFakeMainland "Genus species,Genus species"`: the two
    /// mainland natives' names (screenshots of particular reference photos).
    static var effectiveNames: [(String, String)] {
        var n = names
        let extra = (UserDefaults.standard.string(forKey: "plantIDFakeMainland") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (k, name) in extra.prefix(2).enumerated() { n[8 + k] = (name, String(name.split(separator: " ").first ?? "")) }
        return n
    }

    /// The shipped model's ladder (pipeline.json `v3.scoring.ladder`, the
    /// final sweep — 2026-11-06), so screenshots show the lines in force:
    /// species 50 / 50 / 50 / 75 % by the named class's training photos,
    /// genus 50 %.
    static let ladder = PlantIDLadder(species: [0.5, 0.5, 0.5, 0.75], bucketEdges: [0, 10, 50], genus: 0.5)

    static func make(_ mode: String) async throws -> (PlantIDModel, any PlantEncoding) {
        let catalog = await PlantLibrary.shared.load()
        let labels = effectiveNames.enumerated().map { i, pair in
            let (name, genus) = pair
            let plant = catalog?.plant(for: name)
            var l = PlantIDLabel(name: name, genus: genus, family: plant?.family ?? "Myrtaceae",
                                 un: plant.map { PlantIDLabel.Profile(key: name, ids: [$0.id], match: nil) })
            l.trainPhotos = 30   // ladder v3's 10–49 bucket: named at 50 %
            if plant == nil, i >= 8, names[i].0 == name { l.common = i == 8 ? "yellow box" : "red ironbark" }
            if plant == nil { l.inat = 1000 + i }
            if plant != nil { l.ship = i }
            return l
        }
        let C = labels.count
        // logits = norm · q with q unit: q ∝ log p − min + 1
        let p = target(mode)
        let l = p.map { log($0) }
        let shifted = l.map { $0 - l.min()! + 1 }
        let norm = sqrt(shifted.reduce(0) { $0 + $1 * $1 })
        let embedding = shifted.map { Float($0 / norm) }
        var weight = [Float](repeating: 0, count: C * C)
        for i in 0 ..< C { weight[i * C + i] = Float(norm) }
        // records within a few km of Hobart for three of the labels
        var records: [(latitude: Double, longitude: Double, label: Int)] = []
        for (label, n) in [(0, 6), (1, 4), (6, 2)] {
            for i in 0 ..< n { records.append((-42.88 + 0.004 * Double(i), 147.32 + 0.003 * Double(i), label)) }
        }
        let params = PlantIDModelParameters(temperature: 1, lam: 0.02, prior: .init(transform: .log1p, sigmaKm: 10, alpha: 64),
                                            ladder: Self.ladder)
        let model = PlantIDModel(labels: labels, weight: weight, centre: [Float](repeating: 0, count: C),
                                 parameters: params, prior: PlantIDDegPrior(records: records, labels: C))
        return (model, Encoder(embedding: embedding))
    }
}
#endif
