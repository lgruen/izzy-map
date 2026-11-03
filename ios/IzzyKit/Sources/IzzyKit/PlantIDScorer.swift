import Accelerate
import Foundation

// Plant identification scoring: the Swift port of `Ship` in
// pipeline/plantid/build_ship.py (the spec; pipeline.json "steps"). The
// image encoder (Core ML, in the app) turns a photo into a 1024-vector;
// everything after that is here:
//
//   q      = normalise(normalise(embedding) − head.centre)
//   L_head = log_softmax(head.temp · W q)
//   L_knn  = log_softmax(knn_temp · log(P + 1e-6/C)), P = softmax-weighted
//            vote of the k most similar training photos (the bank)
//   L_img  = log_softmax(blend_temp · (L_head + ω · L_knn))
//   L      = log_softmax(L_img + λ · log prior(lat, lon))   (no location: λ = 0)
//
// then the answer ladder: the species when its p ≥ 0.5, else the genus whose
// species sum to ≥ 0.5, else "not sure". Unit tests reproduce Ship's log p
// on the shipped files to ~1e-4 (PlantIDScorerTests).

/// One class of the classifier (labels.json).
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

    enum CodingKeys: String, CodingKey {
        case name, genus, family, inat, un
        case tasRecords = "tas_records"
    }

    public init(name: String, genus: String?, family: String? = nil, un: Profile? = nil) {
        self.name = name
        self.genus = genus
        self.family = family
        self.un = un
    }

    /// The genus the ladder sums over (the name's first word when the table has none).
    public var genusName: String { genus ?? String(name.split(separator: " ").first ?? Substring(name)) }
}

struct PlantIDLabelsFile: Decodable {
    var version: Int
    var count: Int
    var labels: [PlantIDLabel]
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

/// The location prior (prior.bin): pool-record counts on a 2.5 km grid in
/// equirectangular km; at the query point a Gaussian kernel (σ = 5 km, cut
/// at 3σ) sums the counts K, shrunk to the statewide frequency:
/// p(s | place) = (K_s + α f_s) / (Σ K + α) — evaluate.GeoPrior exactly.
public struct PlantIDPrior: Sendable {
    let kmPerDegLon: Double, kmPerDegLat: Double, cellKm: Double
    let x0: Int, y0: Int, nx: Int, ny: Int
    let sigmaKm: Double, radiusSigmas: Double, alpha: Double
    let rowptr: [UInt32]
    let species: [UInt16]
    let count: [UInt16]
    /// f_s = (total_s + 1) / Σ (total + 1)
    let frequency: [Double]

    /// The eval's projection constants (evaluate.project: 111.32 · cos 42° km per degree of longitude).
    public static let kmPerDegLon = 111.32 * cos(-42.0 * Double.pi / 180)
    public static let kmPerDegLat = 110.57

    init(blob: IZPLBlob, labels: Int) throws {
        let name = blob.file.url.lastPathComponent
        func n(_ k: String) throws -> Double {
            guard let v = blob.number(k) else { throw PlantIDError.malformed(name, "no \(k)") }
            return v
        }
        kmPerDegLon = try n("km_per_deg_lon")
        kmPerDegLat = try n("km_per_deg_lat")
        cellKm = try n("cell_km")
        x0 = Int(try n("x0"))
        y0 = Int(try n("y0"))
        nx = Int(try n("nx"))
        ny = Int(try n("ny"))
        sigmaKm = try n("sigma_km")
        radiusSigmas = try n("radius_sigmas")
        alpha = try n("alpha")
        rowptr = Array(try blob.pointer("rowptr", UInt32.self, dtype: "uint32"))
        species = Array(try blob.pointer("species", UInt16.self, dtype: "uint16"))
        count = Array(try blob.pointer("count", UInt16.self, dtype: "uint16"))
        let totals = try blob.pointer("species_total", UInt32.self, dtype: "uint32")
        guard rowptr.count == nx * ny + 1, Int(rowptr.last!) == species.count, count.count == species.count,
              totals.count == labels, species.allSatisfy({ Int($0) < labels })
        else { throw PlantIDError.malformed(name, "grid arrays don't fit together") }
        frequency = Self.frequency(totals.map { Double($0) })
    }

