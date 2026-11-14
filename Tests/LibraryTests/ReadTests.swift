import Foundation
import Testing
@testable import Library
import Subsonic

@Suite struct ReadTests {
    private func seeded() async throws -> LibraryDatabase {
        let db = tempDatabase()
        try await seed(db, albums: [
            (album("a1", "zebra", artist: "Beta", year: 1999, plays: 5, created: "2024-01-01T00:00:00Z", songs: 2),
             [song("s1", "Gamma", artist: "Beta", album: "zebra", albumId: "a1", track: 2, disc: 1, plays: 3),
              song("s2", "Alpha", artist: "Beta", album: "zebra", albumId: "a1", track: 1, disc: 2, plays: 1)]),
            (album("a2", "Café del Mar", artist: "Alpha", year: 2010, plays: 9, created: "2024-03-01T00:00:00Z"),
             [song("s3", "Sunset", artist: "Alpha", album: "Café del Mar", albumId: "a2", plays: 7, created: "2024-03-01T00:00:00Z")]),
            (album("a3", "apple", artist: "Chi", year: 2005, plays: 1, created: "2024-02-01T00:00:00Z"),
             [song("s4", "Спейс Одити", artist: "Девид", album: "apple", albumId: "a3", created: "2024-02-01T00:00:00Z")]),
        ])
        return db
    }

    @Test func albumSorting() async throws {
        let db = try await seeded()
        #expect(await db.albums().map(\.id) == ["a3", "a2", "a1"])  // apple, cafe, zebra
        #expect(await db.albums(sort: .artist).map(\.id) == ["a2", "a1", "a3"])
        #expect(await db.albums(sort: .year).map(\.id) == ["a2", "a3", "a1"])
        #expect(await db.albums(sort: .newest).map(\.id) == ["a2", "a3", "a1"])
        #expect(await db.albums(sort: .mostPlayed).map(\.id) == ["a2", "a1", "a3"])
    }

    @Test func songSortingAndPaging() async throws {
        let db = try await seeded()
        #expect(await db.songs(sort: .title).map(\.id) == ["s2", "s1", "s3", "s4"])  // Alpha Gamma Sunset Спейс
        #expect(await db.songs(sort: .mostPlayed, limit: 2).map(\.id) == ["s3", "s1"])
        #expect(await db.songs(sort: .mostPlayed, limit: 2, offset: 2).map(\.id).count == 2)
        #expect(await db.songs(sort: .newest).first?.id == "s3")
        #expect(await db.songs(limit: 10, offset: 10).isEmpty)
        #expect(await db.songCount() == 4)
    }

    @Test func albumSongsAreOrderedByDiscAndTrack() async throws {
        let db = try await seeded()
        #expect(await db.album(id: "a1")?.song?.map(\.id) == ["s1", "s2"])  // disc 1 track 2, then disc 2 track 1
        #expect(await db.album(id: "missing") == nil)
    }

    @Test func albumWithoutSyncedTracksIsNotServed() async throws {
        let db = tempDatabase()
        try await db.storeAlbumPage([album("a1", "Pending")], run: "r", nextOffset: 1)
        #expect(await db.albums().count == 1)
        #expect(await db.album(id: "a1") == nil)  // caller falls back to the network
    }

    @Test func searchIgnoresCaseAndDiacriticsAndHandlesCyrillic() async throws {
        let db = try await seeded()
        #expect(await db.search("cafe").album.map(\.id) == ["a2"])
        #expect(await db.search("Café").album.map(\.id) == ["a2"])
        #expect(await db.search("café del m").album.map(\.id) == ["a2"])
        #expect(await db.search("Спейс").song.map(\.id) == ["s4"])
        #expect(await db.search("спе").song.map(\.id) == ["s4"])
        #expect(await db.search("девид").song.map(\.id) == ["s4"])
        #expect(await db.search("alpha").song.map(\.id).sorted() == ["s2", "s3"])
        #expect(await db.search("\"; DROP TABLE songs; --").song.isEmpty)
        #expect(await db.search("   ").album.isEmpty)
        #expect(await db.songCount() == 4)
    }

    @Test func searchFollowsUpdatesAndDeletes() async throws {
        let db = try await seeded()
        try await db.storeAlbumTracks(albumId: "a2", songs: [song("s3", "Renamed Tune", artist: "Alpha", album: "Café del Mar", albumId: "a2")])
        #expect(await db.search("sunset").song.isEmpty)
        #expect(await db.search("renamed").song.map(\.id) == ["s3"])
        try await db.storeAlbumPage([album("a1", "zebra", songs: 2)], run: "new", nextOffset: 1)
        try await db.finishAlbumListing(run: "new")
        #expect(await db.search("renamed").song.isEmpty)
        #expect(await db.search("zebra").album.map(\.id) == ["a1"])
    }

    @Test func lyricsRoundTripPrefersSynced() async throws {
        let db = try await seeded()
        let plain: StructuredLyrics = decode(["synced": false, "line": [["value": "plain"]]])
        let synced: StructuredLyrics = decode(["synced": true, "lang": "eng", "offset": -50, "line": [["start": 0, "value": "Hi"], ["start": 1500, "value": "There"]]])
        try await db.storeLyrics(songId: "s1", lyrics: [plain, synced])
        let got = await db.lyrics(songId: "s1")
        #expect(got?.synced == true && got?.line.map(\.start) == [0, 1500] && got?.offset == -50)
        try await db.storeLyrics(songId: "s2", lyrics: [])
        #expect(await db.lyrics(songId: "s2") == nil)
        #expect(await db.lyrics(songId: "s3") == nil)
        #expect(await db.songsMissingLyrics(limit: 10).sorted() == ["s3", "s4"])
        // Stored replies, also "none", are not asked again; unknown songs are.
        #expect(await db.storedLyrics(songId: "s1")?.count == 2)
        #expect(await db.storedLyrics(songId: "s2") == [])
        #expect(await db.storedLyrics(songId: "s3") == nil)
    }
}

