import Foundation

// The query side of SearchIndex — a line-for-line port of the web app's
// search() (app/src/search.ts, 2026-09 → 2026-10), scoring included. The
// only structural change is speed: words are vocabulary ids (a typed word =
// an id range), hits stay index records until the final top-`limit` rows
// are turned into SearchResults.

extension SearchIndex {
    /// Word-prefix search over place names, streets and street addresses.
    ///
    /// Every typed word must hit a name word (exact 3 / prefix 2, +1 when the
    /// first typed word hits the first name word) or, failing that, a
    /// locality / council word (prefix, 1); a whole-name match adds 3. Ties
    /// rank by distance from `near`, then by name. Fewer than two letters
    /// (after normalisation) answer nothing.
    public func search(query: String, near: GeoPoint? = nil, limit: Int = 30) -> [SearchResult] {
        let norm = SearchText.normalise(SearchText.stripUnitAndRange(query))
        guard norm.utf8.count >= 2, limit > 0 else { return [] }
        let all = SearchText.words(norm)
        let km: (Double, Double) -> Double? = near.map { c in
            { lat, lon in SearchText.km(lat1: c.latitude, lon1: c.longitude, lat2: lat, lon2: lon) }
        } ?? { _, _ in nil }
        var hits: [Hit] = []

        // "12 elizabeth st hobart": the number picks an address on the
        // streets the other words match; those words still run against the
        // gazetteer below.
        let (num, tokens, numAtEnd) = SearchText.splitHouseNumber(all)
        if let num, hasAddresses { addressHits(num, tokens, km, limit, into: &hits) }

        // Name-index query variants: the words without the number and, for
        // "7 mile beach", the number spelt out where it stood — "seven" earns
        // Seven Mile Beach the first-word and whole-name bonuses that the
        // address "7 Seven Mile Beach Road" (+4) would otherwise beat.
        var variants = [tokens]
        if let num, let word = SearchText.numberWords[num] {
            variants.append(numAtEnd ? tokens + [word] : [word] + tokens)
        }
        let scorers = variants.map { v in
            Scorer(
                qs: v.map(candidates),
                expanded: exactIDs(v.map { SearchText.abbreviations[$0] ?? $0 }),
                joined: exactIDs(v)
            )
        }
        let streetWord = tokens.contains { SearchText.streetWords.contains($0) }

        // "name|place" of every register / street row in the result and of
        // each Property row: a Property twinning a register row is dropped
        // before the final sort (below)
        var shownKeys = Set<Int64>()
        func entryHit(_ i: Int, _ score: Double) -> Hit {
            let lat = Double(eLat5[i]) / 1e5, lon = Double(eLon5[i]) / 1e5
            let key = Self.key(eNorm[i], placeNormOf(i))
            let property = eFlags[i] & Self.isProperty != 0
            if !property { shownKeys.insert(key) }
            return Hit(source: .entry(i), score: score, km: km(lat, lon), lat: lat, lon: lon, key: key, property: property)
        }

        var matched = [Bool](repeating: false, count: eName.count)
        let streetScan = hasAddresses && num == nil
        var roadNames = Set<Int32>() // normalised names of matched register roads…
        var roadKeys = Set<Int64>() // …and "name|place" of each such row
        var official = false // any non-Property row matched
        let qs0 = scorers[0].qs // every variant holds these words
        for i in entryCandidates(qs0) {
            let s0 = (eTokStart[i], eTokStart[i + 1]), c = eCtx[i]
            guard let r = best(scorers, eTok, s0, ctxTok, (ctxStart[Int(c)], ctxStart[Int(c) + 1])) else { continue }
            var s = Double(r.score)
            let flags = eFlags[i]
            if flags & Self.isProperty != 0 {
                // property names rank below official names, and a property
                // that merely IS the typed word ("Salamanca", a farm) must not
                // outrank the Salamanca Square everyone means: a token
                // whole-name bonus only
                s += (r.whole ? 1 : 0) - 0.5
            } else {
                if r.whole { s += 3 } // the whole name, exactly
                official = true
                if flags & Self.isTransport != 0 {
                    // a road shares its name with the suburb / hill / bay it
                    // is named after — the place ranks first unless the user
                    // typed a street word, which then puts the ROAD ahead of
                    // the pier (Transport too) or park of that name
                    s += streetWord ? (flags & Self.isRoad != 0 ? 1 : 0) : -1
                    if streetScan {
                        roadNames.insert(eNorm[i])
                        roadKeys.insert(Self.key(eNorm[i], placeNormOf(i)))
                    }
                }
            }
            matched[i] = true
            hits.append(entryHit(i, s))
        }

        // Suburb-qualified streets ("elizabeth st north hobart"): the
        // register holds a road once, under one place, so the address file's
        // per-suburb rows fill in — only where a typed word named the suburb,
        // or the register has no such road at all (plain "elizabeth st" must
        // not grow twenty duplicate rows); a row the register already has is
        // dropped, the register's bbox being the better frame. Ties go to the
        // register.
        if streetScan {
            var cands: [(st: Int, s: Double, km: Double?)] = []
            for st in streetCandidates(qs0) {
                guard let r = best(scorers, sTok, (sTokStart[st], sTokStart[st + 1]),
                                   sLocTok, (sLocStart[st], sLocStart[st + 1])) else { continue }
                if roadKeys.contains(Self.key(sNorm[st], sLocNorm[st])) { continue }
                if !r.ctx && roadNames.contains(sNorm[st]) { continue }
                let s = Double(r.score + (r.whole ? 3 : 0) + (streetWord ? 1 : -1)) - 0.25
                cands.append((st, s, km(Double(sLat0[st]) / 1e5, Double(sLon0[st]) / 1e5)))
            }
            if !cands.isEmpty { official = true }
            let order = cands.indices.sorted { a, b in
                let x = cands[a], y = cands[b]
                if x.s != y.s { return x.s > y.s }
                let dx = x.km ?? 0, dy = y.km ?? 0
                return dx != dy ? dx < dy : a < b
            }
            for o in order.prefix(limit) {
                let c = cands[o]
                let mid = streetCoord(c.st, Int(sNumStart[c.st + 1] - sNumStart[c.st]) >> 1)
                let key = Self.key(sNorm[c.st], sLocNorm[c.st])
                shownKeys.insert(key)
                hits.append(Hit(source: .street(c.st), score: c.s, km: km(mid.lat, mid.lon),
                                lat: mid.lat, lon: mid.lon, key: key, property: false))
            }
        }

        // substring tier (mid-word typos, "ellington"): only when the prefix
        // tier left room and a word is long enough to mean something
        if hits.count < limit, tokens.contains(where: { $0.utf8.count >= 3 }) {
            let masks = tokens.map { t in substringMask(SearchText.forms(t)) }
            // rows holding a word of the rarest mask, ascending
            func postings(_ m: [Bool]) -> Int {
                var c = 0
                for id in m.indices where m[id] { c += eNamePost.range(Int32(id), Int32(id + 1)).count }
                return c
            }
            let rare = masks.min { postings($0) < postings($1) }!
            var mark = [Bool](repeating: false, count: eName.count)
            for id in rare.indices where rare[id] {
                for k in eNamePost.range(Int32(id), Int32(id + 1)) { mark[Int(eNamePost.items[k])] = true }
            }
            for i in collect(mark) where !matched[i] {
                let lo = Int(eTokStart[i]), hi = Int(eTokStart[i + 1])
                if masks.allSatisfy({ m in (lo..<hi).contains { m[Int(eTok[$0])] } }) {
                    hits.append(entryHit(i, 0.5))
                }
            }
        }
        // properties trail whenever anything official answered the query
        if official { for k in hits.indices where hits[k].property { hits[k].score -= 2 } }
        // Some 430 register names (2026-09) recur as a Property row of the
        // same name and place ("Elizabeth Street Pier": Pier and Property,
        // both Hobart; most are parks and cemeteries) — the register row
        // alone is shown. Address rows are not keyed: nothing twins them.
        hits.removeAll { $0.property && shownKeys.contains($0.key) }
        return top(hits, limit, num).map { result($0, num) }
    }

