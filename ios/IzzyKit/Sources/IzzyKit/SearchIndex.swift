import Foundation

/// The offline place / street / address index: LIST place names
/// (`search/gazetteer.json`) and street address points
/// (`search/addresses.json`), both built by pipeline/build_gazetteer.py,
/// version 1, CC BY 3.0 AU © State of Tasmania.
///
/// Every name is normalised and split into words once at load; the words are
/// interned into one sorted vocabulary, so a typed word becomes an id range
/// (all words it prefixes are contiguous) and scoring a row is integer
/// comparisons only. Immutable and `Sendable`: build it off the main actor
/// (`load(from:)`), then query from anywhere.
public struct SearchIndex: Sendable {
    public static let supportedVersion = 1
    /// File names inside the bundled `search/` folder.
    public enum File {
        public static let directory = "search"
        public static let gazetteer = "gazetteer.json"
        public static let addresses = "addresses.json"
    }
    /// The search panel's footer credit.
    public static let credit = "Names and addresses from theLIST © State of Tasmania (CC BY 3.0 AU)"

    /// What the search panel says when the index could not be built: a
    /// version mismatch is this build's for good ("Update the app to
    /// search"); anything else is a damaged install.
    public static func failureMessage(for error: any Error) -> String {
        if case DataError.unsupportedVersion = error { return "Update the app to search" }
        return "Place names aren’t available — reinstall IzzyMap if this persists"
    }

    /// `built` dates and attribution lines of the two files.
    public let built: [String]
    public let attributions: [String]
    /// Rows in the place-name file / streets in the address file.
    public var placeCount: Int { eName.count }
    public var streetCount: Int { sName.count }

    // ---- vocabulary: every distinct word, sorted (id = rank) ----
    let vocab: [String]
    /// The same words as one byte buffer (substring tier).
    let vocabBytes: [UInt8]
    let vocabStart: [Int32]

    // ---- gazetteer rows ----
    let types: [String]
    let groups: [String]
    /// Group name per type index ("" when the table has none).
    let typeGroupName: [String]
    let places: [String]
    let munis: [String]
    let eName: [String]
    let eType: [Int32]
    let ePlace: [Int32]
    let eMuni: [Int32]
    let eLat5: [Int32]
    let eLon5: [Int32]
    /// [w, s, e, n] in 1e-5° per row; valid where `eFlags & hasBox`.
    let eBox: [Int32]
    let eFlags: [UInt8]
    /// Name word ids, row i = eTok[eTokStart[i] ..< eTokStart[i+1]].
    let eTokStart: [Int32]
    let eTok: [Int32]
    /// Context (place + council) word set per row, shared per (place, council).
    let eCtx: [Int32]
    let ctxStart: [Int32]
    let ctxTok: [Int32]
    /// Interned normalised name, and normalised place per place index.
    let eNorm: [Int32]
    let placeNorm: [Int32]

    // ---- address-file streets ----
    let sName: [String]
    let sLocality: [String]
    let sNorm: [Int32]
    let sLocNorm: [Int32]
    let sTokStart: [Int32]
    let sTok: [Int32]
    let sLocStart: [Int32]
    let sLocTok: [Int32]
    let sLon0: [Int32]
    let sLat0: [Int32]
    /// House numbers, street i = numValue[sNumStart[i] ..< sNumStart[i+1]].
    let sNumStart: [Int32]
    /// Leading integer of each number (`parseInt`); `Int32.min` = NaN.
    let numValue: [Int32]
    /// Numbers that are strings in the file ("15A"), by flat index.
    let numText: [Int32: String]
    let dLon: [Int32]
    let dLat: [Int32]
    let hasAddresses: Bool

    // ---- inverted lists (word id → rows), to skip rows that cannot match ----
    /// word → gazetteer rows with it in the name
    let eNamePost: Postings
    /// word → context groups holding it; context group → rows
    let ctxPost: Postings
    let ctxRows: Postings
    /// Prefix sums over word ids of the rows reachable through `ctxPost`.
    let ctxWeight: [Int]
    /// word → streets with it in the name / in the locality
    let sNamePost: Postings
    let sLocPost: Postings

    static let hasBox: UInt8 = 1, isProperty: UInt8 = 2, isTransport: UInt8 = 4, isRoad: UInt8 = 8

    // MARK: loading

