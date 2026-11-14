import Foundation
import Support

/// Builders and parsers for `mhod` chunks.
enum Mhod {
    enum Kind {
        static let title: UInt32 = 1, location: UInt32 = 2, album: UInt32 = 3, artist: UInt32 = 4
        static let genre: UInt32 = 5, fileType: UInt32 = 6, composer: UInt32 = 12, albumArtist: UInt32 = 22
        static let sortArtist: UInt32 = 23, sortTitle: UInt32 = 27, sortAlbum: UInt32 = 28
        static let sortAlbumArtist: UInt32 = 29
        static let libraryIndex: UInt32 = 52, jumpTable: UInt32 = 53, playlistPrefs: UInt32 = 100
        static let albumName: UInt32 = 200, albumOwner: UInt32 = 201, albumSortOwner: UInt32 = 202
        static let artistName: UInt32 = 300
    }

    /// 24-byte header; `total` is the length of the whole chunk.
    private static func header(_ type: UInt32, total: Int) -> BinaryWriter {
        var w = BinaryWriter()
        w.tag("mhod"); w.u32(24); w.u32(UInt32(total)); w.u32(type); w.zeros(8)
        return w
    }

    static func string(_ type: UInt32, _ value: String) -> Data {
        let body = value.data(using: .utf16LittleEndian) ?? Data()
        var w = header(type, total: 40 + body.count)
        w.u32(1); w.u32(UInt32(body.count)); w.u32(1); w.u32(0); w.bytes(body)
        return w.data
    }

    /// Decodes a string mhod (UTF-16LE, or UTF-8 when the encoding flag is 2).
    static func decodeString(_ chunk: Data) -> String? {
        let r = BinaryReader(chunk)
        guard let encoding = try? r.u32(at: 0x18), let length = try? r.int(0x1C) else { return nil }
        if encoding == 2 { return try? r.utf8(at: 0x28, byteCount: length) }
        return try? r.utf16le(at: 0x28, byteCount: length)
    }

    /// Position marker child of a `mhip`.
    static func position(_ index: UInt32) -> Data {
        var w = header(Kind.playlistPrefs, total: 44)
        w.u32(index); w.zeros(16)
        return w.data
    }

    /// Per-playlist view preferences (type 100); the blob libgpod writes for every playlist.
    static func playlistPrefs() -> Data {
        var w = header(Kind.playlistPrefs, total: 0x288)
        w.zeros(16)
        let words: [UInt32] = [0x010084, 0x05, 0x09, 0x03, 0x120001, 0, 0, 0]
        words.forEach { w.u32($0) }
        for column: UInt32 in [0xc80002, 0x3c000d, 0x7d0004, 0x7d0003, 0x640008] { w.u32(column); w.zeros(12) }
        for column: UInt32 in [0x640017, 0x500014, 0x7d0015] { w.u32(column); w.u32(1); w.zeros(8) }
        w.pad(toCount: 0x288)
        return w.data
    }

    /// Sorted track positions (type 52) and the matching jump table (type 53).
    static func libraryIndex(sortType: UInt32, order: [Int], letters: [UInt16]) -> [Data] {
        var w = header(Kind.libraryIndex, total: 4 * order.count + 72)
        w.u32(sortType); w.u32(UInt32(order.count)); w.zeros(40)
        order.forEach { w.u32(UInt32($0)) }

        var groups: [(letter: UInt16, start: Int, count: Int)] = []
        for (position, trackIndex) in order.enumerated() {
            let letter = letters[trackIndex]
            if groups.last?.letter == letter { groups[groups.count - 1].count += 1 } else { groups.append((letter, position, 1)) }
        }
        var j = header(Kind.jumpTable, total: 12 * groups.count + 40)
        j.u32(sortType); j.u32(UInt32(groups.count)); j.zeros(8)
        for g in groups { j.u16(g.letter); j.u16(0); j.u32(UInt32(g.start)); j.u32(UInt32(g.count)) }
        return [w.data, j.data]
    }
}