    // MARK: - internals

    /// One typed word's form resolved against the vocabulary: the id of the
    /// word itself (-1 when absent) and the id range of the words it prefixes.
    struct Cand { var exact: Int32; var lo: Int32; var hi: Int32 }
    struct Scorer {
        var qs: [[Cand]]
        /// Word ids of the variant with abbreviations expanded / as typed —
        /// nil when a word is in no name (then no name equals it).
        var expanded: [Int32]?
        var joined: [Int32]?
    }
    enum Source { case entry(Int), street(Int), address(street: Int, number: Int, exact: Bool) }
    struct Hit {
        var source: Source
        var score: Double
        var km: Double?
        var lat: Double
        var lon: Double
        var key: Int64
        var property: Bool
    }

    static func key(_ name: Int32, _ place: Int32) -> Int64 { Int64(name) << 32 | Int64(UInt32(bitPattern: place)) }

    func placeNormOf(_ i: Int) -> Int32 {
        let p = Int(ePlace[i])
        return p >= 0 && p < placeNorm.count ? placeNorm[p] : -1
    }

    /// The forms of one typed word, resolved.
    func candidates(_ t: String) -> [Cand] { SearchText.forms(t).map(resolve) }

    func resolve(_ c: String) -> Cand {
        let bytes = Array(c.utf8)
        let lo = lowerBound(bytes)
        let exact = lo < vocab.count && compareWord(lo, bytes) == 0 ? Int32(lo) : -1
        // every word is [a-z0-9]: all words with this prefix sort before c + "{"
        let hi = lowerBound(bytes + [0x7B])
        return Cand(exact: exact, lo: Int32(lo), hi: Int32(hi))
    }

