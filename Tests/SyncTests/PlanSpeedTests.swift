import Foundation
import Synchronization
import Testing
@testable import ITunesDB
@testable import Library
@testable import Subsonic
@testable import Sync
@testable import Transcode

/// A big library: `albums` albums of 10 songs, 3 of 5 artists selected, 3 playlists of 40 songs.
struct BigLibrary {
    let server = StubServer()
    var selection = Selection()
    let albumIDs: [String]

    init(albums: Int = 150) {
        let file = URL(fileURLWithPath: "/nonexistent")
        albumIDs = (0..<albums).map { String(format: "al-%03d", $0) }
        var songs: [String: [[String: Any]]] = [:]
        for (n, id) in albumIDs.enumerated() {
            songs[id] = (1...10).map { t in
                songJSON("\(id)-s\(t)", title: "Song \(t)", track: t, album: "Album \(n)", albumId: id, file: file, seconds: 200,
                         extra: ["size": 30_000_000, "discNumber": t > 6 ? 2 : 1])
            }
            var album = albumJSON(id: id, name: "Album \(n)", songs: songs[id]!)
            album["artistId"] = "ar-\(n % 5)"
            server.reply("getAlbum:\(id)", StubServer.albumReply(album))
        }
        for a in 0..<5 {
            let owned = albumIDs.enumerated().filter { $0.offset % 5 == a }.map { ["id": $0.element, "name": $0.element] }
            server.reply("getArtist:ar-\(a)", StubServer.reply(["artist": ["id": "ar-\(a)", "name": "Artist \(a)", "albumCount": owned.count, "album": owned]]))
        }
        selection.artists = ["ar-0", "ar-1", "ar-2"]
        for p in 0..<3 {
            let entries = (0..<40).map { songs[albumIDs[(p * 37 + $0 * 3) % albums]]![$0 % 10] }
            server.reply("getPlaylist:pl-\(p)", StubServer.reply(["playlist": ["id": "pl-\(p)", "name": "Mix \(p)", "entry": entries]]))
            selection.playlists.insert("pl-\(p)")
        }
        selection.albums = Set(albumIDs.prefix(100))
    }

    /// Half of the expanded songs are already on the device, plus 200 foreign tracks.
    func device(for songs: [DesiredSong]) -> (Manifest, DeviceLibrary) {
        var manifest = Manifest(serverKey: "s")
        var tracks = (0..<200).map { makeTrack($0, album: "Foreign \($0 / 10)") }
        for (i, d) in songs.enumerated() where i % 2 == 0 {
            var t = makeTrack(5000 + i, album: d.tags.album, artist: d.tags.albumArtist, dbid: UInt64(10_000 + i))
            t.title = d.tags.title
            tracks.append(t)
            manifest.entries[d.id] = makeEntry(d, dbid: UInt64(10_000 + i), trackID: UInt32(20_000 + i))
        }
        return (manifest, makeLibrary(tracks: tracks, manifest: manifest))
    }

    /// A library mirror holding these albums, all artists and these playlists as the server sends them.
    func mirror(_ albums: [String], playlists: [String] = ["pl-0", "pl-1", "pl-2"], in dir: URL) async throws -> LibraryDatabase {
        let db = LibraryDatabase(serverKey: "k", directory: dir, coversDirectory: dir.appendingPathComponent("covers"))
        let client = server.client
        var full: [Album] = []
        for id in albums { full.append(try await client.getAlbum(id: id)) }
        try await db.storeAlbumPage(full, run: "r", nextOffset: full.count)
        for album in full { try await db.storeAlbumTracks(albumId: album.id, songs: album.song ?? []) }
        var artists: [Artist] = []
        for a in 0..<5 { artists.append(try await client.getArtist(id: "ar-\(a)")) }
        try await db.replaceArtists(artists)
        for id in playlists { try await db.storePlaylist(try await client.getPlaylist(id: id)) }
        return db
    }

    func expander(_ db: LibraryDatabase) -> SelectionExpander {
        SelectionExpander(client: server.client, local: LocalLibrary(album: { await db.album(id: $0) },
                                                                     artistAlbumIDs: { await db.albumIDs(ofArtist: $0) },
                                                                     playlist: { await db.playlist(id: $0) }))
    }

    func plan(_ expansion: Expansion) -> SyncPlan {
        let (manifest, library) = device(for: expansion.songs)
        return SyncPlanner.plan(PlannerInput(desired: expansion.songs, playlists: expansion.playlists, manifest: manifest,
                                             library: library, freeBytes: 10_000_000_000))
    }
}

