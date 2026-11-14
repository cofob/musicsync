import Foundation

public enum BinaryError: Error, Equatable {
    case outOfBounds(offset: Int, count: Int)
    case badTag(expected: String, found: String, offset: Int)
}

/// Little-endian reader over `Data` with absolute and sequential access.
public struct BinaryReader {
    public let data: Data
    public var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    public func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw BinaryError.outOfBounds(offset: offset, count: count)
        }
        let start = data.startIndex + offset
        return data.subdata(in: start..<start + count)
    }

    public func uint<T: FixedWidthInteger>(_: T.Type, at offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        let raw = try bytes(at: offset, count: size)
        var value: T = 0
        for (i, byte) in raw.enumerated() { value |= T(truncatingIfNeeded: byte) << (8 * i) }
        return value
    }

    public func u8(at o: Int) throws -> UInt8 { try uint(UInt8.self, at: o) }
    public func u16(at o: Int) throws -> UInt16 { try uint(UInt16.self, at: o) }
    public func u32(at o: Int) throws -> UInt32 { try uint(UInt32.self, at: o) }
    public func u64(at o: Int) throws -> UInt64 { try uint(UInt64.self, at: o) }
    public func i16(at o: Int) throws -> Int16 { Int16(bitPattern: try u16(at: o)) }
    public func i32(at o: Int) throws -> Int32 { Int32(bitPattern: try u32(at: o)) }
    public func f32(at o: Int) throws -> Float { Float(bitPattern: try u32(at: o)) }

    /// 4-byte ASCII tag such as "mhbd".
    public func tag(at o: Int) throws -> String {
        String(decoding: try bytes(at: o, count: 4), as: UTF8.self)
    }

    public func expectTag(_ expected: String, at o: Int) throws {
        let found = try tag(at: o)
        guard found == expected else { throw BinaryError.badTag(expected: expected, found: found, offset: o) }
    }

    public func utf16le(at o: Int, byteCount: Int) throws -> String {
        let raw = try bytes(at: o, count: byteCount)
        return String(data: raw, encoding: .utf16LittleEndian) ?? ""
    }

    public func utf8(at o: Int, byteCount: Int) throws -> String {
        String(decoding: try bytes(at: o, count: byteCount), as: UTF8.self)
    }

    // Sequential helpers.
    public mutating func readU8() throws -> UInt8 { defer { offset += 1 }; return try u8(at: offset) }
    public mutating func readU16() throws -> UInt16 { defer { offset += 2 }; return try u16(at: offset) }
    public mutating func readU32() throws -> UInt32 { defer { offset += 4 }; return try u32(at: offset) }
    public mutating func readU64() throws -> UInt64 { defer { offset += 8 }; return try u64(at: offset) }
    public mutating func readBytes(_ count: Int) throws -> Data {
        defer { offset += count }
        return try bytes(at: offset, count: count)
    }
}

/// Little-endian writer with back-patching.
public struct BinaryWriter {
    public private(set) var data = Data()

    public init() {}

    public var count: Int { data.count }

    public mutating func uint<T: FixedWidthInteger>(_ value: T) {
        for i in 0..<MemoryLayout<T>.size { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    public mutating func u8(_ v: UInt8) { uint(v) }
    public mutating func u16(_ v: UInt16) { uint(v) }
    public mutating func u32(_ v: UInt32) { uint(v) }
    public mutating func u64(_ v: UInt64) { uint(v) }
    public mutating func i16(_ v: Int16) { uint(UInt16(bitPattern: v)) }
    public mutating func i32(_ v: Int32) { uint(UInt32(bitPattern: v)) }
    public mutating func f32(_ v: Float) { uint(v.bitPattern) }

    public mutating func tag(_ s: String) {
        precondition(s.utf8.count == 4, "tag must be 4 bytes")
        data.append(contentsOf: Array(s.utf8))
    }

    public mutating func bytes(_ d: Data) { data.append(d) }
    public mutating func zeros(_ n: Int) { if n > 0 { data.append(Data(count: n)) } }

    public mutating func utf16le(_ s: String) { data.append(s.data(using: .utf16LittleEndian) ?? Data()) }

    /// Pads with zeros until `count` is `size` (no-op if already larger).
    public mutating func pad(toCount size: Int) { zeros(size - data.count) }

    /// Pads with zeros to a multiple of `alignment`.
    public mutating func align(_ alignment: Int) { zeros((alignment - data.count % alignment) % alignment) }

    public mutating func patch<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        for i in 0..<MemoryLayout<T>.size {
            data[data.startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
        }
    }

    public mutating func patchU32(_ v: UInt32, at o: Int) { patch(v, at: o) }

    public mutating func patchBytes(_ d: Data, at offset: Int) {
        let start = data.startIndex + offset
        data.replaceSubrange(start..<start + d.count, with: d)
    }
}

public extension Data {
    /// Returns a copy with `value` written little-endian at `offset`.
    func patching<T: FixedWidthInteger>(_ value: T, at offset: Int) -> Data {
        var copy = self
        for i in 0..<MemoryLayout<T>.size {
            copy[copy.startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
        }
        return copy
    }
}
