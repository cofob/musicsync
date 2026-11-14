import Foundation
import Support

public enum ITunesDBError: Error, Equatable {
    case notITunesDB
    case corrupt(String)
    case noMasterPlaylist
}

/// iPod timestamps: seconds since 1904-01-01 in local time, 0 = unset.
enum MacTime {
    static let epochOffset: Int64 = 2_082_844_800

    static func mac(_ date: Date?) -> UInt32 {
        guard let date else { return 0 }
        let local = Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(TimeZone.current.secondsFromGMT(for: date))
        return UInt32(clamping: max(0, local + epochOffset))
    }

    static func date(_ mac: UInt32) -> Date? {
        guard mac != 0 else { return nil }
        let unixLocal = Int64(mac) - epochOffset
        let tz = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(unixLocal)))
        return Date(timeIntervalSince1970: Double(unixLocal - Int64(tz)))
    }
}

/// Sound Check value from a ReplayGain gain in dB (0 = none).
public func soundcheck(fromReplayGainDB gain: Double) -> UInt32 {
    let value = (1000 * pow(10, -gain / 10)).rounded()
    guard value.isFinite, value > 0 else { return 0 }
    return value >= Double(UInt32.max) ? UInt32.max : UInt32(value)
}

extension ITunesDB {
    /// `iPod_Control/Music/F07/ABCD.m4a` -> `:iPod_Control:Music:F07:ABCD.m4a`
    public static func ipodLocation(relativePath: String) -> String {
        ":" + relativePath.split(separator: "/").joined(separator: ":")
    }

    /// `:iPod_Control:Music:F07:ABCD.m4a` -> `iPod_Control/Music/F07/ABCD.m4a`
    public static func relativePath(ipodLocation: String) -> String {
        ipodLocation.split(separator: ":").joined(separator: "/")
    }
}

extension BinaryReader {
    /// Unsigned little-endian integer of 1, 2, 4 or 8 bytes.
    func uint(width: Int, at offset: Int) throws -> UInt64 {
        switch width {
        case 1: UInt64(try u8(at: offset))
        case 2: UInt64(try u16(at: offset))
        case 4: UInt64(try u32(at: offset))
        default: try u64(at: offset)
        }
    }

    func int(_ offset: Int) throws -> Int { Int(try u32(at: offset)) }
}

extension BinaryWriter {
    mutating func patch(_ value: UInt64, width: Int, at offset: Int) {
        switch width {
        case 1: patch(UInt8(truncatingIfNeeded: value), at: offset)
        case 2: patch(UInt16(truncatingIfNeeded: value), at: offset)
        case 4: patch(UInt32(truncatingIfNeeded: value), at: offset)
        default: patch(value, at: offset)
        }
    }

    /// Zeroes `range` (clipped to the data written so far).
    mutating func zero(_ range: Range<Int>) {
        let clipped = range.clamped(to: 0..<count)
        patchBytes(Data(count: clipped.count), at: clipped.lowerBound)
    }
}

extension Data {
    /// Type field of a `mhod` chunk.
    var mhodType: UInt32 { (try? BinaryReader(self).u32(at: 12)) ?? 0 }
}

func randomID() -> UInt64 { UInt64.random(in: 1...UInt64.max) }

/// 64-bit FNV-1a; gives stable SQL-style ids to albums and artists.
func stableHash(_ s: String) -> UInt64 {
    s.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
}
