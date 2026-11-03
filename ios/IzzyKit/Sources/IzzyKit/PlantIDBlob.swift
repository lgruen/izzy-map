import Foundation

/// A read-only memory map of a whole file: pages come in as they are read
/// and the kernel can drop them again under memory pressure (they are clean
/// file pages, not app memory), so an 85 MB kNN bank costs what is touched.
public final class MappedFile: @unchecked Sendable {
    public let url: URL
    public let count: Int
    /// Valid for the object's lifetime; never written.
    public let base: UnsafeRawPointer

    public init(url: URL) throws {
        self.url = url
        let fd = open(url.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { throw PlantIDError.unreadable(url.lastPathComponent, String(cString: strerror(errno))) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw PlantIDError.unreadable(url.lastPathComponent, "stat failed") }
        count = Int(st.st_size)
        guard count > 0 else { throw PlantIDError.malformed(url.lastPathComponent, "empty file") }
        let p = mmap(nil, count, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let p, p != MAP_FAILED else { throw PlantIDError.unreadable(url.lastPathComponent, "mmap failed") }
        base = UnsafeRawPointer(p)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), count) }
}

public enum PlantIDError: Error, Equatable, LocalizedError {
    case unreadable(String, String)
    case malformed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(file, why): "\(file) couldn’t be read (\(why))."
        case let .malformed(file, why): "\(file) isn’t a valid plant-ID file (\(why))."
        }
    }
}

/// One "IZPL" blob (pipeline/plantid/build_ship.py `write_blob`):
/// little-endian; bytes 0–3 "IZPL", 4–7 uint32 format version (1), 8–11
/// uint32 n = JSON header length, 12… the UTF-8 JSON header; the data
/// section starts at the next multiple of 64 and `header.arrays[name]` =
/// {dtype, shape, offset (from the data start, 64-aligned), bytes},
/// row-major. The rest of the header holds the file's parameters.
public struct IZPLBlob: @unchecked Sendable {
    public struct ArrayInfo: Sendable {
        public let dtype: String
        public let shape: [Int]
        public let offset: Int
        public let bytes: Int
        public var count: Int { shape.reduce(1, *) }
    }

    public let file: MappedFile
    /// The JSON header (parameters), arrays included.
    public let header: [String: Any]
    public let arrays: [String: ArrayInfo]
    let dataStart: Int

    public init(url: URL) throws {
        let file = try MappedFile(url: url)
        let name = url.lastPathComponent
        func bad(_ why: String) -> PlantIDError { .malformed(name, why) }
        guard file.count >= 12 else { throw bad("truncated") }
        let magic = Data(bytes: file.base, count: 4)
        guard magic == Data("IZPL".utf8) else { throw bad("bad magic") }
        let version = UInt32(littleEndian: file.base.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        guard version == 1 else { throw bad("format version \(version)") }
        let n = Int(UInt32(littleEndian: file.base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        guard 12 + n <= file.count else { throw bad("truncated header") }
        let json = Data(bytes: file.base + 12, count: n)
        guard let header = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let raw = header["arrays"] as? [String: [String: Any]]
        else { throw bad("unreadable header") }
        let start = (12 + n + 63) / 64 * 64
        var arrays: [String: ArrayInfo] = [:]
        for (key, e) in raw {
            guard let dtype = e["dtype"] as? String, let shape = e["shape"] as? [Int],
                  let offset = e["offset"] as? Int, let bytes = e["bytes"] as? Int
            else { throw bad("array \(key) has no dtype/shape/offset/bytes") }
            let info = ArrayInfo(dtype: dtype, shape: shape, offset: offset, bytes: bytes)
            guard let size = Self.itemSize[dtype], size * info.count == bytes else { throw bad("array \(key): \(dtype) × \(shape) ≠ \(bytes) bytes") }
            guard start + offset + bytes <= file.count, (start + offset) % size == 0 else { throw bad("array \(key) out of bounds") }
            arrays[key] = info
        }
        self.file = file
        self.header = header
        self.arrays = arrays
        dataStart = start
    }

    static let itemSize = ["float16": 2, "float32": 4, "float64": 8, "int8": 1, "uint8": 1, "uint16": 2, "uint32": 4,
                           "int16": 2, "int32": 4]

    /// The array's elements in place (aligned, little-endian = the host's).
    public func pointer<T>(_ name: String, _ type: T.Type, dtype: String) throws -> UnsafeBufferPointer<T> {
        guard let info = arrays[name] else { throw PlantIDError.malformed(file.url.lastPathComponent, "no array \(name)") }
        guard info.dtype == dtype else {
            throw PlantIDError.malformed(file.url.lastPathComponent, "\(name) is \(info.dtype), expected \(dtype)")
        }
        let p = (file.base + dataStart + info.offset).assumingMemoryBound(to: T.self)
        return UnsafeBufferPointer(start: p, count: info.count)
    }

    /// The array converted to Float (float16 / float32 / integer types).
    public func floats(_ name: String) throws -> [Float] {
        guard let info = arrays[name] else { throw PlantIDError.malformed(file.url.lastPathComponent, "no array \(name)") }
        switch info.dtype {
        case "float16": return try pointer(name, Float16.self, dtype: "float16").map(Float.init)
        case "float32": return Array(try pointer(name, Float.self, dtype: "float32"))
        case "uint16": return try pointer(name, UInt16.self, dtype: "uint16").map(Float.init)
        default: throw PlantIDError.malformed(file.url.lastPathComponent, "\(name): \(info.dtype) as floats")
        }
    }

    public func number(_ key: String) -> Double? { (header[key] as? NSNumber)?.doubleValue }
    public func int(_ key: String) -> Int? { (header[key] as? NSNumber)?.intValue }
}
