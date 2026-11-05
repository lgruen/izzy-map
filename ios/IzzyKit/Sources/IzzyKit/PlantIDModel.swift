import Accelerate
import Foundation

// The single Australia-wide plant identifier (v2): the Swift port of
// `V2Ship` in pipeline/plantid/build_ship.py (the spec; v2-head.bin's
// header `recipe`, pipeline.json "v2"). 22,122 classes (v2-labels.json):
// Tasmania's labels and the Australian natives in ONE trained head; 19
// merged twins carry a −1e4 bias and are never named.
//
//   q      = normalise(normalise(embedding) − centre)
//   L_head = log_softmax(scale ⊙ (W q) + bias)                    int8 rows
//   prior  = log((K + α f) / (ΣK + α)), K[c] = Σ t(count)·exp(−d²/2σ²)
//            over the grid cells within 3σ (v2-prior.bin); no location:
//            K = 0, i.e. log f — the country-wide frequency
//   L      = log_softmax(log_softmax(L_head + λ · prior) / T)
//
// Inside the Tasmania box the dense Tasmanian photo bank joins in
// (tas_gap.py F5): L_img = log_softmax(L_head + ω · max(L_knn, floor)),
// L = log_softmax(log_softmax(L_img + λ_t · prior_t) / T), prior_t its own
// transform / σ / α. Then the answer ladder (ladder_v3): a species when
// p(named) reaches the threshold of the named class's training-photo
// bucket, else a genus whose species sum to ≥ genus (shown with its top
// 3), else "not sure". Unit tests reproduce V2Ship on the shipped files.
//
// The big tables (the int8 head, the prior's CSR rows) stay memory-mapped:
// clean file pages the kernel can drop, not app memory.

/// Rows of int8 × a per-row scale: value = scale[row] · v[row].
struct PlantIDInt8Rows: @unchecked Sendable {
    let vectors: UnsafeBufferPointer<Int8>
    /// Synthetic rows (DEBUG fakes, tests) keep their bytes here.
    let owner: PlantIDOwnedBytes?
    let scale: [Float]
    let rows: Int
    let dimension: Int
    /// Rows converted to Float per step (512 × 1024 × 4 B = 2 MB of scratch).
    static let chunk = 512

    init(blob: IZPLBlob, name: String, dimension: Int) throws {
        let file = blob.file.url.lastPathComponent
        guard let info = blob.arrays[name], info.shape.count == 2, info.shape[1] == dimension
        else { throw PlantIDError.malformed(file, "\(name) isn't rows × \(dimension)") }
        rows = info.shape[0]
        self.dimension = dimension
        vectors = try blob.pointer(name, Int8.self, dtype: "int8")
        owner = nil
        scale = try blob.floats("scale")
        guard scale.count == rows else { throw PlantIDError.malformed(file, "scale ≠ rows") }
    }

    /// Rows × dimension floats quantised per row (scale = max|w| / 127).
    init(weight: [Float], rows: Int, dimension: Int) {
        precondition(weight.count == rows * dimension, "weight must be rows × dimension")
        self.rows = rows
        self.dimension = dimension
        var scale = [Float](repeating: 1, count: rows)
        let bytes = PlantIDOwnedBytes(count: rows * dimension)
        for r in 0 ..< rows {
            let row = weight[r * dimension ..< (r + 1) * dimension]
            let m = row.map(abs).max() ?? 0
            scale[r] = max(m, 1e-12) / 127
            for (j, v) in row.enumerated() { bytes.pointer[r * dimension + j] = Int8(max(-127, min(127, (v / scale[r]).rounded()))) }
        }
        self.scale = scale
        owner = bytes
        vectors = UnsafeBufferPointer(bytes.pointer)
    }

    /// out[r] = scale[r] · (v[r] · q) for every row; `scratch` holds
    /// `chunk × dimension` floats.
    func dots(_ q: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>) {
        let D = dimension
        var r0 = 0
        while r0 < rows {
            let n = min(Self.chunk, rows - r0)
            vDSP_vflt8(vectors.baseAddress! + r0 * D, 1, scratch, 1, vDSP_Length(n * D))
            vDSP_mmul(scratch, 1, q, 1, out + r0, 1, vDSP_Length(n), 1, vDSP_Length(D))
            r0 += n
        }
        scale.withUnsafeBufferPointer { s in vDSP_vmul(out, 1, s.baseAddress!, 1, out, 1, vDSP_Length(rows)) }
    }
}