    func exactIDs(_ words: [String]) -> [Int32]? {
        var out: [Int32] = []
        for w in words {
            let c = resolve(w)
            guard c.exact >= 0 else { return nil }
            out.append(c.exact)
        }
        return out
    }

    /// First word id whose word is ≥ `bytes` (byte order, as the vocabulary is sorted).
    private func lowerBound(_ bytes: [UInt8]) -> Int {
        var lo = 0, hi = vocab.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareWord(mid, bytes) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func compareWord(_ id: Int, _ bytes: [UInt8]) -> Int {
        let s = Int(vocabStart[id]), e = Int(vocabStart[id + 1])
        let n = min(e - s, bytes.count)
        for k in 0..<n where vocabBytes[s + k] != bytes[k] {
            return vocabBytes[s + k] < bytes[k] ? -1 : 1
        }
        return (e - s) - bytes.count
    }

    /// Every query word must hit a name word (exact 3 / prefix 2, +1 when the
    /// first typed word hits the first name word) or, failing that, a context
    /// word (locality / council, prefix, 1). 0 = no match. `ctx` reports
    /// whether any word was carried by the context alone.
    @inline(__always)
    func scoreTokens(_ qs: [[Cand]], _ name: [Int32], _ nr: (Int32, Int32),
                     _ ctx: [Int32], _ cr: (Int32, Int32), _ usedCtx: inout Bool) -> Int {
        var total = 0
        usedCtx = false
        let nlo = Int(nr.0), nhi = Int(nr.1)
        for qi in qs.indices {
            let cands = qs[qi]
            var best = 0
            for ni in nlo..<nhi {
                let n = name[ni]
                for c in cands {
                    var s = n == c.exact ? 3 : (n >= c.lo && n < c.hi ? 2 : 0)
                    if s == 0 { continue }
                    if qi == 0 && ni == nlo { s += 1 }
                    if s > best { best = s }
                }
            }
            if best == 0 {
                ctxLoop: for xi in Int(cr.0)..<Int(cr.1) {
                    let x = ctx[xi]
                    for c in cands where x >= c.lo && x < c.hi {
                        best = 1
                        usedCtx = true
                        break ctxLoop
                    }
                }
                if best == 0 { return 0 }
            }
            total += best
        }
        return total
    }

    /// Best variant for one name: raw token score, whether it is the whole
    /// name exactly, whether context alone carried a word. nil = no match.
    func best(_ scorers: [Scorer], _ name: [Int32], _ nr: (Int32, Int32),
              _ ctx: [Int32], _ cr: (Int32, Int32)) -> (score: Int, whole: Bool, ctx: Bool)? {
        var r: (score: Int, whole: Bool, ctx: Bool) = (0, false, false)
        var flag = false
        for v in scorers {
            let s = scoreTokens(v.qs, name, nr, ctx, cr, &flag)
            if s == 0 { continue }
            let whole = equals(name, nr, v.expanded) || equals(name, nr, v.joined)
            if s + (whole ? 3 : 0) > r.score + (r.whole ? 3 : 0) { r = (s, whole, flag) }
        }
        return r.score > 0 ? r : nil
    }

    private func equals(_ name: [Int32], _ nr: (Int32, Int32), _ ids: [Int32]?) -> Bool {
        guard let ids, Int(nr.1 - nr.0) == ids.count else { return false }
        for k in ids.indices where name[Int(nr.0) + k] != ids[k] { return false }
        return true
    }

    /// Word ids (as a mask over the vocabulary) containing any of `forms`.
    func substringMask(_ forms: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: vocab.count)
        vocabBytes.withUnsafeBufferPointer { buf in
            for f in forms {
                let p = Array(f.utf8)
                guard let first = p.first else { continue }
                for id in 0..<vocab.count where !mask[id] {
                    let s = Int(vocabStart[id]), e = Int(vocabStart[id + 1])
                    if e - s < p.count { continue }
                    var k = s
                    while k + p.count <= e {
                        if buf[k] == first {
                            var j = 1
                            while j < p.count && buf[k + j] == p[j] { j += 1 }
                            if j == p.count { mask[id] = true; break }
                        }
                        k += 1
                    }
                }
            }
        }
        return mask
    }