    /// Reads `search/gazetteer.json` + `search/addresses.json` under
    /// `data.root` (or directly under it) on a background thread.
    @concurrent
    public static func load(from data: BundledData) async throws -> SearchIndex {
        func file(_ name: String) throws -> Data {
            let nested = data.root.appending(path: File.directory).appending(path: name)
            let url = FileManager.default.fileExists(atPath: nested.path) ? nested : data.root.appending(path: name)
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        return try SearchIndex(gazetteer: file(File.gazetteer), addresses: file(File.addresses))
    }

    /// Builds the index from the two files' bytes (synchronous; ~0.1–0.3 s —
    /// call off the main actor). `addresses` nil = place names only.
    public init(gazetteer: Data, addresses: Data?) throws {
        let g = try Self.parse(gazetteer, file: File.gazetteer, RawGazetteer.read)
        let a = try addresses.map { try Self.parse($0, file: File.addresses, RawAddresses.read) }
        var b = Builder()

        // gazetteer tables
        let types = g.types, groups = g.groups, places = g.places, munis = g.munis
        guard g.typeGroup.count == types.count else {
            throw DataError.malformed(file: File.gazetteer, reason: "typeGroup has \(g.typeGroup.count) entries for \(types.count) types")
        }
        self.types = types; self.groups = groups; self.places = places; self.munis = munis
        typeGroupName = g.typeGroup.map { $0 >= 0 && $0 < groups.count ? groups[$0] : "" }
        var typeFlags = [UInt8](repeating: 0, count: types.count)
        for (t, gi) in g.typeGroup.enumerated() {
            let group = gi >= 0 && gi < groups.count ? groups[gi] : ""
            if group == "Property" { typeFlags[t] |= Self.isProperty }
            if group == "Transport" { typeFlags[t] |= Self.isTransport }
            if types[t] == "Road" { typeFlags[t] |= Self.isRoad }
        }
        var placeNorm = [Int32]()
        for p in places { placeNorm.append(b.placeNormID(SearchText.normalise(p))) }
        self.placeNorm = placeNorm

        let n = g.names.count
        var eType = [Int32](), ePlace = [Int32](), eMuni = [Int32](), eLat5 = [Int32](), eLon5 = [Int32]()
        var eFlags = [UInt8](), eNorm = [Int32](), eCtx = [Int32]()
        var eTok = [Int32](), eTokStart: [Int32] = [0]
        var ctxTok = [Int32](), ctxStart: [Int32] = [0], ctxOf: [Int: Int32] = [:]
        eType.reserveCapacity(n); ePlace.reserveCapacity(n); eMuni.reserveCapacity(n); eLat5.reserveCapacity(n)
        eLon5.reserveCapacity(n); eFlags.reserveCapacity(n); eNorm.reserveCapacity(n); eCtx.reserveCapacity(n)
        eTokStart.reserveCapacity(n + 1); eTok.reserveCapacity(3 * n)
        for r in 0..<n {
            let ti = Int(g.ints[5 * r]), pi = Int(g.ints[5 * r + 1]), mi = Int(g.ints[5 * r + 2])
            let place = pi >= 0 && pi < places.count ? places[pi] : ""
            let muni = mi >= 0 && mi < munis.count ? munis[mi] : ""
            let norm = SearchText.normalise(g.names[r])
            eType.append(Int32(ti)); ePlace.append(Int32(pi)); eMuni.append(Int32(mi))
            eLat5.append(g.ints[5 * r + 3]); eLon5.append(g.ints[5 * r + 4])
            eFlags.append((ti >= 0 && ti < typeFlags.count ? typeFlags[ti] : 0) | (g.hasBox[r] ? Self.hasBox : 0))
            eNorm.append(b.nameNormID(norm))
            b.words(norm, into: &eTok)
            eTokStart.append(Int32(eTok.count))
            let ck = pi &* 4096 &+ mi
            if let c = ctxOf[ck] {
                eCtx.append(c)
            } else {
                var seen = Set<String>()
                for w in SearchText.tokenise(place + " " + muni) where seen.insert(w).inserted {
                    ctxTok.append(b.word(w))
                }
                ctxStart.append(Int32(ctxTok.count))
                let c = Int32(ctxStart.count - 2)
                ctxOf[ck] = c
                eCtx.append(c)
            }
        }

        // address-file streets
        var sNorm = [Int32](), sLocNorm = [Int32]()
        var sTok = [Int32](), sTokStart: [Int32] = [0], sLocTok = [Int32](), sLocStart: [Int32] = [0]
        if let a {
            for st in a.names.indices {
                let norm = SearchText.normalise(a.names[st])
                let locNorm = SearchText.normalise(a.localities[st])
                sNorm.append(b.nameNormID(norm)); sLocNorm.append(b.placeNormID(locNorm))
                b.words(norm, into: &sTok); sTokStart.append(Int32(sTok.count))
                b.words(locNorm, into: &sLocTok); sLocStart.append(Int32(sLocTok.count))
            }
        }
        let eName = g.names, eBox = g.boxes
        let sName = a?.names ?? [], sLocality = a?.localities ?? [], sLon0 = a?.lon0 ?? [], sLat0 = a?.lat0 ?? []
        let sNumStart = a?.numStart ?? [0], numValue = a?.numValue ?? [], numText = a?.numText ?? [:]
        let dLon = a?.dLon ?? [], dLat = a?.dLat ?? []

        // sort the vocabulary and renumber every word id by rank
        let (sorted, rank) = b.sortedVocabulary()
        func remap(_ ids: inout [Int32]) { for i in ids.indices { ids[i] = rank[Int(ids[i])] } }
        remap(&eTok); remap(&ctxTok); remap(&sTok); remap(&sLocTok)
        var bytes = [UInt8](), starts: [Int32] = [0]
        for w in sorted { bytes.append(contentsOf: w.utf8); starts.append(Int32(bytes.count)) }

        vocab = sorted; vocabBytes = bytes; vocabStart = starts
        self.eName = eName; self.eType = eType; self.ePlace = ePlace; self.eMuni = eMuni
        self.eLat5 = eLat5; self.eLon5 = eLon5; self.eBox = eBox; self.eFlags = eFlags
        self.eTokStart = eTokStart; self.eTok = eTok; self.eCtx = eCtx; self.ctxStart = ctxStart; self.ctxTok = ctxTok
        self.eNorm = eNorm
        self.sName = sName; self.sLocality = sLocality; self.sNorm = sNorm; self.sLocNorm = sLocNorm
        self.sTokStart = sTokStart; self.sTok = sTok; self.sLocStart = sLocStart; self.sLocTok = sLocTok
        self.sLon0 = sLon0; self.sLat0 = sLat0; self.sNumStart = sNumStart; self.numValue = numValue
        self.numText = numText; self.dLon = dLon; self.dLat = dLat
        hasAddresses = a != nil
        let words = sorted.count
        eNamePost = Postings(keyCount: words, rowStart: eTokStart, keys: eTok)
        ctxPost = Postings(keyCount: words, rowStart: ctxStart, keys: ctxTok)
        ctxRows = Postings(keyCount: ctxStart.count - 1, rowStart: Array(0...Int32(eCtx.count)), keys: eCtx)
        var weight = [Int](repeating: 0, count: words + 1)
        for id in 0..<words {
            var w = 0
            for k in ctxPost.range(Int32(id), Int32(id + 1)) { w += ctxRows.range(ctxPost.items[k], ctxPost.items[k] + 1).count }
            weight[id + 1] = weight[id] + w
        }
        ctxWeight = weight
        sNamePost = Postings(keyCount: words, rowStart: sTokStart, keys: sTok)
        sLocPost = Postings(keyCount: words, rowStart: sLocStart, keys: sLocTok)
        built = [g.built] + (a.map { [$0.built] } ?? [])
        attributions = [g.attribution] + (a.map { [$0.attribution] } ?? [])
    }

    /// Reads one file with `read`; the version is checked first — also when
    /// the file no longer parses as this build expects (a newer shape).
    private static func parse<T: SearchFile>(_ data: Data, file: String,
                                             _ read: (inout SearchJSONReader) throws -> T) throws -> T {
        let parsed: Result<T, SearchJSONReader.Failure> = data.withUnsafeBytes { raw in
            var r = SearchJSONReader(raw)
            do {
                let v = try read(&r)
                try r.end()
                return .success(v)
            } catch let f as SearchJSONReader.Failure {
                return .failure(f)
            } catch {
                return .failure(.init(offset: r.i, reason: "\(error)"))
            }
        }
        switch parsed {
        case let .success(v):
            guard v.version == supportedVersion else {
                throw DataError.unsupportedVersion(file: file, found: v.version, supported: supportedVersion)
            }
            return v
        case let .failure(f):
            // valid JSON of another version = a newer file; broken JSON = damage
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let found = o["version"] as? Int
                if found != supportedVersion {
                    throw DataError.unsupportedVersion(file: file, found: found, supported: supportedVersion)
                }
            }
            throw DataError.malformed(file: file, reason: "\(f.reason) at byte \(f.offset)")
        }
    }