/// Bytes a synthetic table owns (freed with it).
final class PlantIDOwnedBytes: @unchecked Sendable {
    let pointer: UnsafeMutableBufferPointer<Int8>
    init(count: Int) {
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: 0)
    }
    deinit { pointer.deallocate() }
}

/// How the prior turns a cell's record count into weight (eval_v2's `kind`).
public enum PlantIDCountTransform: String, Sendable {
    case count, sqrt, log1p, presence

    @inline(__always) func apply(_ c: Double) -> Double {
        switch self {
        case .count: c
        case .sqrt: c.squareRoot()
        case .log1p: Foundation.log1p(c)
        case .presence: 1
        }
    }
}

/// The Australia-wide location prior (v2-prior.bin, kind
/// "plantid-prior-deg" v2; build_ship.V2Prior): record counts per (cell,
/// class) on a lat/lon grid of `cell_deg` degrees — row iy = floor((lat −
/// lat0)/cell_deg), column ix = floor((lon − lon0)/cell_deg), CSR rows —
/// and per count transform t the class frequency f_t (`freq_<t>`, over
/// every class). At a point every cell whose centre is within 3σ adds
/// t(count) · exp(−d²/2σ²), d in km with Δlon scaled by cos(the point's
/// latitude); then (K + α f) / (ΣK + α).
public final class PlantIDDegPrior: @unchecked Sendable {
    let blob: IZPLBlob?
    /// A synthetic prior's buffers (allocated here, freed in deinit).
    private let owned: [UnsafeMutableRawBufferPointer]
    let cellDeg: Double, lat0: Double, lon0: Double
    let nx: Int, ny: Int
    let kmPerDegLat: Double, kmPerDegLon: Double
    let radiusSigmas: Double
    let rowptr: UnsafeBufferPointer<UInt32>
    let species: UnsafeBufferPointer<UInt16>
    let count16: UnsafeBufferPointer<UInt16>?
    let count32: UnsafeBufferPointer<UInt32>?
    let frequency: [PlantIDCountTransform: [Double]]
    public let labels: Int

    init(blob: IZPLBlob, labels: Int) throws {
        self.blob = blob
        owned = []
        self.labels = labels
        let name = blob.file.url.lastPathComponent
        guard blob.header["kind"] as? String == "plantid-prior-deg", blob.int("version") == 2
        else { throw PlantIDError.malformed(name, "not a plantid-prior-deg v2 file") }
        func n(_ k: String) throws -> Double {
            guard let v = blob.number(k) else { throw PlantIDError.malformed(name, "no \(k)") }
            return v
        }
        cellDeg = try n("cell_deg")
        lat0 = try n("lat0")
        lon0 = try n("lon0")
        nx = Int(try n("nx"))
        ny = Int(try n("ny"))
        kmPerDegLat = try n("km_per_deg_lat")
        kmPerDegLon = try n("km_per_deg_lon")
        radiusSigmas = try n("radius_sigmas")
        rowptr = try blob.pointer("rowptr", UInt32.self, dtype: "uint32")
        species = try blob.pointer("species", UInt16.self, dtype: "uint16")
        switch blob.arrays["count"]?.dtype {
        case "uint16":
            count16 = try blob.pointer("count", UInt16.self, dtype: "uint16")
            count32 = nil
        case "uint32":
            count32 = try blob.pointer("count", UInt32.self, dtype: "uint32")
            count16 = nil
        default:
            throw PlantIDError.malformed(name, "count isn't uint16/uint32")
        }
        var freq: [PlantIDCountTransform: [Double]] = [:]
        for t in [PlantIDCountTransform.count, .sqrt, .log1p, .presence] where blob.arrays["freq_\(t.rawValue)"] != nil {
            let f = Array(try blob.pointer("freq_\(t.rawValue)", Double.self, dtype: "float64"))
            guard f.count == labels, f.allSatisfy({ $0 > 0 && $0.isFinite }) else { throw PlantIDError.malformed(name, "freq_\(t.rawValue)") }
            freq[t] = f
        }
        frequency = freq
        let pairs = count16?.count ?? count32!.count
        guard cellDeg > 0, nx > 0, ny > 0, rowptr.count == nx * ny + 1, Int(rowptr.last!) == species.count,
              pairs == species.count
        else { throw PlantIDError.malformed(name, "grid arrays don't fit together") }
        // one pass over the class ids (5.6 M uint16, a few ms): a bad id would index out of range later
        guard species.allSatisfy({ Int($0) < labels }) else { throw PlantIDError.malformed(name, "class id out of range") }
    }