    // MARK: candidate rows

    /// Rows that can match: those reachable from the most selective typed
    /// word (through a name word or a context word it prefixes) — a row must
    /// match every word, so it must match that one. Ascending, like a full scan.
    func entryCandidates(_ qs: [[Cand]]) -> [Int] {
        let n = eName.count
        func cost(_ cands: [Cand]) -> Int {
            cands.reduce(0) { $0 + eNamePost.range($1.lo, $1.hi).count + ctxWeight[Int($1.hi)] - ctxWeight[Int($1.lo)] }
        }
        guard let pick = qs.min(by: { cost($0) < cost($1) }), cost(pick) < n / 2 else { return Array(0..<n) }
        var mark = [Bool](repeating: false, count: n)
        for c in pick {
            for k in eNamePost.range(c.lo, c.hi) { mark[Int(eNamePost.items[k])] = true }
            for k in ctxPost.range(c.lo, c.hi) {
                let g = ctxPost.items[k]
                for j in ctxRows.range(g, g + 1) { mark[Int(ctxRows.items[j])] = true }
            }
        }
        return collect(mark)
    }

    /// The same for address-file streets (name or locality words).
    func streetCandidates(_ qs: [[Cand]]) -> [Int] {
        let n = sName.count
        func cost(_ cands: [Cand]) -> Int {
            cands.reduce(0) { $0 + sNamePost.range($1.lo, $1.hi).count + sLocPost.range($1.lo, $1.hi).count }
        }
        guard let pick = qs.min(by: { cost($0) < cost($1) }), cost(pick) < n / 2 else { return Array(0..<n) }
        var mark = [Bool](repeating: false, count: n)
        for c in pick {
            for k in sNamePost.range(c.lo, c.hi) { mark[Int(sNamePost.items[k])] = true }
            for k in sLocPost.range(c.lo, c.hi) { mark[Int(sLocPost.items[k])] = true }
        }
        return collect(mark)
    }

    private func collect(_ mark: [Bool]) -> [Int] {
        var out: [Int] = []
        for i in mark.indices where mark[i] { out.append(i) }
        return out
    }

    // MARK: addresses

    /// House number `index` of street `st` (flat index into the number tables).
    func numberText(_ flat: Int) -> String { numText[Int32(flat)] ?? String(numValue[flat]) }

    /// Coordinate of a street's `i`-th house number: the cumulative sum of
    /// the deltas from (lon0, lat0), in degrees.
    func streetCoord(_ st: Int, _ i: Int) -> (lon: Double, lat: Double) {
        var lon = Int(sLon0[st]), lat = Int(sLat0[st])
        let base = Int(sNumStart[st])
        for k in base...(base + i) {
            lon += Int(dLon[k])
            lat += Int(dLat[k])
        }
        return (Double(lon) / 1e5, Double(lat) / 1e5)
    }

