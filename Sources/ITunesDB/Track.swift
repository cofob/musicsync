import Foundation
import Support

/// Original bytes of a track read from an existing database (e.g. written by iTunes).
public struct RawTrack: Sendable, Equatable {
    let header: Data
    let mhods: [Data]
}

public struct Track: Sendable, Equatable {
    public var id: UInt32 = 0
    public var dbid: UInt64 = 0

    public var title = "", artist = "", album = "", albumArtist = "", genre = "", composer = ""
    public var sortTitle = "", sortArtist = "", sortAlbum = "", sortAlbumArtist = ""
    /// iPod form, e.g. `:iPod_Control:Music:F07:ABCD.m4a`.
    public var location = ""
    /// Four characters, e.g. `"M4A "` or `"MP3 "`.
    public var filetype = "M4A "
    /// Defaults from `filetype` when empty (e.g. "AAC audio file").
    public var fileTypeDescription = ""

    public var size: UInt32 = 0
    public var lengthMs: UInt32 = 0
    public var trackNumber: UInt32 = 0, trackCount: UInt32 = 0
    public var discNumber: UInt32 = 0, discCount: UInt32 = 0
    public var year: UInt32 = 0
    public var bitrate: UInt32 = 0
    public var sampleRate: UInt32 = 44100
    public var soundcheck: UInt32 = 0
    public var playCount: UInt32 = 0, skipCount: UInt32 = 0
    /// Stars x 20 (0...100).
    public var rating: UInt8 = 0
    public var bookmarkTime: UInt32 = 0
    public var timePlayed: Date?, timeAdded: Date?, timeModified: Date?, lastSkipped: Date?
    public var compilation = false
    public var mediaType: UInt32 = 1
    /// 1 = normal, 2 = shown with the "unplayed" bullet.
    public var markUnplayed: UInt8 = 1

    public var pregap: UInt32 = 0, postgap: UInt32 = 0
    public var sampleCount: UInt64 = 0
    public var gaplessData: UInt32 = 0
    public var gaplessTrackFlag = false, gaplessAlbumFlag = false

    public var artworkCount: UInt16 = 0
    public var artworkSize: UInt32 = 0
    public var hasArtwork = false
    /// The file has lyrics (the iPod shows them from the file's tag).
    public var lyricsFlag = false
    /// Image id in the ArtworkDB (`mhii::song_id` link).
    public var mhiiLink: UInt32 = 0

    /// Set for tracks parsed from an existing database; written back byte-for-byte except edited fields.
    public var raw: RawTrack?

    public init() {}

    /// Points the track at an ArtworkDB image.
    public mutating func setArtwork(imageID: UInt32, sourceSize: UInt32) {
        mhiiLink = imageID; artworkCount = 1; artworkSize = sourceSize; hasArtwork = true
    }
}

// MARK: - Binary layout

/// mhit header offsets that are not part of the field table.
private enum MHIT {
    static let headerLength = 0x248
    static let visible = 0x14, filetype = 0x18, type2 = 0x1D, unk126 = 0x7E, unk144 = 0x90
    static let albumID = 0x120, id24 = 0x124, magic = 0x134, unk168 = 0x168
    static let artistID = 0x1E0, composerID = 0x1F4
}

/// One numeric header field; `set` is nil for derived fields that are only written.
private struct Field {
    let offset: Int
    let width: Int
    let get: (Track) -> UInt64
    let set: ((inout Track, UInt64) -> Void)?

    static func int<T: FixedWidthInteger>(_ offset: Int, _ path: WritableKeyPath<Track, T>) -> Field {
        Field(offset: offset, width: MemoryLayout<T>.size,
              get: { UInt64($0[keyPath: path]) }, set: { $0[keyPath: path] = T(truncatingIfNeeded: $1) })
    }

    static func flag(_ offset: Int, width: Int, _ path: WritableKeyPath<Track, Bool>, off: UInt64 = 0) -> Field {
        Field(offset: offset, width: width,
              get: { $0[keyPath: path] ? 1 : off }, set: { $0[keyPath: path] = $1 == 1 })
    }

    static func date(_ offset: Int, _ path: WritableKeyPath<Track, Date?>) -> Field {
        Field(offset: offset, width: 4,
              get: { UInt64(MacTime.mac($0[keyPath: path])) }, set: { $0[keyPath: path] = MacTime.date(UInt32($1)) })
    }

    static func derived(_ offset: Int, width: Int, _ get: @escaping (Track) -> UInt64) -> Field {
        Field(offset: offset, width: width, get: get, set: nil)
    }

    static var all: [Field] {
        [
            .int(0x10, \.id), .flag(0x1E, width: 1, \.compilation), .int(0x1F, \.rating),
            .date(0x20, \.timeModified), .int(0x24, \.size), .int(0x28, \.lengthMs),
            .int(0x2C, \.trackNumber), .int(0x30, \.trackCount), .int(0x34, \.year), .int(0x38, \.bitrate),
            Field(offset: 0x3C, width: 4, get: { UInt64(($0.sampleRate & 0xFFFF) << 16) },
                  set: { $0.sampleRate = UInt32($1 >> 16) }),
            .int(0x4C, \.soundcheck), .int(0x50, \.playCount), .date(0x58, \.timePlayed),
            .int(0x5C, \.discNumber), .int(0x60, \.discCount), .date(0x68, \.timeAdded),
            .int(0x6C, \.bookmarkTime), .int(0x70, \.dbid), .int(0x7C, \.artworkCount),
            .int(0x80, \.artworkSize), .int(0x9C, \.skipCount), .date(0xA0, \.lastSkipped), .flag(0xA4, width: 1, \.hasArtwork, off: 2),
            .flag(0xB0, width: 1, \.lyricsFlag), .int(0xB2, \.markUnplayed), .int(0xB8, \.pregap), .int(0xBC, \.sampleCount), .int(0xC8, \.postgap),
            .int(0xD0, \.mediaType), .int(0xF8, \.gaplessData),
            .flag(0x100, width: 2, \.gaplessTrackFlag), .flag(0x102, width: 2, \.gaplessAlbumFlag),
            .int(0x160, \.mhiiLink),
            Field(offset: MHIT.filetype, width: 4, get: { UInt64(Track.marker($0.filetype)) },
                  set: { $0.filetype = Track.filetype(marker: UInt32($1)) }),
            .derived(0x88, width: 4) { UInt64(Float($0.sampleRate).bitPattern) },
            .derived(0xA8, width: 8) { $0.dbid },
            .derived(0x12C, width: 4) { UInt64($0.size) },
        ]
    }

