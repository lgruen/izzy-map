#if DEBUG
import Foundation
import IzzyKit

/// DEBUG `-plantIDFake <species|genus|unsure>`: identification without the
/// 0.7 GB model, for UI tests and screenshots — a synthetic head-only scorer
/// over eight real UN species (plus one without a profile) and an encoder
/// that ignores the photo and returns the embedding giving the mode's
/// answer. A prior with records around Hobart marks some "recorded within
/// 5 km".
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
    ]

    /// The answer each mode should give, as probabilities in `names` order.
    static func target(_ mode: String) -> [Double] {
        switch mode {
        case "genus": [0.04, 0.36, 0.22, 0.12, 0.08, 0.06, 0.07, 0.05]
        case "unsure": [0.28, 0.12, 0.06, 0.04, 0.03, 0.22, 0.17, 0.08]
        default: [0.78, 0.04, 0.03, 0.02, 0.01, 0.03, 0.02, 0.07]
        }
    }

    static func make(_ mode: String) async throws -> (PlantIDScorer, any PlantEncoding) {
        let catalog = await PlantLibrary.shared.load()
        let labels = names.map { name, genus in
            let plant = catalog?.plant(for: name)
            return PlantIDLabel(name: name, genus: genus, family: plant?.family,
                                un: plant.map { PlantIDLabel.Profile(key: name, ids: [$0.id], match: nil) })
        }
        let C = labels.count
        var weight = [Float](repeating: 0, count: C * C)
        for i in 0 ..< C { weight[i * C + i] = 1 }
        // logits = temp · q with q unit: q ∝ log p − min + 1, temp = its norm
        let p = target(mode)
        let l = p.map { log($0) }
        let shifted = l.map { $0 - l.min()! + 1 }
        let norm = sqrt(shifted.reduce(0) { $0 + $1 * $1 })
        let embedding = shifted.map { Float($0 / norm) }
        // records within a few km of Hobart for three of the labels
        var records: [(latitude: Double, longitude: Double, label: Int)] = []
        for (label, n) in [(0, 6), (1, 4), (6, 2)] {
            for i in 0 ..< n { records.append((-42.88 + 0.004 * Double(i), 147.32 + 0.003 * Double(i), label)) }
        }
        let scorer = PlantIDScorer(labels: labels, weight: weight, centre: [Float](repeating: 0, count: C),
                                   headTemp: norm, bank: nil, scoring: PlantIDScoring(lam: 0.05, headOnly: true),
                                   prior: PlantIDPrior(records: records, labels: C))
        return (scorer, Encoder(embedding: embedding))
    }
}
#endif