@Suite struct PlanSpeedTests {
    let clock = ContinuousClock()

    func expand(_ expander: SelectionExpander, _ selection: Selection, progress: SelectionExpander.Progress? = nil) async throws -> Expansion {
        try await expander.expand(selection, defaultPresetID: "stock-aac", soundCheck: .album, progress: progress)
    }

    @Test func mirrorGivesTheSamePlanWithoutRequests() async throws {
        let lib = BigLibrary(), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await expand(SelectionExpander(client: lib.server.client), lib.selection)
        let db = try await lib.mirror(lib.albumIDs, in: dir)
        let before = lib.server.requests.count
        let local = try await expand(lib.expander(db), lib.selection)
        #expect(local.songs == server.songs && local.playlists == server.playlists && local.missing.isEmpty)
        #expect(lib.plan(local) == lib.plan(server))
        #expect(lib.server.requests.count == before)
    }

    @Test func repeatCheckUsesTheCacheUntilCleared() async throws {
        let lib = BigLibrary(albums: 20)
        let expander = SelectionExpander(client: lib.server.client)
        _ = try await expand(expander, lib.selection)
        let before = lib.server.requests.count
        _ = try await expand(expander, lib.selection)
        #expect(lib.server.requests.count == before)
        await expander.clearCache()
        _ = try await expand(expander, lib.selection)
        #expect(lib.server.requests.count == before * 2)
    }

    @Test func albumsMissingFromTheMirrorComeFromTheServer() async throws {
        var lib = BigLibrary(albums: 20), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        lib.selection.albums.insert("gone")
        lib.selection.artists.insert("ar-gone")
        lib.selection.playlists.insert("pl-gone")
        let db = try await lib.mirror(Array(lib.albumIDs.prefix(10)), playlists: ["pl-0"], in: dir)
        let before = lib.server.requests.count
        let local = try await expand(lib.expander(db), lib.selection)
        let asked = lib.server.requests.dropFirst(before)
        let server = try await expand(SelectionExpander(client: lib.server.client), lib.selection)
        #expect(Set(local.missing) == ["gone", "ar-gone", "pl-gone"])
        #expect(local.songs == server.songs && local.playlists == server.playlists)
        #expect(asked.filter { $0 == "getAlbum" }.count == 11)
        // Half of each artist's albums are not in the mirror, so the server lists them all.
        #expect(asked.filter { $0 == "getArtist" }.count == 4 && asked.filter { $0 == "getPlaylist" }.count == 3)
    }

    @Test func serverErrorForAnAlbumMissingFromTheMirrorStillFails() async throws {
        let lib = BigLibrary(albums: 20), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await lib.mirror(Array(lib.albumIDs.prefix(10)), in: dir)
        lib.server.reply("getAlbum:al-015", #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"boom"}}}"#)
        await #expect(throws: SubsonicError.self) {
            try await expand(lib.expander(db), lib.selection)
        }
    }

    @Test func reportsProgressOverAllAlbums() async throws {
        let lib = BigLibrary(albums: 30)
        let seen = Mutex<[Int]>([])
        _ = try await expand(SelectionExpander(client: lib.server.client), lib.selection) { done, total in
            #expect(total == 30)
            seen.withLock { $0.append(done) }
        }
        #expect(seen.withLock { $0 } == Array(1...30))
    }

    /// 150 albums, 3 artists and 3 playlists over a 50 ms network: the mirror needs no request.
    @Test func bigSelectionIsFastFromTheMirror() async throws {
        let lib = BigLibrary(), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await lib.mirror(lib.albumIDs, in: dir)
        lib.server.replyDelay = 0.05
        var expansion = Expansion()
        let expanding = try await clock.measure {
            expansion = try await expand(lib.expander(db), lib.selection)
        }
        let (manifest, library) = lib.device(for: expansion.songs)
        var plan = SyncPlan()
        let planning = clock.measure {
            plan = SyncPlanner.plan(PlannerInput(desired: expansion.songs, playlists: expansion.playlists, manifest: manifest,
                                                 library: library, freeBytes: 10_000_000_000))
        }
        #expect(expansion.songs.count > 1000 && plan.add.count > 500)
        #expect(expanding < .seconds(1) && planning < .seconds(1))
    }
}
