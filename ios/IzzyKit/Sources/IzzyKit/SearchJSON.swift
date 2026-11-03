import Foundation

/// A minimal pull reader for the two search files: JSONSerialization +
/// NSNumber bridging spent ~200 ms of a ~250 ms index build on ~800k small
/// numbers; walking the bytes directly takes a fraction of that. Handles all
/// of JSON (strings with escapes, numbers, literals, nesting) but only hands
/// out what the search build needs: ints, strings and structure.
struct SearchJSONReader {
    struct Failure: Error { var offset: Int; var reason: String }

    private let b: UnsafeRawBufferPointer
    private(set) var i = 0

    init(_ bytes: UnsafeRawBufferPointer) { b = bytes }

    private func fail(_ reason: String) -> Failure { Failure(offset: i, reason: reason) }

    mutating func skipSpace() {
        while i < b.count {
            switch b[i] {
            case 0x20, 0x0A, 0x0D, 0x09: i += 1
            default: return
            }
        }
    }

    /// The next significant byte (0 at the end).
    mutating func peek() -> UInt8 {
        skipSpace()
        return i < b.count ? b[i] : 0
    }

    mutating func expect(_ c: UInt8) throws {
        guard peek() == c else { throw fail("expected \(Character(Unicode.Scalar(c)))") }
        i += 1
    }

    /// Iterates an array's elements; `element` must consume exactly one value.
    mutating func array(_ element: (inout SearchJSONReader) throws -> Void) throws {
        try expect(0x5B) // [
        if peek() == 0x5D { i += 1; return }
        while true {
            try element(&self)
            switch peek() {
            case 0x2C: i += 1 // ,
            case 0x5D: i += 1; return // ]
            default: throw fail("expected , or ]")
            }
        }
    }

    /// Iterates an object's members; `member` must consume the value.
    mutating func object(_ member: (inout SearchJSONReader, String) throws -> Void) throws {
        try expect(0x7B) // {
        if peek() == 0x7D { i += 1; return }
        while true {
            let key = try string()
            try expect(0x3A) // :
            try member(&self, key)
            switch peek() {
            case 0x2C: i += 1
            case 0x7D: i += 1; return
            default: throw fail("expected , or }")
            }
        }
    }

    /// An integer (a fraction or exponent is refused: the files hold none).
    mutating func int() throws -> Int {
        skipSpace()
        var neg = false
        if i < b.count, b[i] == 0x2D { neg = true; i += 1 }
        let start = i
        var n = 0
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
            let (m, o1) = n.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int(b[i] - 0x30))
            guard !o1, !o2 else { throw fail("integer overflow") }
            n = s
            i += 1
        }
        guard i > start else { throw fail("expected an integer") }
        if i < b.count, b[i] == 0x2E || b[i] == 0x65 || b[i] == 0x45 { throw fail("expected an integer") }
        return neg ? -n : n
    }

    mutating func int32() throws -> Int32 {
        let v = try int()
        guard let x = Int32(exactly: v) else { throw fail("value out of range") }
        return x
    }

    var nextIsString: Bool { mutating get { peek() == 0x22 } }
    var nextIsNull: Bool { mutating get { peek() == 0x6E } }

    mutating func string() throws -> String {
        try expect(0x22)
        let start = i
        // fast path: no escapes
        while i < b.count, b[i] != 0x22, b[i] != 0x5C { i += 1 }
        guard i < b.count else { throw fail("unterminated string") }
        if b[i] == 0x22 {
            let s = String(decoding: UnsafeRawBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
            i += 1
            return s
        }
        var out = [UInt8](UnsafeRawBufferPointer(rebasing: b[start..<i]))
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { break }
            let e = b[i]
            i += 1
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var u = try hex4()
                if (0xD800..<0xDC00).contains(u), i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                    i += 2
                    let lo = try hex4()
                    if (0xDC00..<0xE000).contains(lo) { u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00) }
                }
                out.append(contentsOf: String(Unicode.Scalar(UInt32(u)).map(Character.init) ?? "\u{FFFD}").utf8)
            default: throw fail("bad escape")
            }
        }
        throw fail("unterminated string")
    }

    private mutating func hex4() throws -> Int {
        guard i + 4 <= b.count else { throw fail("bad \\u escape") }
        var v = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: Int
            switch c {
            case 0x30...0x39: d = Int(c - 0x30)
            case 0x41...0x46: d = Int(c - 0x41 + 10)
            case 0x61...0x66: d = Int(c - 0x61 + 10)
            default: throw fail("bad \\u escape")
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    /// Skips one value of any kind.
    mutating func skipValue() throws {
        switch peek() {
        case 0x22: _ = try string()
        case 0x5B: try array { try $0.skipValue() }
        case 0x7B: try object { r, _ in try r.skipValue() }
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default:
            // a number of any form
            let start = i
            while i < b.count, b[i] == 0x2D || b[i] == 0x2B || b[i] == 0x2E || b[i] == 0x65 || b[i] == 0x45
                || (b[i] >= 0x30 && b[i] <= 0x39) { i += 1 }
            guard i > start else { throw fail("unexpected byte") }
        }
    }

    mutating func literal(_ word: StaticString) throws {
        skipSpace()
        let n = word.utf8CodeUnitCount
        guard i + n <= b.count else { throw fail("bad literal") }
        for k in 0..<n where b[i + k] != word.utf8Start[k] { throw fail("bad literal") }
        i += n
    }

    mutating func end() throws {
        guard peek() == 0 else { throw fail("trailing bytes") }
    }

    mutating func stringArray() throws -> [String] {
        var out: [String] = []
        try array { out.append(try $0.string()) }
        return out
    }

    mutating func intArray() throws -> [Int] {
        var out: [Int] = []
        try array { out.append(try $0.int()) }
        return out
    }
}
