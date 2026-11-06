import Accelerate
import Foundation

// Plant identification's shared types: a class (PlantIDLabel), the
// Tasmanian photo bank the single model uses inside the Tasmania box
// (PlantIDBank + its header's PlantIDScoring) and the answer
// (PlantIDResult). The scorer itself is PlantIDModel.

/// One class of the classifier (v2-labels.json).
public struct PlantIDLabel: Decodable, Sendable, Hashable {
    public struct Profile: Decodable, Sendable, Hashable {
        /// plants.json `species`: the PlantCatalog key of its UN profile.
        public var key: String
        /// plants.json ids (several when UN splits the species).
        public var ids: [Int]
        /// "spelling" when matched by a spelling variant (lawrencei → lawrencii).
        public var match: String?

        public init(key: String, ids: [Int], match: String? = nil) {
            self.key = key
            self.ids = ids
            self.match = match
        }
    }

    public var name: String
    public var genus: String?
    public var family: String?
    /// iNaturalist taxon id.
    public var inat: Int?
    /// Records in the prior's pool.
    public var tasRecords: Int?
    /// The Understorey Network profile, when there is one.
    public var un: Profile?
    /// The row of the Tasmanian label table (the 2,675 classes of the
    /// Tasmania-first training and the photo bank) this class is, or nil
    /// (a mainland class).
    public var ship: Int? = nil
    /// A common name from the label table (iNaturalist's, place Australia;
    /// the UN profile's is used first).
    public var common: String? = nil
    /// Training photos of the class (the ladder's bucket).
    public var trainPhotos: Int? = nil
    /// Native to Australia.
    public var native: Bool? = nil
    /// The APC name, where the Tasmanian label's spelling is shown instead.
    public var apcName: String? = nil
    /// A twin merged into this class at training: never named.
    public var mergedInto: Int? = nil

    enum CodingKeys: String, CodingKey {
        case name, genus, family, inat, un, common, ship, native
        case tasRecords = "tas_records"
        case trainPhotos = "photos"
        case apcName = "apc_name"
        case mergedInto = "merged_into"
    }

    public init(name: String, genus: String?, family: String? = nil, un: Profile? = nil) {
        self.name = name
        self.genus = genus
        self.family = family
        self.un = un
    }

    /// One of Tasmania's labels (it has a `ship` row).
    public var isTasmanian: Bool { ship != nil }

    /// The genus the ladder sums over (the name's first word when the table has none).
    public var genusName: String { genus ?? String(name.split(separator: " ").first ?? Substring(name)) }
}

/// The bank's kNN parameters and the prior weight (each bank's header
/// `scoring`, chosen on the validation set by build_ship.py).
public struct PlantIDScoring: Sendable, Equatable {
    public var k: Int
    public var tau: Double
    public var rho: Double
    public var knnTemp: Double
    public var omega: Double
    public var blendTemp: Double
    /// Prior weight λ (0 when there is no location).
    public var lam: Double
    /// No kNN: head (+ prior) only.
    public var headOnly: Bool

    public init(k: Int = 50, tau: Double = 0.05, rho: Double = 0, knnTemp: Double = 1, omega: Double = 0.5,
                blendTemp: Double = 1, lam: Double = 0.5, headOnly: Bool = false) {
        self.k = k
        self.tau = tau
        self.rho = rho
        self.knnTemp = knnTemp
        self.omega = omega
        self.blendTemp = blendTemp
        self.lam = lam
        self.headOnly = headOnly
    }

    init(header: [String: Any]) throws {
        guard let s = header["scoring"] as? [String: Any] else { throw PlantIDError.malformed("bank", "no scoring") }
        func num(_ k: String, _ fallback: Double? = nil) throws -> Double {
            if let v = (s[k] as? NSNumber)?.doubleValue { return v }
            if let fallback { return fallback }
            throw PlantIDError.malformed("bank", "scoring has no \(k)")
        }
        headOnly = (s["head_only"] as? NSNumber)?.boolValue ?? false
        lam = try num("lam")
        if headOnly {
            k = 0; tau = 1; rho = 0; knnTemp = 1; omega = 0; blendTemp = 1
        } else {
            k = Int(try num("k"))
            tau = try num("tau")
            rho = try num("rho", 0)
            knnTemp = try num("knn_temp")
            omega = try num("omega")
            blendTemp = try num("blend_temp")
        }
    }
}

