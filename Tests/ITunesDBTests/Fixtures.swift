import Foundation
import Support
@testable import ITunesDB

func sampleTrack(_ n: Int, album: String = "Album", artist: String = "Artist") -> Track {
    var t = Track()
    t.title = "Song \(n)"; t.artist = artist; t.album = album; t.albumArtist = artist
    t.genre = "Rock"; t.composer = "Composer \(n % 2)"
    t.sortTitle = "Song \(n)"; t.sortArtist = artist; t.sortAlbum = album; t.sortAlbumArtist = artist
    t.location = ITunesDB.ipodLocation(relativePath: "iPod_Control/Music/F0\(n % 10)/ABC\(n).m4a")
    t.filetype = "M4A "
    t.size = UInt32(1_000_000 + n); t.lengthMs = 200_000 + UInt32(n)
    t.trackNumber = UInt32(n); t.trackCount = 12; t.discNumber = 1; t.discCount = 2; t.year = 2009
    t.bitrate = 256; t.sampleRate = 44100; t.soundcheck = 1234; t.rating = 80
    t.timeAdded = Date(timeIntervalSince1970: 1_700_000_000)
    t.timeModified = Date(timeIntervalSince1970: 1_700_000_100)
    t.compilation = n % 2 == 0
    t.pregap = 1105; t.postgap = 1000; t.sampleCount = 8_820_000
    t.gaplessTrackFlag = true; t.gaplessAlbumFlag = true
    return t
}

func sampleDB() -> ITunesDB {
    var db = ITunesDB.empty(name: "My iPod")
    for n in 1...3 { db.addTrack(sampleTrack(n)) }
    db.addTrack(sampleTrack(4, album: "Other", artist: "Zed"))
    db.playlists.append(Playlist(name: "Mix", trackIDs: [db.tracks[3].id, db.tracks[0].id]))
    return db
}

/// Checks that all chunk lengths nest correctly and returns the mhsd types in file order.
func validateStructure(_ data: Data) throws -> [UInt32] {
    let r = BinaryReader(data)
    try r.expectTag("mhbd", at: 0)
    guard try r.int(8) == data.count else { throw ITunesDBError.corrupt("mhbd total") }
    var offset = try r.int(4)
    var types: [UInt32] = []
    for _ in 0..<(try r.int(0x14)) {
        try r.expectTag("mhsd", at: offset)
        let hl = try r.int(offset + 4), total = try r.int(offset + 8)
        types.append(try r.u32(at: offset + 12))
        if types.last == 9 { offset += total; continue }  // opaque payload
        let list = offset + hl
        let count = try r.int(list + 8)
        var o = list + (try r.int(list + 4))
        for _ in 0..<count {
            let tag = try r.tag(at: o)
            let total = try r.int(o + 8)
            if tag == "mhit" {
                var m = o + (try r.int(o + 4))
                for _ in 0..<(try r.int(o + 12)) { try r.expectTag("mhod", at: m); m += try r.int(m + 8) }
                guard m == o + total else { throw ITunesDBError.corrupt("mhit children") }
            } else if tag == "mhyp" {
                var m = o + (try r.int(o + 4))
                for _ in 0..<(try r.int(o + 12)) { try r.expectTag("mhod", at: m); m += try r.int(m + 8) }
                for _ in 0..<(try r.int(o + 16)) {
                    try r.expectTag("mhip", at: m)
                    let mhipEnd = m + (try r.int(m + 8))
                    try r.expectTag("mhod", at: m + 76)
                    guard m + 76 + (try r.int(m + 76 + 8)) == mhipEnd else { throw ITunesDBError.corrupt("mhip") }
                    m = mhipEnd
                }
                guard m == o + total else { throw ITunesDBError.corrupt("mhyp children") }
            }
            o += total
        }
        guard o == offset + total else { throw ITunesDBError.corrupt("mhsd \(types.last!) total") }
        offset += total
    }
    guard offset == data.count else { throw ITunesDBError.corrupt("trailing data") }
    return types
}

func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
