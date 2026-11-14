import Foundation
import Subsonic
@testable import Library

/// A fresh temp directory removed at the end of the test.
final class TempDir: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-test-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func database(key: String = "demo@http://stub") -> LibraryDatabase {
        LibraryDatabase(serverKey: key, directory: url, coversDirectory: url.appendingPathComponent("covers"))
    }

    var asideFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.contains(".corrupt-") }
    }
}

/// No background schedule and no throttling: tests drive passes with `syncNow()`.
func manualSettings() -> MirrorSettings {
    var settings = MirrorSettings()
    settings.enabled = false
    settings.throttleMs = 0
    return settings
}

func decode<T: Decodable>(_ json: [String: Any]) -> T {
    try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
}

func album(_ id: String, _ name: String, artist: String = "Artist", year: Int = 2000, plays: Int = 0, created: String = "2024-01-01T00:00:00Z", songs: Int = 1) -> Album {
    decode(["id": id, "name": name, "artist": artist, "artistId": "ar", "year": year, "playCount": plays, "created": created,
            "songCount": songs, "duration": songs * 100, "coverArt": "cov-\(id)"])
}

func song(_ id: String, _ title: String, artist: String = "Artist", album: String = "Album", albumId: String = "al", track: Int = 1,
          disc: Int = 1, plays: Int = 0, created: String = "2024-01-01T00:00:00Z") -> Song {
    decode(["id": id, "title": title, "artist": artist, "album": album, "albumId": albumId, "track": track, "discNumber": disc,
            "playCount": plays, "created": created, "duration": 200, "suffix": "flac"])
}

/// Stores albums and their songs through the same calls the mirror uses.
func seed(_ db: LibraryDatabase, albums: [(Album, [Song])]) async throws {
    try await db.storeAlbumPage(albums.map(\.0), run: "seed", nextOffset: albums.count)
    for (album, songs) in albums { try await db.storeAlbumTracks(albumId: album.id, songs: songs) }
}

/// Polls until `condition` holds or five seconds pass.
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<250 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func makeServer(albums: Int = 3, songsPerAlbum: Int = 2) -> StubLibraryServer {
    let server = StubLibraryServer()
    server.albums = (1...albums).map { n in
        StubAlbum(id: "al-\(n)", name: "Album \(String(format: "%02d", n))", artistId: n % 2 == 0 ? "ar-2" : "ar-1", year: 1990 + n,
                  songs: (1...songsPerAlbum).map { StubSong(id: "s-\(n)-\($0)", title: "Song \(n).\($0)", track: $0) })
    }
    return server
}


private let retained = Retained()
private final class Retained: @unchecked Sendable {
    let lock = NSLock()
    var dirs: [TempDir] = []
}

/// A database in a temp directory that lives until the process ends (for tests that do not manage the directory).
func tempDatabase() -> LibraryDatabase {
    let dir = TempDir()
    retained.lock.withLock { retained.dirs.append(dir) }
    return dir.database()
}
