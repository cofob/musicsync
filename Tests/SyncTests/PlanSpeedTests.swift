import Foundation
import Synchronization
import Testing
@testable import ITunesDB
@testable import Library
@testable import Subsonic
@testable import Sync
@testable import Transcode

/// A big library: `albums` albums of 10 songs, 3 artists of 10 albums, 3 playlists of 40 songs.
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
            server.reply("getAlbum:\(id)", StubServer.albumReply(albumJSON(id: id, name: "Album \(n)", songs: songs[id]!)))
        }
        for a in 0..<3 {
            let owned = (0..<10).map { albumIDs[(albums / 2 + a * 10 + $0) % albums] }.map { ["id": $0, "name": $0] }
            server.reply("getArtist:ar-\(a)", StubServer.reply(["artist": ["id": "ar-\(a)", "name": "Artist \(a)", "album": owned]]))
            selection.artists.insert("ar-\(a)")
        }
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

    /// A library mirror holding `albums` as the server sends them.
    func mirror(_ albums: [String], in dir: URL) async throws -> LibraryDatabase {
        let db = LibraryDatabase(serverKey: "k", directory: dir, coversDirectory: dir.appendingPathComponent("covers"))
        let client = server.client
        var full: [Album] = []
        for id in albums { full.append(try await client.getAlbum(id: id)) }
        try await db.storeAlbumPage(full, run: "r", nextOffset: full.count)
        for album in full { try await db.storeAlbumTracks(albumId: album.id, songs: album.song ?? []) }
        return db
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

    @Test func mirrorGivesTheSamePlanWithoutAlbumRequests() async throws {
        let lib = BigLibrary(), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try await expand(SelectionExpander(client: lib.server.client), lib.selection)
        let db = try await lib.mirror(lib.albumIDs, in: dir)
        let before = lib.server.requests.count
        let local = try await expand(SelectionExpander(client: lib.server.client) { await db.album(id: $0) }, lib.selection)
        #expect(local.songs == server.songs && local.playlists == server.playlists && local.missing.isEmpty)
        #expect(lib.plan(local) == lib.plan(server))
        #expect(!lib.server.requests.dropFirst(before).contains("getAlbum"))
    }

    @Test func albumsMissingFromTheMirrorComeFromTheServer() async throws {
        var lib = BigLibrary(albums: 20), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        lib.selection.albums.insert("gone")
        let db = try await lib.mirror(Array(lib.albumIDs.prefix(10)), in: dir)
        let before = lib.server.requests.count
        let result = try await expand(SelectionExpander(client: lib.server.client) { await db.album(id: $0) }, lib.selection)
        #expect(result.missing == ["gone"])
        #expect(Set(result.songs.map(\.albumID)) == Set(lib.albumIDs))
        #expect(lib.server.requests.dropFirst(before).filter { $0 == "getAlbum" }.count == 11)
    }

    @Test func serverErrorForAnAlbumMissingFromTheMirrorStillFails() async throws {
        let lib = BigLibrary(albums: 20), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await lib.mirror(Array(lib.albumIDs.prefix(10)), in: dir)
        lib.server.reply("getAlbum:al-015", #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"boom"}}}"#)
        await #expect(throws: SubsonicError.self) {
            try await expand(SelectionExpander(client: lib.server.client) { await db.album(id: $0) }, lib.selection)
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

    /// 150 albums, 3 artists and 3 playlists over a 50 ms network: the mirror makes it one round trip.
    @Test func bigSelectionIsFastFromTheMirror() async throws {
        let lib = BigLibrary(), dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await lib.mirror(lib.albumIDs, in: dir)
        lib.server.replyDelay = 0.05
        var expansion = Expansion()
        let expanding = try await clock.measure {
            expansion = try await expand(SelectionExpander(client: lib.server.client) { await db.album(id: $0) }, lib.selection)
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