    /// Interning tables used only while building.
    private struct Builder {
        var wordIDs: [String: Int32] = [:]
        var wordList: [String] = []
        var nameNorms: [String: Int32] = [:]
        var placeNorms: [String: Int32] = [:]

        mutating func word(_ w: String) -> Int32 {
            if let id = wordIDs[w] { return id }
            let id = Int32(wordList.count)
            wordIDs[w] = id
            wordList.append(w)
            return id
        }
        mutating func words(_ norm: String, into out: inout [Int32]) {
            guard !norm.isEmpty else { return }
            for w in norm.split(separator: " ") { out.append(word(String(w))) }
        }
        mutating func nameNormID(_ s: String) -> Int32 { Self.intern(s, &nameNorms) }
        mutating func placeNormID(_ s: String) -> Int32 { Self.intern(s, &placeNorms) }
        private static func intern(_ s: String, _ table: inout [String: Int32]) -> Int32 {
            if let id = table[s] { return id }
            let id = Int32(table.count)
            table[s] = id
            return id
        }
        /// The words in byte order, and provisional id → rank.
        func sortedVocabulary() -> ([String], [Int32]) {
            let order = wordList.indices.sorted { wordList[$0].utf8.lexicographicallyPrecedes(wordList[$1].utf8) }
            var rank = [Int32](repeating: 0, count: wordList.count)
            for (r, i) in order.enumerated() { rank[i] = Int32(r) }
            return (order.map { wordList[$0] }, rank)
        }
    }
}