/// The kNN bank: centred, unit-length training-photo embeddings and their labels.
public struct PlantIDBank: @unchecked Sendable {
    enum Vectors {
        /// int8 per-row symmetric: similarity = scale[row] · (q · v)
        case int8(UnsafeBufferPointer<Int8>, scale: [Float])
        case float16(UnsafeBufferPointer<Float16>)
        case float32([Float])
    }

    let vectors: Vectors
    let labels: [UInt16]
    /// Photos per row (prototype banks), for the weight^ρ factor.
    let weight: [Float]?
    public let rows: Int
    let blob: IZPLBlob?

    /// A synthetic bank (tests, DEBUG fakes): `vectors` = rows × dimension.
    public init(vectors: [Float], labels: [Int], weight: [Float]? = nil) {
        self.vectors = .float32(vectors)
        self.labels = labels.map { UInt16($0) }
        self.weight = weight
        rows = labels.count
        blob = nil
    }

    init(blob: IZPLBlob, dimension: Int) throws {
        let name = blob.file.url.lastPathComponent
        guard let info = blob.arrays["vectors"], info.shape.count == 2, info.shape[1] == dimension || info.shape[0] == 0
        else { throw PlantIDError.malformed(name, "vectors aren't rows × \(dimension)") }
        rows = info.shape[0]
        switch info.dtype {
        case "int8":
            vectors = .int8(try blob.pointer("vectors", Int8.self, dtype: "int8"), scale: try blob.floats("scale"))
        case "float16":
            vectors = .float16(try blob.pointer("vectors", Float16.self, dtype: "float16"))
        case "float32":
            vectors = .float32(Array(try blob.pointer("vectors", Float.self, dtype: "float32")))
        default:
            throw PlantIDError.malformed(name, "vectors are \(info.dtype)")
        }
        labels = Array(try blob.pointer("labels", UInt16.self, dtype: "uint16"))
        weight = blob.arrays["weight"] == nil ? nil : try blob.floats("weight")
        guard labels.count == rows else { throw PlantIDError.malformed(name, "labels ≠ rows") }
        self.blob = blob
    }

    /// The k most similar rows to `q`, best first: (similarity, row).
    func neighbours(_ q: [Float], dimension D: Int, k: Int) -> [(Float, Int)] {
        let k = min(k, rows)
        guard k > 0 else { return [] }
        var sims = [Float](repeating: 0, count: rows)
        let chunk = 2048
        var buffer = [Float](repeating: 0, count: min(chunk, rows) * D)
        sims.withUnsafeMutableBufferPointer { out in
            q.withUnsafeBufferPointer { qp in
                switch vectors {
                case let .float32(v):
                    v.withUnsafeBufferPointer { vp in
                        vDSP_mmul(vp.baseAddress!, 1, qp.baseAddress!, 1, out.baseAddress!, 1,
                                  vDSP_Length(rows), 1, vDSP_Length(D))
                    }
                case let .int8(v, scale):
                    buffer.withUnsafeMutableBufferPointer { b in
                        var r0 = 0
                        while r0 < rows {
                            let n = min(chunk, rows - r0)
                            vDSP_vflt8(v.baseAddress! + r0 * D, 1, b.baseAddress!, 1, vDSP_Length(n * D))
                            vDSP_mmul(b.baseAddress!, 1, qp.baseAddress!, 1, out.baseAddress! + r0, 1,
                                      vDSP_Length(n), 1, vDSP_Length(D))
                            r0 += n
                        }
                    }
                    scale.withUnsafeBufferPointer { sp in
                        vDSP_vmul(out.baseAddress!, 1, sp.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(rows))
                    }
                case let .float16(v):
                    buffer.withUnsafeMutableBufferPointer { b in
                        var r0 = 0
                        while r0 < rows {
                            let n = min(chunk, rows - r0)
                            let src = v.baseAddress! + r0 * D
                            for i in 0 ..< n * D { b[i] = Float(src[i]) }
                            vDSP_mmul(b.baseAddress!, 1, qp.baseAddress!, 1, out.baseAddress! + r0, 1,
                                      vDSP_Length(n), 1, vDSP_Length(D))
                            r0 += n
                        }
                    }
                }
            }
        }
        return Self.top(sims, k)
    }