    /// A synthetic prior (DEBUG fakes, tests): each record counts 1 in its
    /// 0.05° cell; frequencies for every transform.
    public init(records: [(latitude: Double, longitude: Double, label: Int)], labels: Int) {
        let g = 0.05
        cellDeg = g
        lat0 = ((records.map(\.latitude).min() ?? 0) / g).rounded(.down) * g - 1
        lon0 = ((records.map(\.longitude).min() ?? 0) / g).rounded(.down) * g - 1
        ny = Int((((records.map(\.latitude).max() ?? 0) + 1 - lat0) / g).rounded(.up)) + 1
        nx = Int((((records.map(\.longitude).max() ?? 0) + 1 - lon0) / g).rounded(.up)) + 1
        kmPerDegLat = 110.57
        kmPerDegLon = 111.32
        radiusSigmas = 3
        self.labels = labels
        blob = nil
        var perCell: [Int: [Int: UInt32]] = [:]
        for r in records {
            let iy = Int(((r.latitude - lat0) / g).rounded(.down)), ix = Int(((r.longitude - lon0) / g).rounded(.down))
            perCell[iy * nx + ix, default: [:]][r.label, default: 0] += 1
        }
        var rowptr: [UInt32] = [0], species: [UInt16] = [], count: [UInt32] = []
        for cell in 0 ..< nx * ny {
            for (l, c) in (perCell[cell] ?? [:]).sorted(by: { $0.key < $1.key }) {
                species.append(UInt16(l))
                count.append(c)
            }
            rowptr.append(UInt32(species.count))
        }
        var freq: [PlantIDCountTransform: [Double]] = [:]
        for t in [PlantIDCountTransform.count, .sqrt, .log1p, .presence] {
            var tot = [Double](repeating: 1, count: labels)
            for (l, c) in zip(species, count) { tot[Int(l)] += t.apply(Double(c)) }
            let sum = tot.reduce(0, +)
            freq[t] = tot.map { $0 / sum }
        }
        frequency = freq
        func copy<T>(_ a: [T]) -> (UnsafeBufferPointer<T>, UnsafeMutableRawBufferPointer) {
            let p = UnsafeMutableBufferPointer<T>.allocate(capacity: max(a.count, 1))
            _ = p.initialize(from: a)
            return (UnsafeBufferPointer(start: p.baseAddress, count: a.count), UnsafeMutableRawBufferPointer(p))
        }
        let (r, rb) = copy(rowptr), (sp, sb) = copy(species), (c, cb) = copy(count)
        self.rowptr = r
        self.species = sp
        count32 = c
        count16 = nil
        owned = [rb, sb, cb]
    }

    deinit { for b in owned { b.deallocate() } }

    @inline(__always) private func count(_ j: Int) -> Double {
        if let count16 { return Double(count16[j]) }
        return Double(count32![j])
    }