    /// A synthetic prior (tests, DEBUG fakes): records binned exactly like
    /// build_ship.write_prior (σ 5 km, α 32).
    public init(records: [(latitude: Double, longitude: Double, label: Int)], labels: Int) {
        let g = 2.5
        kmPerDegLon = Self.kmPerDegLon
        kmPerDegLat = Self.kmPerDegLat
        cellKm = g
        sigmaKm = 5
        radiusSigmas = 3
        alpha = 32
        let kx = Self.kmPerDegLon, ky = Self.kmPerDegLat
        let cells = records.map { (Int((($0.longitude * kx) / g).rounded(.down)),
                                   Int((($0.latitude * ky) / g).rounded(.down)), $0.label) }
        x0 = cells.map(\.0).min() ?? 0
        y0 = cells.map(\.1).min() ?? 0
        nx = (cells.map(\.0).max() ?? 0) - x0 + 1
        ny = (cells.map(\.1).max() ?? 0) - y0 + 1
        var perCell: [Int: [Int: Int]] = [:]
        var totals = [Double](repeating: 0, count: labels)
        for (x, y, l) in cells {
            perCell[(y - y0) * nx + (x - x0), default: [:]][l, default: 0] += 1
            totals[l] += 1
        }
        var rowptr: [UInt32] = [0]
        var species: [UInt16] = [], count: [UInt16] = []
        for cell in 0 ..< nx * ny {
            for (l, c) in (perCell[cell] ?? [:]).sorted(by: { $0.key < $1.key }) {
                species.append(UInt16(l))
                count.append(UInt16(c))
            }
            rowptr.append(UInt32(species.count))
        }
        self.rowptr = rowptr
        self.species = species
        self.count = count
        frequency = Self.frequency(totals)
    }

    static func frequency(_ totals: [Double]) -> [Double] {
        let t = totals.map { $0 + 1 }
        let sum = t.reduce(0, +)
        return t.map { $0 / sum }
    }

    var radiusKm: Double { radiusSigmas * sigmaKm }

    /// Whether the point's kernel reaches the grid at all (Tasmania and its
    /// islands). Elsewhere the prior would be the statewide frequency alone.
    public func covers(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        let qx = longitude * kmPerDegLon, qy = latitude * kmPerDegLat
        let minX = Double(x0) * cellKm, maxX = Double(x0 + nx) * cellKm
        let minY = Double(y0) * cellKm, maxY = Double(y0 + ny) * cellKm
        let dx = max(minX - qx, 0, qx - maxX), dy = max(minY - qy, 0, qy - maxY)
        return dx * dx + dy * dy <= radiusKm * radiusKm
    }

    /// Visits every grid cell whose centre lies within `radius` km of the
    /// point: (row index, squared distance in km²).
    private func cells(latitude: Double, longitude: Double, radius r: Double, _ body: (Int, Double) -> Void) {
        let g = cellKm
        let qx = longitude * kmPerDegLon, qy = latitude * kmPerDegLat
        let w = Int((r / g).rounded(.up)) + 1
        let cx = Int((qx / g).rounded(.down)), cy = Int((qy / g).rounded(.down))
        for dy in -w ... w {
            for dx in -w ... w {
                let x = cx + dx, y = cy + dy
                let ddx = (Double(x) + 0.5) * g - qx, ddy = (Double(y) + 0.5) * g - qy
                let d2 = ddx * ddx + ddy * ddy
                let ix = x - x0, iy = y - y0
                guard d2 <= r * r, ix >= 0, ix < nx, iy >= 0, iy < ny else { continue }
                body(iy * nx + ix, d2)
            }
        }
    }

    /// log p(label | place) for every label.
    public func logPrior(latitude: Double, longitude: Double) -> [Double] {
        var K = [Double](repeating: 0, count: frequency.count)
        let s2 = 2 * sigmaKm * sigmaKm
        cells(latitude: latitude, longitude: longitude, radius: radiusKm) { row, d2 in
            let w = exp(-d2 / s2)
            for j in Int(rowptr[row]) ..< Int(rowptr[row + 1]) { K[Int(species[j])] += w * Double(count[j]) }
        }
        let denominator = K.reduce(0, +) + alpha
        return zip(K, frequency).map { log(($0 + alpha * $1) / denominator) }
    }