    /// The k largest values with their indices, largest first.
    static func top(_ values: [Float], _ k: Int) -> [(Float, Int)] {
        var best: [(Float, Int)] = []
        best.reserveCapacity(k + 1)
        var floor = -Float.infinity
        for (i, v) in values.enumerated() where best.count < k || v > floor {
            // insertion into a short sorted list (k ≈ 50)
            var lo = 0, hi = best.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if best[mid].0 >= v { lo = mid + 1 } else { hi = mid }
            }
            best.insert((v, i), at: lo)
            if best.count > k { best.removeLast() }
            if best.count == k { floor = best[k - 1].0 }
        }
        return best
    }
}

/// What the identifier says about one photo.
public struct PlantIDResult: Sendable, Equatable {
    /// A species bar's line when nothing else is known.
    public static let defaultThreshold = 0.5

    public enum Answer: Sendable, Equatable {
        /// One species at p ≥ 0.5.
        case species(label: Int, p: Double)
        /// No species reaches 0.5, but this genus's species together do.
        case genus(String, p: Double)
        case notSure
    }

    public struct Candidate: Sendable, Equatable, Identifiable {
        public let label: Int
        public let p: Double
        /// Records of this label near the photo (`nearbyKm`; 0 without a location).
        public let nearbyRecords: Int
        /// Where the ladder would name this class a species (its bucket's threshold).
        public var threshold: Double = PlantIDResult.defaultThreshold
        public var id: Int { label }

        public init(label: Int, p: Double, nearbyRecords: Int, threshold: Double = PlantIDResult.defaultThreshold) {
            self.label = label
            self.p = p
            self.nearbyRecords = nearbyRecords
            self.threshold = threshold
        }
    }

    /// A genus among the candidates: its summed p and its species' shares, largest first.
    public struct GenusShare: Sendable, Equatable, Identifiable {
        public let name: String
        public let p: Double
        public let species: [Candidate]
        public var id: String { name }
    }

    public let answer: Answer
    /// The top 5, best first.
    public let candidates: [Candidate]
    /// The genera of the top candidates (summed over EVERY label), largest first.
    public let genera: [GenusShare]
    /// The location prior took part (a location within reach of the grid).
    public let usedLocation: Bool

    /// Which model answered.
    public enum Scope: Sendable, Equatable {
        /// The single model inside the Tasmania box (with the Tasmanian photo bank).
        case tasmania
        /// The single model elsewhere in Australia, or without a location.
        case australia
    }

    public var scope: Scope = .australia
    /// What "nearby" means for `Candidate.nearbyRecords` (km).
    public var nearbyKm: Double = PlantIDModel.nearbyKm
    /// The ladder this answer was read with (the genus bars' line).
    public var ladder: PlantIDLadder = .simple
    /// A genus answer: its top 3 species, best first (else empty).
    public var genusSpecies: [Candidate] = []
    /// How many classes have records near the location (the area
    /// `Candidate.nearbyRecords` counts): 0 = none, or no location — then
    /// "recorded nearby" can't be what ranked them.
    public var nearbySpecies = 0
    /// The location prior's kernel σ at the photo's place (km; the adaptive
    /// prior's cell: a few km where records are dense, up to 20 km where
    /// sparse), nil without a location.
    public var priorSigmaKm: Double? = nil

    /// The sentence tail under the results. Claims only the radius actually
    /// counted (`nearbyKm`, the same as the candidates' "Recorded within" badge),
    /// never the prior's kernel σ.
    public var locationEffect: String {
        let km = Int(nearbyKm.rounded())
        return nearbySpecies > 0 ? "plants recorded within \(km) km rank higher."
            : "no plants are recorded within \(km) km, so the photo and records further afield decide."
    }

    public init(answer: Answer, candidates: [Candidate], genera: [GenusShare], usedLocation: Bool,
                scope: Scope = .australia, nearbyKm: Double = PlantIDModel.nearbyKm,
                ladder: PlantIDLadder = .simple, genusSpecies: [Candidate] = [], nearbySpecies: Int = 0,
                priorSigmaKm: Double? = nil) {
        self.answer = answer
        self.candidates = candidates
        self.genera = genera
        self.usedLocation = usedLocation
        self.scope = scope
        self.nearbyKm = nearbyKm
        self.ladder = ladder
        self.genusSpecies = genusSpecies
        self.nearbySpecies = nearbySpecies
        self.priorSigmaKm = priorSigmaKm
    }
}