    /// Whether the point's kernel (radius 3σ) reaches the grid at all.
    public func covers(latitude: Double, longitude: Double, sigmaKm: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) < 89 else { return false }
        let r = radiusSigmas * sigmaKm
        let ky = kmPerDegLat, kx = kmPerDegLon * cos(latitude * Double.pi / 180)
        let dLat = max(lat0 - latitude, 0, latitude - (lat0 + Double(ny) * cellDeg)) * ky
        let dLon = max(lon0 - longitude, 0, longitude - (lon0 + Double(nx) * cellDeg)) * kx
        return dLat * dLat + dLon * dLon <= r * r
    }

    /// Every cell whose centre lies within `r` km of the point: (row, d² in km²).
    private func cells(latitude lat: Double, longitude lon: Double, radius r: Double, _ body: (Int, Double) -> Void) {
        let g = cellDeg
        let ky = kmPerDegLat, kx = kmPerDegLon * cos(lat * Double.pi / 180)
        guard kx > 0, lat.isFinite, lon.isFinite else { return }
        let wy = Int((r / (ky * g)).rounded(.up)) + 1
        let wx = Int((r / (kx * g)).rounded(.up)) + 1
        let fy = ((lat - lat0) / g).rounded(.down), fx = ((lon - lon0) / g).rounded(.down)
        guard abs(fy) < 1e7, abs(fx) < 1e7 else { return }
        let iy0 = Int(fy), ix0 = Int(fx)
        let yLo = max(iy0 - wy, 0), yHi = min(iy0 + wy, ny - 1)
        let xLo = max(ix0 - wx, 0), xHi = min(ix0 + wx, nx - 1)
        guard yLo <= yHi, xLo <= xHi else { return }
        for iy in yLo ... yHi {
            let dy = (lat0 + (Double(iy) + 0.5) * g - lat) * ky
            for ix in xLo ... xHi {
                let dx = (lon0 + (Double(ix) + 0.5) * g - lon) * kx
                let d2 = dx * dx + dy * dy
                guard d2 <= r * r else { continue }
                body(iy * nx + ix, d2)
            }
        }
    }

    /// Adds λ · log p(class | place) to `L` in place; `location` nil = no
    /// local evidence (K = 0 → λ · log f).
    func addLogPrior(_ location: GeoPoint?, transform: PlantIDCountTransform, sigmaKm: Double, alpha: Double,
                     lambda: Double, to L: UnsafeMutableBufferPointer<Double>, scratch K: UnsafeMutableBufferPointer<Double>) {
        guard let f = frequency[transform] else { preconditionFailure("no freq_\(transform.rawValue) (checked at load)") }
        let C = labels
        K.initialize(repeating: 0)
        var total = 0.0
        if let location {
            let s2 = 2 * sigmaKm * sigmaKm
            cells(latitude: location.latitude, longitude: location.longitude, radius: radiusSigmas * sigmaKm) { row, d2 in
                let w = exp(-d2 / s2)
                for j in Int(rowptr[row]) ..< Int(rowptr[row + 1]) { K[Int(species[j])] += w * transform.apply(count(j)) }
            }
            for c in 0 ..< C { total += K[c] }
        }
        let denominator = total + alpha
        for c in 0 ..< C { L[c] += lambda * log((K[c] + alpha * f[c]) / denominator) }
    }

    /// log p(class | place) for every class (tests).
    public func logPrior(_ location: GeoPoint?, transform: PlantIDCountTransform, sigmaKm: Double, alpha: Double) -> [Double] {
        var L = [Double](repeating: 0, count: labels)
        var K = [Double](repeating: 0, count: labels)
        L.withUnsafeMutableBufferPointer { l in
            K.withUnsafeMutableBufferPointer { k in
                addLogPrior(location, transform: transform, sigmaKm: sigmaKm, alpha: alpha, lambda: 1, to: l, scratch: k)
            }
        }
        return L
    }

    /// Records per class in the cells whose centre is within `km` of the point.
    public func records(within km: Double, latitude: Double, longitude: Double) -> [Int: Int] {
        var out: [Int: Int] = [:]
        cells(latitude: latitude, longitude: longitude, radius: km) { row, _ in
            for j in Int(rowptr[row]) ..< Int(rowptr[row + 1]) { out[Int(species[j]), default: 0] += Int(count(j)) }
        }
        return out
    }
}

/// The answer ladder: a species threshold per training-photo bucket of the
/// NAMED class (ladder_v3: 0 | 1–9 | 10–49 | 50+ photos), a genus threshold,
/// the image-only floor and the close-congener rule (off at ratio 1).
public struct PlantIDLadder: Sendable, Equatable {
    public var species: [Double]
    /// Bucket b holds the counts n with edges[b] ≤ n < edges[b+1] (first:
    /// n ≤ edges[0]); one threshold per bucket.
    public var bucketEdges: [Int]
    public var genus: Double
    public var imageFloor: Double
    public var congenerRatio: Double

    /// One threshold for every class: 0.5 / 0.5 (tests, DEBUG fakes).
    public static let simple = PlantIDLadder(species: [0.5], bucketEdges: [], genus: 0.5)

    public init(species: [Double], bucketEdges: [Int], genus: Double, imageFloor: Double = 0, congenerRatio: Double = 1) {
        self.species = species
        self.bucketEdges = bucketEdges
        self.genus = genus
        self.imageFloor = imageFloor
        self.congenerRatio = congenerRatio
    }