public extension BundledData {
    /// The search index from this folder's `search/` subfolder (background thread).
    func searchIndex() async throws -> SearchIndex { try await SearchIndex.load(from: self) }
}

/// A compressed inverted list: key k → items[start[k] ..< start[k+1]],
/// items ascending within a key.
struct Postings: Sendable {
    let start: [Int32]
    let items: [Int32]

    /// Row r holds keys[rowStart[r] ..< rowStart[r+1]]; each (key, r) becomes a posting.
    init(keyCount: Int, rowStart: [Int32], keys: [Int32]) {
        var start = [Int32](repeating: 0, count: keyCount + 1)
        for k in keys { start[Int(k) + 1] += 1 }
        for k in 0..<keyCount { start[k + 1] += start[k] }
        var fill = start
        var items = [Int32](repeating: 0, count: keys.count)
        for r in 0..<max(0, rowStart.count - 1) {
            for j in Int(rowStart[r])..<Int(rowStart[r + 1]) {
                let k = Int(keys[j])
                items[Int(fill[k])] = Int32(r)
                fill[k] += 1
            }
        }
        self.start = start
        self.items = items
    }

    /// Posting positions of the keys lo ..< hi.
    func range(_ lo: Int32, _ hi: Int32) -> Range<Int> { Int(start[Int(lo)])..<Int(start[Int(hi)]) }
}

// MARK: - file shapes (version 1)

protocol SearchFile { var version: Int? { get } }

/// gazetteer.json: `{version, built, attribution, types[], groups[],
/// typeGroup[], places[], munis[], rows[]}`; a row is `[name, typeIdx,
/// placeIdx, muniIdx, lat5, lon5, bboxDelta?]` in 1e-5° with bbox =
/// `[w−lon5, s−lat5, e−lon5, n−lat5]`.
struct RawGazetteer: SearchFile {
    var version: Int?
    var built = "", attribution = ""
    var types: [String] = [], groups: [String] = [], places: [String] = [], munis: [String] = []
    var typeGroup: [Int] = []
    var names: [String] = []
    /// typeIdx, placeIdx, muniIdx, lat5, lon5 per row.
    var ints: [Int32] = []
    /// Absolute [w, s, e, n] per row (zeros where `hasBox` is false).
    var boxes: [Int32] = []
    var hasBox: [Bool] = []