    /// Extent of all of a street's numbers.
    func streetBBox(_ st: Int) -> SearchBBox {
        var lon = Int(sLon0[st]), lat = Int(sLat0[st])
        var w = Int.max, s = Int.max, e = Int.min, n = Int.min
        for k in Int(sNumStart[st])..<Int(sNumStart[st + 1]) {
            lon += Int(dLon[k])
            lat += Int(dLat[k])
            w = min(w, lon); e = max(e, lon); s = min(s, lat); n = max(n, lat)
        }
        return SearchBBox(west: Double(w) / 1e5, south: Double(s) / 1e5, east: Double(e) / 1e5, north: Double(n) / 1e5)
    }

    func addressHits(_ num: String, _ rest: [String], _ km: (Double, Double) -> Double?, _ limit: Int,
                     into hits: inout [Hit]) {
        let qs = rest.map(candidates)
        var scored: [(st: Int, s: Int, km: Double?)] = []
        var flag = false
        for st in streetCandidates(qs) {
            let s = scoreTokens(qs, sTok, (sTokStart[st], sTokStart[st + 1]), sLocTok, (sLocStart[st], sLocStart[st + 1]), &flag)
            if s > 0 { scored.append((st, s, km(Double(sLat0[st]) / 1e5, Double(sLon0[st]) / 1e5))) }
        }
        let order = scored.indices.sorted { a, b in
            let x = scored[a], y = scored[b]
            if x.s != y.s { return x.s > y.s }
            let dx = x.km ?? 0, dy = y.km ?? 0
            return dx != dy ? dx < dy : a < b
        }
        // JS numbers: a 20-digit "house number" must not overflow (Double, as parseInt)
        let want = Double(String(num.prefix { $0.isASCII && $0.isNumber })) ?? 0
        for o in order.prefix(limit) {
            let (st, s, _) = scored[o]
            let base = Int(sNumStart[st]), count = Int(sNumStart[st + 1]) - base
            var i = (0..<count).first { numberText(base + $0).lowercased() == num } ?? -1
            let exact = i >= 0
            if !exact {
                // nearest by numeric part; ties → the plain number, then the lower one
                var bestD = Double.infinity
                for j in 0..<count {
                    let v = numValue[base + j]
                    if v == .min { continue } // NaN never compares
                    let d = abs(Double(v) - want)
                    let isNumber = numText[Int32(base + j)] == nil
                    let iIsNumber = i >= 0 && numText[Int32(base + i)] == nil
                    if d < bestD || (d == bestD && isNumber && !iIsNumber) {
                        bestD = d
                        i = j
                    }
                }
            }
            if i < 0 { continue }
            let (lon, lat) = streetCoord(st, i)
            // A typed house number is the strongest intent signal: +4
            // outranks the gazetteer's whole-name-exact bonus (+3) for the
            // same street. An exact number adds 1; a stand-in loses ground
            // with its distance in house numbers — "nearest: 14" for a typed
            // 12 is a fair answer, the "nearest: 249" of the same street's
            // next suburb is not, whatever the map centre says.
            let off = exact ? 0 : min(0.9, abs(Double(numValue[base + i]) - want) / 100)
            hits.append(Hit(source: .address(street: st, number: base + i, exact: exact),
                            score: Double(s) + 4 + (exact ? 1 : -off), km: km(lat, lon),
                            lat: lat, lon: lon, key: -1, property: false))
        }
    }

    // MARK: ranking + results

    func name(of h: Hit, _ num: String?) -> String {
        switch h.source {
        case let .entry(i): eName[i]
        case let .street(st): sName[st]
        case let .address(st, _, _): "\((num ?? "").uppercased()) \(sName[st])"
        }
    }

    private static let collation = Locale(identifier: "en")

