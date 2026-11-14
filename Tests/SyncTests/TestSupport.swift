import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Device
@testable import ITunesDB
@testable import Subsonic
@testable import Sync
@testable import Transcode

// MARK: Songs and desired songs

func makeSong(_ id: String, title: String? = nil, album: String = "Album One", albumId: String = "al-1",
              artist: String = "Test Artist", track: Int = 1, size: Int = 30_000_000, suffix: String = "flac",
              duration: Int = 200, bitRate: Int = 900, created: String = "2024-01-01T00:00:00Z",
              playCount: Int = 0, extra: [String: Any] = [:]) -> Song {
    var json: [String: Any] = [
        "id": id, "title": title ?? "Song \(id)", "album": album, "albumId": albumId, "artist": artist, "track": track,
        "year": 2020, "genre": "Rock", "size": size, "suffix": suffix, "duration": duration, "bitRate": bitRate,
        "samplingRate": 44100, "bitDepth": 16, "created": created, "playCount": playCount, "coverArt": "cov-\(albumId)",
    ]
    json.merge(extra) { $1 }
    return try! JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: json))
}

func makeDesired(_ song: Song, preset: Preset = .stockAAC, title: String? = nil, gain: Double? = nil) -> DesiredSong {
    DesiredSong(song: song, preset: preset,
                tags: TrackTags(title: title ?? song.title, artist: song.artist ?? "", album: song.album ?? "",
                                albumArtist: song.artist ?? "", genre: "Rock", year: 2020, trackNumber: song.track,
                                trackTotal: 10, discNumber: 1, discTotal: 1),
                coverArtID: song.coverArt, soundCheckGain: gain)
}

func makeEntry(_ d: DesiredSong, dbid: UInt64, trackID: UInt32, path: String = "iPod_Control/Music/F00/AAAA.m4a",
               outSize: Int64 = 5_000_000) -> Manifest.Entry {
    Manifest.Entry(dbid: dbid, trackID: trackID, relativePath: path, presetID: d.preset.id,
                   presetVersion: d.preset.version, albumID: d.albumID, sourceSize: d.song.size,
                   sourceSuffix: d.song.suffix, sourceCreated: d.song.created, outSize: outSize,
                   fingerprint: d.fingerprint, title: d.tags.title)
}

func makeTrack(_ n: Int, album: String = "Foreign Album", artist: String = "Foreign Artist", dbid: UInt64? = nil,
               location: String? = nil, size: UInt32 = 4_000_000) -> Track {
    var t = Track()
    t.title = "Foreign \(n)"; t.artist = artist; t.album = album; t.albumArtist = artist
    t.dbid = dbid ?? UInt64(1000 + n)
    t.location = location ?? ITunesDB.ipodLocation(relativePath: "iPod_Control/Music/F09/FRG\(n).m4a")
    t.size = size; t.lengthMs = 180_000; t.trackNumber = UInt32(n); t.year = 2001
    return t
}

/// A library holding the given tracks (and playlists) as the manifest sees them.
func makeLibrary(tracks: [Track] = [], playlists: [PodPlaylist] = [], manifest: Manifest = Manifest(),
                 rockbox: Set<String> = []) -> DeviceLibrary {
    var db = ITunesDB.empty(name: "Test iPod")
    for t in tracks { db.addTrack(t) }
    db.playlists += playlists
    return DeviceLibrary(db: db, manifest: manifest, rockboxPaths: rockbox)
}

// MARK: Temp dirs

func tempDirectory(_ name: String = "sync-test") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testLocations(_ root: URL) -> SyncLocations {
    SyncLocations(appSupport: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"))
}
