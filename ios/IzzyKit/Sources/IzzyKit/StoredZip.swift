import Foundation

/// A zip archive whose entries are all STORED (method 0, no compression) —
/// the container of the .docx export (`DocxWriter`, docs/PINS_PLAN.md §6).
/// JPEGs don't compress and the XML parts are small, so deflate would buy
/// nothing worth a dependency; a stored zip is just headers + bytes + CRC-32.
///
/// Layout (APPNOTE.TXT 6.3): per entry a local file header followed by its
/// bytes, then the central directory (one record per entry), then the
/// end-of-central-directory record. Names are flagged UTF-8 (bit 11). Every
/// entry carries the same caller-supplied DOS timestamp, so identical input
/// gives identical bytes.
///
/// No zip64: every 32-bit size and offset must stay below 0xFFFFFFFF (that
/// value, like 0xFFFF for the entry count, tells readers to look for zip64
/// fields). Anything that wouldn't fit THROWS before a byte is written —
/// never a silently truncated, corrupt archive. Built in memory (the export
/// is ≤ ~60 MB).
public enum StoredZip {
    public struct Entry: Sendable, Hashable {
        /// Archive path, "/"-separated, relative ("word/document.xml").
        public var path: String
        public var data: Data
        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    /// MS-DOS date and time as stored in zip headers (2-second resolution,
    /// 1980–2107). The format has no time zone; we pass UTC — what matters
    /// is that the same input gives the same bytes.
    public struct Timestamp: Sendable, Hashable {
        public let date: UInt16
        public let time: UInt16

        /// Out-of-range years clamp to 1980 / 2107; seconds round down to even.
        public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
            let y = min(max(year, 1980), 2107) - 1980
            date = UInt16(y << 9 | min(max(month, 1), 12) << 5 | min(max(day, 1), 31))
            time = UInt16(min(max(hour, 0), 23) << 11 | min(max(minute, 0), 59) << 5 | min(max(second, 0), 59) / 2)
        }

        public init(_ instant: Date, timeZone: TimeZone = .gmt) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
            self.init(year: c.year ?? 1980, month: c.month ?? 1, day: c.day ?? 1,
                      hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
        }
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// More entries than a non-zip64 archive can count (≥ 65,535).
        case tooManyEntries(Int)
        /// This entry (or the archive once it is added) would pass 4 GB.
        case tooLarge(path: String)
        /// Empty, absolute, "\\"-separated, NUL-holding, with an empty
        /// segment ("a//b", a trailing "/"), a segment ending in "." (which
        /// covers ".."), or longer than 65,535 UTF-8 bytes.
        case invalidPath(String)
        /// Equal to an earlier path ignoring case: OPC (the .docx package
        /// format) treats "A.xml" and "a.xml" as one part.
        case duplicatePath(String)

        public var description: String {
            switch self {
            case .tooManyEntries(let n): "zip: \(n) entries (a zip without zip64 holds at most 65,534)"
            case .tooLarge(let path): "zip: \(path) would push the archive past 4 GB (no zip64)"
            case .invalidPath(let path): "zip: invalid entry path \(path.debugDescription)"
            case .duplicatePath(let path): "zip: duplicate entry path \(path.debugDescription)"
            }
        }
    }

    /// The archive, entries in the given order.
    public static func archive(_ entries: [Entry], modified: Timestamp) throws -> Data {
        try archive(entries, modified: modified, limit: 0xFFFF_FFFE)
    }

    /// `limit` = the largest value a 32-bit size/offset field may hold
    /// (lowered by the tests to exercise the overflow checks cheaply).
    static func archive(_ entries: [Entry], modified: Timestamp, limit: UInt64) throws -> Data {
        guard entries.count < 0xFFFF else { throw Failure.tooManyEntries(entries.count) }

        // Validate and lay out everything before writing anything.
        var names: [Data] = []
        names.reserveCapacity(entries.count)
        var seen = Set<String>()
        var offset: UInt64 = 0
        var centralSize: UInt64 = 0
        for entry in entries {
            let path = entry.path
            let name = Data(path.utf8)
            // empty segments also catch "", "/abs" and "a/"; a final "." also ".."
            let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.contains("\\"), !path.contains("\u{0}"), name.count <= 0xFFFF,
                  segments.allSatisfy({ !$0.isEmpty && !$0.hasSuffix(".") })
            else { throw Failure.invalidPath(path) }
            guard seen.insert(path.lowercased()).inserted else { throw Failure.duplicatePath(path) }
            let size = UInt64(entry.data.count)
            // the local header's offset, the entry's size and the offset
            // right after it all have to fit
            guard size <= limit, offset <= limit else { throw Failure.tooLarge(path: path) }
            offset += UInt64(localHeaderLength + name.count) + size
            guard offset <= limit else { throw Failure.tooLarge(path: path) }
            centralSize += UInt64(centralHeaderLength + name.count)
            names.append(name)
        }
        guard centralSize <= limit, offset + centralSize <= limit else {
            throw Failure.tooLarge(path: entries.last?.path ?? "")
        }

        var out = Data()
        out.reserveCapacity(Int(offset + centralSize) + endRecordLength)
        var central = Data()
        central.reserveCapacity(Int(centralSize))
        for (entry, name) in zip(entries, names) {
            let localOffset = UInt32(out.count)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            out.le32(0x0403_4B50)           // local file header signature
            out.le16(versionNeeded)
            out.le16(flagUTF8)
            out.le16(0)                     // method: stored
            out.le16(modified.time)
            out.le16(modified.date)
            out.le32(crc)
            out.le32(size)                  // compressed size
            out.le32(size)                  // uncompressed size
            out.le16(UInt16(name.count))
            out.le16(0)                     // extra field length
            out.append(name)
            out.append(entry.data)

            central.le32(0x0201_4B50)       // central directory header signature
            central.le16(versionNeeded)     // version made by: 2.0, MS-DOS attributes
            central.le16(versionNeeded)
            central.le16(flagUTF8)
            central.le16(0)
            central.le16(modified.time)
            central.le16(modified.date)
            central.le32(crc)
            central.le32(size)
            central.le32(size)
            central.le16(UInt16(name.count))
            central.le16(0)                 // extra field length
            central.le16(0)                 // comment length
            central.le16(0)                 // disk number start
            central.le16(0)                 // internal attributes
            central.le32(0)                 // external attributes
            central.le32(localOffset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)

        out.le32(0x0605_4B50)               // end of central directory signature
        out.le16(0)                         // this disk
        out.le16(0)                         // disk with the central directory
        out.le16(UInt16(entries.count))     // entries on this disk
        out.le16(UInt16(entries.count))     // entries in total
        out.le32(UInt32(central.count))
        out.le32(centralOffset)
        out.le16(0)                         // comment length
        return out
    }

    static let localHeaderLength = 30
    static let centralHeaderLength = 46
    static let endRecordLength = 22
    private static let versionNeeded: UInt16 = 20
    private static let flagUTF8: UInt16 = 1 << 11

    // MARK: CRC-32

    /// CRC-32 as zip (and PNG, gzip) use it: reflected polynomial
    /// 0xEDB88320, initial value and final XOR 0xFFFFFFFF.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

extension Data {
    fileprivate mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    fileprivate mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