    static func read(_ r: inout SearchJSONReader) throws -> RawGazetteer {
        var g = RawGazetteer()
        var sawRows = false
        try r.object { r, key in
            switch key {
            case "version": g.version = try r.int()
            case "built": g.built = try r.string()
            case "attribution": g.attribution = try r.string()
            case "types": g.types = try r.stringArray()
            case "groups": g.groups = try r.stringArray()
            case "places": g.places = try r.stringArray()
            case "munis": g.munis = try r.stringArray()
            case "typeGroup": g.typeGroup = try r.intArray()
            case "rows":
                sawRows = true
                try r.array { r in
                    var k = 0
                    var lat5 = 0, lon5 = 0
                    try r.array { r in
                        switch k {
                        case 0: g.names.append(try r.string())
                        case 1...5:
                            let x = try r.int32()
                            g.ints.append(x)
                            if k == 4 { lat5 = Int(x) } else if k == 5 { lon5 = Int(x) }
                        case 6:
                            let d = try r.intArray()
                            guard d.count == 4 else { throw SearchJSONReader.Failure(offset: r.i, reason: "bbox delta of \(d.count)") }
                            g.boxes.append(contentsOf: [lon5 + d[0], lat5 + d[1], lon5 + d[2], lat5 + d[3]].map { Int32(truncatingIfNeeded: $0) })
                            g.hasBox.append(true)
                        default: try r.skipValue()
                        }
                        k += 1
                    }
                    guard k >= 6 else { throw SearchJSONReader.Failure(offset: r.i, reason: "row of \(k) values") }
                    if k == 6 {
                        g.boxes.append(contentsOf: [0, 0, 0, 0])
                        g.hasBox.append(false)
                    }
                }
            default: try r.skipValue()
            }
        }
        guard sawRows else { throw SearchJSONReader.Failure(offset: r.i, reason: "no rows") }
        return g
    }
}

/// addresses.json: `{version, built, attribution, streets[]}`; a street is
/// `[street, locality, lon0_5, lat0_5, numbers[], dlon[], dlat[]]` — numbers
/// ascending (strings like "15A" carry a suffix), coordinate i = the
/// cumulative sum of the deltas from (lon0, lat0), first delta 0.
struct RawAddresses: SearchFile {
    var version: Int?
    var built = "", attribution = ""
    var names: [String] = [], localities: [String] = []
    var lon0: [Int32] = [], lat0: [Int32] = []
    var numStart: [Int32] = [0]
    var numValue: [Int32] = []
    var numText: [Int32: String] = [:]
    var dLon: [Int32] = [], dLat: [Int32] = []

    static func read(_ r: inout SearchJSONReader) throws -> RawAddresses {
        var a = RawAddresses()
        var sawStreets = false
        try r.object { r, key in
            switch key {
            case "version": a.version = try r.int()
            case "built": a.built = try r.string()
            case "attribution": a.attribution = try r.string()
            case "streets":
                sawStreets = true
                try r.array { r in
                    var k = 0
                    try r.array { r in
                        switch k {
                        case 0: a.names.append(try r.string())
                        case 1: a.localities.append(try r.string())
                        case 2: a.lon0.append(try r.int32())
                        case 3: a.lat0.append(try r.int32())
                        case 4:
                            try r.array { r in
                                if r.nextIsString {
                                    let s = try r.string()
                                    a.numText[Int32(a.numValue.count)] = s
                                    a.numValue.append(SearchText.leadingInt(s).map { Int32(clamping: $0) } ?? .min)
                                } else {
                                    a.numValue.append(Int32(clamping: try r.int()))
                                }
                            }
                            a.numStart.append(Int32(a.numValue.count))
                        case 5: try r.array { a.dLon.append(try $0.int32()) }
                        case 6: try r.array { a.dLat.append(try $0.int32()) }
                        default: try r.skipValue()
                        }
                        k += 1
                    }
                    let total = a.numValue.count
                    guard k >= 7, a.names.count == a.numStart.count - 1, a.dLon.count == total, a.dLat.count == total,
                          a.numStart[a.numStart.count - 1] > a.numStart[a.numStart.count - 2]
                    else { throw SearchJSONReader.Failure(offset: r.i, reason: "bad street \(a.names.last ?? "?")") }
                }
            default: try r.skipValue()
            }
        }
        guard sawStreets else { throw SearchJSONReader.Failure(offset: r.i, reason: "no streets") }
        return a
    }
}