    /// Pool records per label in the cells whose centre is within `km` of
    /// the point (the 2.5 km cells make the edge ±1.8 km).
    public func records(within km: Double, latitude: Double, longitude: Double) -> [Int: Int] {
        var out: [Int: Int] = [:]
        cells(latitude: latitude, longitude: longitude, radius: km) { row, _ in
            for j in Int(rowptr[row]) ..< Int(rowptr[row + 1]) { out[Int(species[j]), default: 0] += Int(count[j]) }
        }
        return out
    }
}

/// What the identifier says about one photo.
public struct PlantIDResult: Sendable, Equatable {
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
        /// Pool records of this label within ~5 km of the photo (0 without a location).
        public let nearbyRecords: Int
        public var id: Int { label }
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
}

/// Scores encoder embeddings against the shipped head, bank and prior.
public final class PlantIDScorer: @unchecked Sendable {
    public static let ladderSpecies = 0.5
    public static let ladderGenus = 0.5
    /// "Recorded within 5 km" (σ of the prior).
    public static let nearbyKm = 5.0

    public let labels: [PlantIDLabel]
    public let dimension: Int
    let weight: [Float]  // C × D
    let centre: [Float]
    let headTemp: Double
    let bank: PlantIDBank?
    public let scoring: PlantIDScoring
    let prior: PlantIDPrior?
    let genusOf: [Int]
    let genusNames: [String]

    /// The pack's files: head.bin, `bank`, prior.bin and labels.json in `directory`.
    public convenience init(directory: URL, bank: String = "bank-int8.bin") throws {
        try self.init(head: directory.appending(path: "head.bin"), bank: directory.appending(path: bank),
                      prior: directory.appending(path: "prior.bin"), labels: directory.appending(path: "labels.json"))
    }

    public convenience init(head: URL, bank: URL, prior: URL, labels: URL) throws {
        let file: PlantIDLabelsFile
        do { file = try JSONDecoder().decode(PlantIDLabelsFile.self, from: Data(contentsOf: labels, options: .mappedIfSafe)) }
        catch { throw PlantIDError.malformed("labels.json", String(describing: error)) }
        guard file.version == 1, file.labels.count == file.count else { throw PlantIDError.malformed("labels.json", "version/count") }
        let h = try IZPLBlob(url: head)
        guard let w = h.arrays["weight"], w.shape.count == 2, w.shape[0] == file.count, let temp = h.number("temp")
        else { throw PlantIDError.malformed("head.bin", "weight isn't labels × dimension") }
        let D = w.shape[1]
        let centre = try h.floats("centre")
        guard centre.count == D else { throw PlantIDError.malformed("head.bin", "centre ≠ dimension") }
        let b = try IZPLBlob(url: bank)
        let scoring = try PlantIDScoring(header: b.header)
        let theBank = scoring.headOnly ? nil : try PlantIDBank(blob: b, dimension: D)
        if let theBank, theBank.labels.contains(where: { Int($0) >= file.count }) {
            throw PlantIDError.malformed(bank.lastPathComponent, "label out of range")
        }
        let p = try PlantIDPrior(blob: IZPLBlob(url: prior), labels: file.count)
        self.init(labels: file.labels, weight: try h.floats("weight"), centre: centre, headTemp: temp,
                  bank: theBank, scoring: scoring, prior: p)
    }

    /// Everything given (tests, DEBUG fakes). `weight` = labels × dimension.
    public init(labels: [PlantIDLabel], weight: [Float], centre: [Float], headTemp: Double,
                bank: PlantIDBank?, scoring: PlantIDScoring, prior: PlantIDPrior?) {
        precondition(weight.count == labels.count * centre.count, "weight must be labels × dimension")
        self.labels = labels
        dimension = centre.count
        self.weight = weight
        self.centre = centre
        self.headTemp = headTemp
        self.bank = scoring.headOnly ? nil : bank
        self.scoring = scoring
        self.prior = prior
        var names: [String: Int] = [:]
        var order: [String] = []
        genusOf = labels.map { label in
            let g = label.genusName
            if let i = names[g] { return i }
            names[g] = order.count
            order.append(g)
            return order.count - 1
        }
        genusNames = order
    }

    // MARK: Steps