    /// The species threshold for a class with `photos` training photos.
    public func speciesThreshold(photos: Int?) -> Double {
        guard let photos, !bucketEdges.isEmpty else { return species[0] }
        var b = 0
        if photos > bucketEdges[0] {
            b = bucketEdges.count
            for i in 1 ..< bucketEdges.count where photos < bucketEdges[i] {
                b = i
                break
            }
        }
        return species[min(b, species.count - 1)]
    }

    init(header any: Any?) throws {
        func bad(_ why: String) -> PlantIDError { .malformed("v2-head.bin", "ladder: \(why)") }
        guard let d = any as? [String: Any] else { throw bad("missing") }
        guard let s = (d["species"] as? [NSNumber])?.map(\.doubleValue), !s.isEmpty,
              let e = (d["bucket_edges"] as? [NSNumber])?.map(\.intValue), e.count + 1 == s.count,
              let g = (d["genus"] as? NSNumber)?.doubleValue,
              s.allSatisfy({ $0 > 0 && $0 <= 1 }), g > 0, g <= 1
        else { throw bad("species/bucket_edges/genus") }
        species = s
        bucketEdges = e
        genus = g
        imageFloor = (d["image_floor"] as? NSNumber)?.doubleValue ?? 0
        congenerRatio = (d["congener_ratio"] as? NSNumber)?.doubleValue ?? 1
    }
}

/// v2-head.bin's `scoring`: everything after the encoder.
public struct PlantIDModelParameters: Sendable, Equatable {
    public struct PriorTerm: Sendable, Equatable {
        public var transform: PlantIDCountTransform
        public var sigmaKm: Double
        public var alpha: Double

        public init(transform: PlantIDCountTransform, sigmaKm: Double, alpha: Double) {
            self.transform = transform
            self.sigmaKm = sigmaKm
            self.alpha = alpha
        }
    }

    public var temperature: Double
    public var lam: Double
    public var prior: PriorTerm
    /// W, S, E, N.
    public var tasmaniaBox: [Double]
    public var tasmaniaOmega: Double
    public var knnFloor: Double
    public var tasmaniaLam: Double
    public var tasmaniaPrior: PriorTerm
    public var bank: String
    public var ladder: PlantIDLadder

    /// A model without the Tasmanian bank term (DEBUG fakes, tests).
    public init(temperature: Double, lam: Double, prior: PriorTerm, ladder: PlantIDLadder) {
        self.temperature = temperature
        self.lam = lam
        self.prior = prior
        tasmaniaBox = [143.5, -44.0, 149.0, -39.2]
        tasmaniaOmega = 0
        knnFloor = -30
        tasmaniaLam = lam
        tasmaniaPrior = prior
        bank = ""
        self.ladder = ladder
    }

    init(header: [String: Any]) throws {
        func bad(_ why: String) -> PlantIDError { .malformed("v2-head.bin", why) }
        guard let s = header["scoring"] as? [String: Any], let t = s["tasmania"] as? [String: Any] else { throw bad("no scoring") }
        func num(_ d: [String: Any], _ k: String) throws -> Double {
            guard let v = (d[k] as? NSNumber)?.doubleValue, v.isFinite else { throw bad("scoring has no \(k)") }
            return v
        }
        func term(_ any: Any?) throws -> PriorTerm {
            guard let d = any as? [String: Any], let tr = (d["transform"] as? String).flatMap(PlantIDCountTransform.init(rawValue:))
            else { throw bad("prior term") }
            let p = PriorTerm(transform: tr, sigmaKm: try num(d, "sigma_km"), alpha: try num(d, "alpha"))
            guard p.sigmaKm > 0, p.alpha > 0 else { throw bad("prior σ/α") }
            return p
        }
        temperature = try num(s, "temperature")
        lam = try num(s, "lam")
        prior = try term(s["prior"])
        guard let box = (t["box"] as? [NSNumber])?.map(\.doubleValue), box.count == 4 else { throw bad("tasmania box") }
        tasmaniaBox = box
        tasmaniaOmega = try num(t, "omega")
        knnFloor = try num(t, "knn_floor")
        tasmaniaLam = try num(t, "lam")
        tasmaniaPrior = try term(t["prior"])
        bank = t["bank"] as? String ?? "bank-int8.bin"
        ladder = try PlantIDLadder(header: s["ladder"])
        guard temperature > 0 else { throw bad("temperature") }
    }