    /// (mhod type, field) in libgpod's write order.
    static var strings: [(type: UInt32, path: WritableKeyPath<Track, String>)] {
        [(Mhod.Kind.title, \.title), (Mhod.Kind.artist, \.artist), (Mhod.Kind.album, \.album),
         (Mhod.Kind.fileType, \.fileTypeDescription), (Mhod.Kind.location, \.location),
         (Mhod.Kind.genre, \.genre), (Mhod.Kind.composer, \.composer), (Mhod.Kind.albumArtist, \.albumArtist),
         (Mhod.Kind.sortArtist, \.sortArtist), (Mhod.Kind.sortTitle, \.sortTitle),
         (Mhod.Kind.sortAlbum, \.sortAlbum), (Mhod.Kind.sortAlbumArtist, \.sortAlbumArtist)]
    }
}

extension Track {
    /// "M4A " as the big-endian integer libgpod stores (written little-endian).
    fileprivate static func marker(_ type: String) -> UInt32 {
        var bytes = Array(type.utf8.prefix(4))
        bytes += Array(repeating: 0x20, count: 4 - bytes.count)
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    fileprivate static func filetype(marker: UInt32) -> String {
        marker == 0 ? "" : String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: marker >> (24 - 8 * $0)) }, as: UTF8.self)
    }

    private var isMP3: Bool { filetype.uppercased().hasPrefix("MP3") }
    private var isM4A: Bool { filetype.uppercased().hasPrefix("M4A") || filetype.uppercased().hasPrefix("M4B") }

    private var defaultDescription: String {
        isMP3 ? "MPEG audio file" : isM4A ? "AAC audio file" : ""
    }

    /// Reads the fields this module understands; tolerant of short headers.
    static func decode(header: Data, mhods: [Data]) -> Track {
        var track = Track()
        let r = BinaryReader(header)
        for f in Field.all {
            guard let set = f.set, f.offset + f.width <= header.count, let v = try? r.uint(width: f.width, at: f.offset) else { continue }
            set(&track, v)
        }
        let strings = Field.strings
        for chunk in mhods {
            guard let value = Mhod.decodeString(chunk), let path = strings.first(where: { $0.type == chunk.mhodType })?.path else { continue }
            track[keyPath: path] = value
        }
        track.raw = RawTrack(header: header, mhods: mhods)
        return track
    }

    /// Serialized mhit (header, then child mhods). Ids are the regenerated album/artist/composer ids.
    func encode(albumID: UInt32, artistID: UInt32, composerID: UInt32, dbID24: UInt64) -> Data {
        let fields = Field.all
        var w = BinaryWriter()
        var mhods: [Data]

        if let raw {
            let original = Track.decode(header: raw.header, mhods: raw.mhods)
            w.bytes(raw.header)
            for f in fields where f.offset + f.width <= raw.header.count && f.get(self) != f.get(original) { w.patch(f.get(self), width: f.width, at: f.offset) }
            mhods = raw.mhods
            for (type, path) in Field.strings where self[keyPath: path] != original[keyPath: path] {
                let at = mhods.firstIndex { $0.mhodType == type }
                mhods.removeAll { $0.mhodType == type }
                if !self[keyPath: path].isEmpty { mhods.insert(Mhod.string(type, self[keyPath: path]), at: at ?? mhods.endIndex) }
            }
        } else {
            w.tag("mhit"); w.u32(UInt32(MHIT.headerLength)); w.zeros(MHIT.headerLength - 8)
            for f in fields { w.patch(f.get(self), width: f.width, at: f.offset) }
            w.patch(UInt32(1), at: MHIT.visible)
            if isMP3 { w.patch(UInt8(1), at: MHIT.type2) }
            let known = isMP3 || isM4A
            w.patch(UInt16(known ? 0xFFFF : 0), at: MHIT.unk126)
            w.patch(UInt16(isMP3 ? 0x0C : isM4A ? 0x33 : 0), at: MHIT.unk144)
            w.patch(UInt64(0x8080_8080_8080), at: MHIT.magic)
            w.patch(UInt32(1), at: MHIT.unk168)
            var track = self
            if track.fileTypeDescription.isEmpty { track.fileTypeDescription = defaultDescription }
            mhods = Field.strings.compactMap { type, path in
                track[keyPath: path].isEmpty ? nil : Mhod.string(type, track[keyPath: path])
            }
        }

        let length = w.data.count
        for (offset, value) in [(MHIT.albumID, albumID), (MHIT.artistID, artistID), (MHIT.composerID, composerID)] where length >= offset + 4 {
            w.patch(value, at: offset)
        }
        if length >= MHIT.id24 + 8 { w.patch(dbID24, at: MHIT.id24) }
        for chunk in mhods { w.bytes(chunk) }
        w.patch(UInt32(w.count), at: 8)
        w.patch(UInt32(mhods.count), at: 12)
        return w.data
    }
}