    /// The first `limit` hits by score (desc), distance (asc), name (locale
    /// order), then insertion order — the web's stable sort, but the name
    /// collation only runs on the rows that can reach the top.
    func top(_ hits: [Hit], _ limit: Int, _ num: String?) -> [Hit] {
        let cheap = hits.indices.sorted { a, b in
            let x = hits[a], y = hits[b]
            if x.score != y.score { return x.score > y.score }
            let dx = x.km ?? 0, dy = y.km ?? 0
            return dx != dy ? dx < dy : a < b
        }
        guard cheap.count > limit else { return finalOrder(cheap, hits, num).map { hits[$0] } }
        let last = hits[cheap[limit - 1]]
        var end = limit
        while end < cheap.count, hits[cheap[end]].score == last.score, (hits[cheap[end]].km ?? 0) == (last.km ?? 0) {
            end += 1
        }
        return finalOrder(Array(cheap[..<end]), hits, num).prefix(limit).map { hits[$0] }
    }

    private func finalOrder(_ idx: [Int], _ hits: [Hit], _ num: String?) -> [Int] {
        let names = Dictionary(uniqueKeysWithValues: idx.map { ($0, name(of: hits[$0], num)) })
        return idx.sorted { a, b in
            let x = hits[a], y = hits[b]
            if x.score != y.score { return x.score > y.score }
            let dx = x.km ?? 0, dy = y.km ?? 0
            if dx != dy { return dx < dy }
            let c = names[a]!.compare(names[b]!, locale: Self.collation)
            return c != .orderedSame ? c == .orderedAscending : a < b
        }
    }

    func result(_ h: Hit, _ num: String?) -> SearchResult {
        let point = GeoPoint(longitude: h.lon, latitude: h.lat)
        switch h.source {
        case let .entry(i):
            let ti = Int(eType[i])
            let type = ti >= 0 && ti < types.count ? types[ti] : ""
            let group = ti >= 0 && ti < typeGroupName.count ? typeGroupName[ti] : ""
            var bbox: SearchBBox?
            if eFlags[i] & Self.hasBox != 0 {
                bbox = SearchBBox(west: Double(eBox[4 * i]) / 1e5, south: Double(eBox[4 * i + 1]) / 1e5,
                                  east: Double(eBox[4 * i + 2]) / 1e5, north: Double(eBox[4 * i + 3]) / 1e5)
            }
            return SearchResult(id: "e\(i)", name: eName[i], type: type, group: group, meta: meta(i, type),
                                coordinate: point, bbox: bbox, score: h.score, distanceKm: h.km)
        case let .street(st):
            let n = Int(sNumStart[st + 1] - sNumStart[st])
            return SearchResult(id: "s\(st)", name: sName[st], type: "Road", group: "Transport", meta: "Road · \(sLocality[st])",
                                coordinate: point, bbox: n > 1 ? streetBBox(st) : nil, score: h.score, distanceKm: h.km)
        case let .address(st, flat, exact):
            // named by the typed number; a stand-in's own number goes in the meta
            let shown = exact ? nil : numberText(flat)
            return SearchResult(id: "a\(flat)", name: name(of: h, num), type: "Address", group: "Address",
                                meta: "Address · \(sLocality[st])" + (shown.map { " · nearest: \($0)" } ?? ""),
                                coordinate: point, bbox: nil, score: h.score, distanceKm: h.km)
        }
    }

    /// "Mountain · Wellington Park, Glenorchy". MUNY is verbatim and 149
    /// values are multi-council lists ("Glenorchy, Hobart, Kingborough"):
    /// show the first so a row stays one line (all of them still match as
    /// context words). Omit the place when empty or equal to the council
    /// ("Suburb · Hobart", not "Suburb · Hobart, Hobart").
    func meta(_ i: Int, _ type: String) -> String {
        let pi = Int(ePlace[i]), mi = Int(eMuni[i])
        let place = pi >= 0 && pi < places.count ? places[pi] : ""
        let muniAll = mi >= 0 && mi < munis.count ? munis[mi] : ""
        let muni = muniAll.components(separatedBy: ", ")[0]
        let ctx: String
        if !place.isEmpty && place != muni {
            ctx = [place, muni].filter { !$0.isEmpty }.joined(separator: ", ")
        } else {
            ctx = muni.isEmpty ? place : muni
        }
        return ctx.isEmpty ? type : "\(type) · \(ctx)"
    }
}