    public func inTasmania(_ p: GeoPoint) -> Bool {
        p.longitude >= tasmaniaBox[0] && p.latitude >= tasmaniaBox[1] && p.longitude <= tasmaniaBox[2] && p.latitude <= tasmaniaBox[3]
    }
}

struct PlantIDV2LabelsFile: Decodable {
    var version: Int
    var count: Int
    var labels: [PlantIDLabel]
}

/// The single model's scorer (v2-head.bin, v2-prior.bin, v2-labels.json +
/// the Tasmanian bank-int8.bin for the Tasmania box).
public final class PlantIDModel: @unchecked Sendable {
    public static let files = ["v2-head.bin", "v2-prior.bin", "v2-labels.json"]
    /// "Recorded within 10 km": records in the 0.05° cells whose centre is
    /// within 6 km of the point (a cell reaches ≤ ~4 km further).
    public static let nearbyCellKm = 6.0
    public static let nearbyKm = 10.0
    /// W, S, E, N: build_ship.TAS_BOX — incl. King Island and the Furneaux Group.
    public static let tasmaniaBox = (west: 143.5, south: -44.0, east: 149.0, north: -39.2)

    public static func inTasmania(_ p: GeoPoint) -> Bool {
        let b = tasmaniaBox
        return p.longitude >= b.west && p.latitude >= b.south && p.longitude <= b.east && p.latitude <= b.north
    }

    public let labels: [PlantIDLabel]
    /// (settable inside IzzyKit for the ladder tests only)
    public internal(set) var parameters: PlantIDModelParameters
    public let dimension: Int
    let head: PlantIDInt8Rows
    let bias: [Float]
    let centre: [Float]
    let tasCentre: [Float]
    /// Per Tasmanian bank label: its class (repeats allowed: the last wins).
    let tasClasses: [Int]
    /// The Tasmanian photo bank (nil: a synthetic model without the Tasmania-box term).
    let bank: PlantIDBank?
    let bankScoring: PlantIDScoring
    public let prior: PlantIDDegPrior
    let photos: [Int]
    let genusOf: [Int]
    let genusNames: [String]
    let blobs: [IZPLBlob]

