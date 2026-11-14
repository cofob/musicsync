import Foundation
import Testing
@testable import Library
import Subsonic

@Suite struct EditTests {
    @Test func starsAndRatingsShowAtOnce() async throws {
        let db = tempDatabase()
        try await seed(db, albums: [(album("al-1", "One"), [song("s-1", "A"), song("s-2", "B", track: 2)]),
                                   (album("al-2", "Two"), [song("s-3", "C")])])
        try await db.replaceArtists([decode(["id": "ar", "name": "Artist"])])
        try await db.setStarred("2024-05-01T00:00:00Z", songIds: ["s-2"], albumIds: ["al-2"], artistIds: ["ar"])
        try await db.setStarred("2024-06-01T00:00:00Z", songIds: ["s-3"])
        var starred = await db.starred()
        #expect(starred.song.map(\.id) == ["s-3", "s-2"])
        #expect(starred.album.map(\.id) == ["al-2"] && starred.album.first?.starred != nil)
        #expect(starred.artist.map(\.id) == ["ar"])

        try await db.setStarred(nil, songIds: ["s-3"], albumIds: ["al-2"])
        starred = await db.starred()
        #expect(starred.song.map(\.id) == ["s-2"] && starred.album.isEmpty)
        #expect(await db.album(id: "al-2")?.song?.first?.starred == nil)

        try await db.setRating(4, songId: "s-3")
        try await db.setRating(2, songId: "s-1")
        #expect(await db.songs(sort: .rating).map(\.id) == ["s-3", "s-1", "s-2"])
        #expect(await db.songs(sort: .rating, descending: true, matching: "", limit: 10, offset: 0).map(\.id) == ["s-2", "s-1", "s-3"])
        #expect(await db.album(id: "al-2")?.song?.first?.userRating == 4)
        #expect(await db.search("C").song.count == 1)  // the search index follows the updates
    }

    @Test func storedPlaylistIsNotFetchedAgain() async throws {
        let server = makeServer(albums: 1, songsPerAlbum: 3)
        let dir = TempDir()
        let db = dir.database()
        let mirror = LibraryMirror(database: db, settings: manualSettings())
        await mirror.start(client: server.client)
        await mirror.syncNow()

        // What the app does after createPlaylist: the server has it, the reply is stored.
        server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t1", songIDs: ["s-1-2", "s-1-1"])]
        let reply = try await server.client.getPlaylist(id: "pl-1")
        try await db.storePlaylist(reply.withEntries(reply.entry).renamed("Mix", comment: nil))
        #expect(await db.playlist(id: "pl-1")?.entry?.map(\.id) == ["s-1-2", "s-1-1"])
        #expect(await db.playlists().map(\.name) == ["Mix"])

        server.clearLog()
        await mirror.syncNow()
        #expect(server.requests("getPlaylist").isEmpty)
        #expect(await db.playlist(id: "pl-1")?.entry?.count == 2)

        // A playlist stored without entries is fetched by the next pass.
        try await db.storePlaylist(reply.withEntries(nil))
        #expect(await db.playlist(id: "pl-1") == nil)
        await mirror.syncNow()
        #expect(server.requests("getPlaylist") == ["getPlaylist:pl-1"])
        #expect(await db.playlist(id: "pl-1")?.entry?.count == 2)

        try await db.deletePlaylist(id: "pl-1")
        #expect(await db.playlists().isEmpty)
        #expect(await db.playlist(id: "pl-1") == nil)
        await mirror.stop()
    }

    @Test func mirrorFollowsStarsSetElsewhere() async throws {
        let server = makeServer(albums: 2, songsPerAlbum: 2)
        server.starred = ["s-1-1": "2024-01-02T00:00:00Z", "al-2": "2024-01-01T00:00:00Z", "ar-2": "2024-01-03T00:00:00Z"]
        let dir = TempDir()
        let db = dir.database()
        let mirror = LibraryMirror(database: db, settings: manualSettings())
        await mirror.start(client: server.client)
        await mirror.syncNow()
        var starred = await db.starred()
        #expect(starred.song.map(\.id) == ["s-1-1"] && starred.album.map(\.id) == ["al-2"] && starred.artist.map(\.id) == ["ar-2"])
        #expect(mirror.currentStatus.warnings == 0)

        try await db.setStarred("2024-02-01T00:00:00Z", songIds: ["s-2-2"])
        server.starred = ["s-2-1": "2024-03-01T00:00:00Z"]
        await mirror.syncNow()
        starred = await db.starred()
        #expect(starred.song.map(\.id) == ["s-2-1"] && starred.album.isEmpty && starred.artist.isEmpty)
        await mirror.stop()
    }
}