    /// q = normalise(normalise(embedding) − centre).
    public func query(_ embedding: [Float]) -> [Float] {
        func unit(_ v: [Float]) -> [Float] {
            let n = Float(sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) }))
            return n > 0 ? v.map { $0 / n } : v
        }
        let e = unit(embedding)
        return unit(zip(e, centre).map { $0 - $1 })
    }

    static func logSoftmax(_ z: [Double]) -> [Double] {
        guard let m = z.max(), m.isFinite else { return z }
        let s = z.reduce(0.0) { $0 + exp($1 - m) }
        let l = log(s)
        return z.map { $0 - m - l }
    }

    func headLogp(_ q: [Float]) -> [Double] {
        let C = labels.count
        var out = [Float](repeating: 0, count: C)
        weight.withUnsafeBufferPointer { w in
            q.withUnsafeBufferPointer { qp in
                vDSP_mmul(w.baseAddress!, 1, qp.baseAddress!, 1, &out, 1, vDSP_Length(C), 1, vDSP_Length(dimension))
            }
        }
        return Self.logSoftmax(out.map { headTemp * Double($0) })
    }

    func knnLogp(_ q: [Float], bank: PlantIDBank) -> [Double] {
        let C = labels.count
        let nb = bank.neighbours(q, dimension: dimension, k: scoring.k)
        var P = [Double](repeating: 0, count: C)
        if let s0 = nb.first?.0 {
            for (s, row) in nb {
                var w = exp(Double(s - s0) / scoring.tau)
                if let weight = bank.weight, scoring.rho != 0 { w *= pow(Double(weight[row]), scoring.rho) }
                P[Int(bank.labels[row])] += w
            }
        }
        let total = P.reduce(0, +)
        let floor = 1e-6 / Double(C)
        return Self.logSoftmax(P.map { scoring.knnTemp * log((total > 0 ? $0 / total : 0) + floor) })
    }

    /// L_img: the photo alone (head ⊕ kNN).
    public func imageLogp(_ q: [Float]) -> [Double] {
        let head = headLogp(q)
        guard let bank, !scoring.headOnly else { return head }
        let knn = knnLogp(q, bank: bank)
        return Self.logSoftmax(zip(head, knn).map { scoring.blendTemp * ($0 + scoring.omega * $1) })
    }

    /// Final log p over the labels; `location` nil = no prior (λ = 0).
    public func logProbabilities(embedding: [Float], location: GeoPoint?) -> [Double] {
        precondition(embedding.count == dimension, "embedding must have \(dimension) values")
        let L = imageLogp(query(embedding))
        guard let location, let prior, scoring.lam != 0 else { return Self.logSoftmax(L) }
        let lp = prior.logPrior(latitude: location.latitude, longitude: location.longitude)
        return Self.logSoftmax(zip(L, lp).map { $0 + scoring.lam * $1 })
    }

    /// Whether a location takes part: within reach of the prior's grid.
    public func usesLocation(_ location: GeoPoint?) -> Bool {
        guard let location, let prior, scoring.lam != 0 else { return false }
        return prior.covers(latitude: location.latitude, longitude: location.longitude)
    }

    // MARK: Answer

    /// The answer ladder and the top 5 for one photo. A location beyond the
    /// prior's grid (outside Tasmania) is ignored: the prior there would be
    /// the statewide frequency alone, which says nothing about the place.
    public func identify(embedding: [Float], location: GeoPoint?) -> PlantIDResult {
        let place = usesLocation(location) ? location : nil
        let logp = logProbabilities(embedding: embedding, location: place)
        return result(logp: logp, location: place)
    }

    func result(logp: [Double], location: GeoPoint?) -> PlantIDResult {
        let p = logp.map { exp($0) }
        let order = p.indices.sorted { p[$0] > p[$1] }
        let nearby = location.flatMap { l in
            prior?.records(within: Self.nearbyKm, latitude: l.latitude, longitude: l.longitude)
        } ?? [:]
        func candidate(_ i: Int) -> PlantIDResult.Candidate {
            .init(label: i, p: p[i], nearbyRecords: nearby[i] ?? 0)
        }
        var genusP = [Double](repeating: 0, count: genusNames.count)
        for (i, v) in p.enumerated() { genusP[genusOf[i]] += v }
        let answer: PlantIDResult.Answer
        if let best = order.first, p[best] >= Self.ladderSpecies {
            answer = .species(label: best, p: p[best])
        } else if let g = genusP.indices.max(by: { genusP[$0] < genusP[$1] }), genusP[g] >= Self.ladderGenus {
            answer = .genus(genusNames[g], p: genusP[g])
        } else {
            answer = .notSure
        }
        let top = order.prefix(5).map(candidate)
        // the genera worth drawing: those of the top 5, each with its leading species
        var seen: [Int] = []
        for c in top where !seen.contains(genusOf[c.label]) { seen.append(genusOf[c.label]) }
        let genera = seen.map { g in
            PlantIDResult.GenusShare(name: genusNames[g], p: genusP[g],
                                     species: order.lazy.filter { self.genusOf[$0] == g }.prefix(6).map(candidate))
        }.sorted { $0.p > $1.p }
        return PlantIDResult(answer: answer, candidates: top, genera: genera, usedLocation: location != nil)
    }
}