    /// All three v2 files are in the folder (the pack from 2026-11 on).
    public static func available(in directory: URL) -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path(percentEncoded: false)) }
    }

    public init(directory: URL) throws {
        let file: PlantIDV2LabelsFile
        do {
            file = try JSONDecoder().decode(PlantIDV2LabelsFile.self,
                                            from: Data(contentsOf: directory.appending(path: "v2-labels.json"), options: .mappedIfSafe))
        } catch { throw PlantIDError.malformed("v2-labels.json", String(describing: error)) }
        guard file.version == 1, file.labels.count == file.count else { throw PlantIDError.malformed("v2-labels.json", "version/count") }
        let C = file.count
        labels = file.labels
        let h = try IZPLBlob(url: directory.appending(path: "v2-head.bin"))
        guard h.header["kind"] as? String == "plantid-head-v2", h.int("version") == 1,
              let w = h.arrays["weight"], w.shape.count == 2, w.shape[0] == C
        else { throw PlantIDError.malformed("v2-head.bin", "not a v2 head over the labels") }
        let D = w.shape[1]
        dimension = D
        head = try PlantIDInt8Rows(blob: h, name: "weight", dimension: D)
        bias = try h.floats("bias")
        centre = try h.floats("centre")
        tasCentre = try h.floats("tas_centre")
        let tas = try h.pointer("tas_classes", Int32.self, dtype: "int32").map(Int.init)
        tasClasses = tas
        guard bias.count == C, centre.count == D, tasCentre.count == D, tas.allSatisfy({ $0 >= 0 && $0 < C })
        else { throw PlantIDError.malformed("v2-head.bin", "bias/centres/tas_classes don't fit") }
        parameters = try PlantIDModelParameters(header: h.header)
        let b = try IZPLBlob(url: directory.appending(path: parameters.bank))
        let bs = try PlantIDScoring(header: b.header)
        let theBank = try PlantIDBank(blob: b, dimension: D)
        guard !bs.headOnly, theBank.labels.allSatisfy({ Int($0) < tas.count })
        else { throw PlantIDError.malformed(parameters.bank, "bank labels don't fit tas_classes") }
        bankScoring = bs
        bank = theBank
        let pb = try IZPLBlob(url: directory.appending(path: "v2-prior.bin"))
        let pr = try PlantIDDegPrior(blob: pb, labels: C)
        guard pr.frequency[parameters.prior.transform] != nil, pr.frequency[parameters.tasmaniaPrior.transform] != nil
        else { throw PlantIDError.malformed("v2-prior.bin", "no frequency for the prior's transform") }
        prior = pr
        let rows = file.labels
        photos = rows.map { $0.trainPhotos ?? 0 }
        var names: [String: Int] = [:]
        var order: [String] = []
        genusOf = rows.map { label in
            let g = label.genusName
            if let i = names[g] { return i }
            names[g] = order.count
            order.append(g)
            return order.count - 1
        }
        genusNames = order
        blobs = [h, b, pb]
    }

    /// A synthetic model (DEBUG fakes, tests): `weight` = labels × dimension
    /// floats (quantised per row like the shipped head), no Tasmanian bank.
    public init(labels: [PlantIDLabel], weight: [Float], bias: [Float]? = nil, centre: [Float],
                parameters: PlantIDModelParameters, prior: PlantIDDegPrior) {
        let C = labels.count, D = centre.count
        precondition(prior.labels == C, "the prior must cover the labels")
        self.labels = labels
        self.parameters = parameters
        dimension = D
        head = PlantIDInt8Rows(weight: weight, rows: C, dimension: D)
        self.bias = bias ?? [Float](repeating: 0, count: C)
        self.centre = centre
        tasCentre = centre
        tasClasses = []
        bank = nil
        bankScoring = PlantIDScoring(headOnly: true)
        self.prior = prior
        photos = labels.map { $0.trainPhotos ?? 0 }
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
        blobs = []
    }

    /// The point takes part in the prior (finite, near the grid).
    func place(_ location: GeoPoint?) -> GeoPoint? {
        guard let location, prior.covers(latitude: location.latitude, longitude: location.longitude,
                                         sigmaKm: max(parameters.prior.sigmaKm, parameters.tasmaniaPrior.sigmaKm))
        else { return nil }
        return location
    }

    static func logSoftmax(_ z: inout [Double], scale: Double = 1) {
        var m = -Double.infinity
        for v in z where v > m { m = v }
        guard m.isFinite else { return }
        var s = 0.0
        for v in z { s += exp(scale * (v - m)) }
        let l = log(s)
        for i in z.indices { z[i] = scale * (z[i] - m) - l }
    }

    /// The Tasmanian bank's kNN term over the classes (others −1e4).
    func knnLogp(_ embedding: [Float]) -> [Double] {
        func unit(_ v: [Float]) -> [Float] {
            let n = Float(sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) }))
            return n > 0 ? v.map { $0 / n } : v
        }
        let qs = unit(zip(unit(embedding), tasCentre).map { $0 - $1 })
        let nb = tasClasses.count
        let s = bankScoring
        guard let bank else { return [Double](repeating: 0, count: labels.count) }
        let near = bank.neighbours(qs, dimension: dimension, k: s.k)
        var P = [Double](repeating: 0, count: nb)
        if let s0 = near.first?.0 {
            for (sim, row) in near { P[Int(bank.labels[row])] += exp(Double(sim - s0) / s.tau) }
        }
        let total = P.reduce(0, +)
        let floor = 1e-6 / Double(nb)
        var small = P.map { s.knnTemp * log((total > 0 ? $0 / total : 0) + floor) }
        Self.logSoftmax(&small)
        var L = [Double](repeating: -1e4, count: labels.count)
        for (j, c) in tasClasses.enumerated() { L[c] = small[j] }
        return L
    }

    /// Displayed log p and image-only log p over the classes, and whether
    /// the Tasmania-box path answered. `location` nil = no location.
    public func scores(embedding: [Float], location: GeoPoint?) -> (logp: [Double], image: [Double], tasmania: Bool) {
        precondition(embedding.count == dimension, "embedding must have \(dimension) values")
        let C = labels.count, D = dimension
        func unit(_ v: [Float]) -> [Float] {
            let n = Float(sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) }))
            return n > 0 ? v.map { $0 / n } : v
        }
        let q = unit(zip(unit(embedding), centre).map { $0 - $1 })
        var logits = [Float](repeating: 0, count: C)
        var scratch = [Float](repeating: 0, count: PlantIDInt8Rows.chunk * D)
        q.withUnsafeBufferPointer { qp in
            logits.withUnsafeMutableBufferPointer { o in
                scratch.withUnsafeMutableBufferPointer { s in head.dots(qp.baseAddress!, into: o.baseAddress!, scratch: s.baseAddress!) }
            }
        }
        var Lh = (0 ..< C).map { Double(logits[$0]) + Double(bias[$0]) }
        Self.logSoftmax(&Lh)
        let p = parameters
        let tas = bank != nil && (location.map(p.inTasmania) ?? false)
        var img = Lh
        var term = p.prior, lam = p.lam
        if tas {
            let knn = knnLogp(embedding)
            for c in 0 ..< C { img[c] = Lh[c] + p.tasmaniaOmega * max(knn[c], p.knnFloor) }
            Self.logSoftmax(&img)
            term = p.tasmaniaPrior
            lam = p.tasmaniaLam
        }
        var L = img
        var K = [Double](repeating: 0, count: C)
        L.withUnsafeMutableBufferPointer { l in
            K.withUnsafeMutableBufferPointer { k in
                prior.addLogPrior(location, transform: term.transform, sigmaKm: term.sigmaKm, alpha: term.alpha,
                                  lambda: lam, to: l, scratch: k)
            }
        }
        Self.logSoftmax(&L)
        Self.logSoftmax(&L, scale: 1 / p.temperature)
        Self.logSoftmax(&img, scale: 1 / p.temperature)
        return (L, img, tas)
    }

    /// The answer for one photo: ladder, top 5, genera. A location far
    /// from the grid counts as none.
    public func identify(embedding: [Float], location: GeoPoint?) -> PlantIDResult {
        let place = place(location)
        let (logp, image, tas) = scores(embedding: embedding, location: place)
        let p = logp.map { exp($0) }
        let order = Self.order(p)
        let nearby = place.map { prior.records(within: Self.nearbyCellKm, latitude: $0.latitude, longitude: $0.longitude) } ?? [:]
        let ladder = parameters.ladder
        func candidate(_ i: Int) -> PlantIDResult.Candidate {
            .init(label: i, p: p[i], nearbyRecords: nearby[i] ?? 0, threshold: ladder.speciesThreshold(photos: photos[i]))
        }
        var genusP = [Double](repeating: 0, count: genusNames.count)
        for (i, v) in p.enumerated() { genusP[genusOf[i]] += v }
        let n1 = order[0], n2 = order.count > 1 ? order[1] : order[0]
        let close = ladder.congenerRatio < 1 && n1 != n2 && genusOf[n1] == genusOf[n2] && p[n2] >= ladder.congenerRatio * p[n1]
        var answer = PlantIDResult.Answer.notSure
        var genusSpecies: [PlantIDResult.Candidate] = []
        if p[n1] >= ladder.speciesThreshold(photos: photos[n1]), exp(image[n1]) >= ladder.imageFloor, !close {
            answer = .species(label: n1, p: p[n1])
        } else if let g = genusP.indices.max(by: { genusP[$0] < genusP[$1] }), genusP[g] >= ladder.genus {
            answer = .genus(genusNames[g], p: genusP[g])
            genusSpecies = order.lazy.filter { self.genusOf[$0] == g }.prefix(3).map(candidate)
        }
        let top = order.prefix(5).map(candidate)
        var seen: [Int] = []
        for c in top where !seen.contains(genusOf[c.label]) { seen.append(genusOf[c.label]) }
        let genera = seen.map { g in
            PlantIDResult.GenusShare(name: genusNames[g], p: genusP[g],
                                     species: order.lazy.filter { self.genusOf[$0] == g }.prefix(6).map(candidate))
        }.sorted { $0.p > $1.p }
        return PlantIDResult(answer: answer, candidates: top, genera: genera, usedLocation: place != nil,
                             scope: tas ? .tasmania : .australia, nearbyKm: Self.nearbyKm, ladder: ladder,
                             genusSpecies: genusSpecies, nearbySpecies: nearby.values.count { $0 > 0 })
    }

    /// Classes by p, best first (index order among equal p).
    static func order(_ p: [Double]) -> [Int] {
        p.indices.sorted { p[$0] != p[$1] ? p[$0] > p[$1] : $0 < $1 }
    }
}
