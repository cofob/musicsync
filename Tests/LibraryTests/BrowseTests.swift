import Foundation
import Subsonic
import Testing
@testable import Library

@Suite struct BrowseTests {
    private func album(_ id: String, artistId: String, genre: String?, year: Int?, plays: Int = 0) -> Album {
        var json: [String: Any] = ["id": id, "name": "Album \(id)", "artist": artistId, "artistId": artistId, "playCount": plays,
                                   "songCount": 1, "coverArt": "cov-\(id)"]
        json["genre"] = genre
        json["year"] = year
        return decode(json)
    }

    private func song(_ id: String, albumId: String, artistId: String, genre: String? = nil, plays: Int = 0) -> Song {
        decode(["id": id, "title": "Song \(id)", "albumId": albumId, "artistId": artistId, "artist": artistId, "playCount": plays,
                "genre": genre ?? ""])
    }

    /// Artist "a" has two albums; "b" has a compilation with one song by "a".
    private func seeded() async throws -> LibraryDatabase {
        let db = tempDatabase()
        try await seed(db, albums: [
            (album("a1", artistId: "a", genre: "Rock", year: 1995, plays: 3),
             [song("s1", albumId: "a1", artistId: "a", genre: "Rock", plays: 2), song("s2", albumId: "a1", artistId: "a", genre: "Rock")]),
            (album("a2", artistId: "a", genre: "Pop", year: 2004, plays: 1), [song("s3", albumId: "a2", artistId: "a", genre: "Pop")]),
            (album("b1", artistId: "b", genre: "Rock", year: 1998, plays: 9),
             [song("s4", albumId: "b1", artistId: "a", genre: "Rock"), song("s5", albumId: "b1", artistId: "b", genre: "Rock", plays: 4)]),
            (album("c1", artistId: "c", genre: "Jazz", year: 1992), [song("s6", albumId: "c1", artistId: "c", genre: "Jazz")]),
            (album("d1", artistId: "d", genre: nil, year: 2011), [song("s7", albumId: "d1", artistId: "d")]),
        ])
        return db
    }

    @Test func genreCountsAndCovers() async throws {
        let db = try await seeded()
        let genres = await db.genres()
        #expect(genres.map(\.name) == ["Rock", "Jazz", "Pop"])
        #expect(genres[0] == GenreSummary(name: "Rock", albumCount: 2, songCount: 4, covers: ["cov-b1", "cov-a1"]))
        #expect(genres[2].albumCount == 1 && genres[2].songCount == 1)
        #expect(await db.albums(genre: "Rock").map(\.id) == ["b1", "a1"])
        #expect(await db.songs(genre: "Rock", limit: 2).map(\.id) == ["s5", "s1"])
        #expect(await db.genres().allSatisfy { !$0.name.isEmpty })
    }

    @Test func genreSpellingsAreMerged() async throws {
        let albums = [(genre: "Hip-Hop", cover: "c1" as String?, count: 1), ("hip hop", nil, 1), ("Hip-Hop; Jazz", "c3", 1), ("", "c4", 1)]
        let genres = GenreSummary.grouped(albums: albums, songs: [("Hip-Hop", 5), ("HipHop", 1), ("Jazz", 2), ("Rock", 4)])
        #expect(genres == [GenreSummary(name: "Hip-Hop", albumCount: 3, songCount: 6, covers: ["c1", "c3"]),
                           GenreSummary(name: "Jazz", albumCount: 1, songCount: 2, covers: ["c3"])])

        let db = tempDatabase()
        try await seed(db, albums: [
            (album("x1", artistId: "x", genre: "Hip-Hop", year: 2001), [song("t1", albumId: "x1", artistId: "x", genre: "Hip-Hop")]),
            (album("x2", artistId: "x", genre: "hip hop / Soul", year: 2002), [song("t2", albumId: "x2", artistId: "x", genre: "hiphop", plays: 3)]),
        ])
        #expect(await db.genres().map(\.name) == ["Hip-Hop", "Soul"])
        #expect(await db.albums(genre: "HIP HOP").map(\.id) == ["x2", "x1"])
        #expect(await db.songs(genre: "Hip-Hop").map(\.id) == ["t2", "t1"])
    }

    @Test func artistSongsAndAppearsOn() async throws {
        let db = try await seeded()
        #expect(await db.songs(artistId: "a").map(\.id) == ["s3", "s4", "s1", "s2"])  // 2004, 1998, 1995
        #expect(await db.appearsOn(artistId: "a").map(\.id) == ["b1"])
        #expect(await db.appearsOn(artistId: "b").isEmpty)
        #expect(await db.appearsOn(artistId: "nobody").isEmpty)
    }

    @Test func similarAlbumsShareGenreOrDecade() async throws {
        let db = try await seeded()
        let a1 = album("a1", artistId: "a", genre: "Rock", year: 1995)
        // b1: same genre and decade; c1: same decade. Albums of the same artist are left out.
        #expect(await db.similarAlbums(to: a1).map(\.id) == ["b1", "c1"])
        #expect(await db.similarAlbums(to: a1, limit: 1).map(\.id) == ["b1"])
        #expect(await db.similarAlbums(to: album("x", artistId: "x", genre: nil, year: nil)).isEmpty)
        #expect(await db.similarAlbums(to: album("x", artistId: "x", genre: nil, year: 2010)).map(\.id) == ["d1"])
    }

    @Test func similarArtistsInLibrary() {
        func artist(_ id: String, _ name: String) -> Artist { decode(["id": id, "name": name]) }
        let library = [artist("1", "Björk"), artist("2", "Aphex Twin"), artist("3", "Boards of Canada")]
        let similar = [artist("2", "Aphex Twin"), artist("", "björk"), artist("9", "Autechre"), artist("2", "Aphex Twin")]
        #expect(Browse.similarInLibrary(similar, library: library).map(\.id) == ["2", "1"])
        #expect(Browse.similarInLibrary([], library: library).isEmpty)
    }

    @Test func topSongsPreferLocalPlays() {
        let songs = [song("s1", albumId: "a", artistId: "a", plays: 5), song("s2", albumId: "a", artistId: "a", plays: 1),
                     song("s3", albumId: "a", artistId: "a"), song("s4", albumId: "a", artistId: "a")]
        #expect(Browse.topSongs(songs, localPlays: ["s3": 2]).map(\.id) == ["s3", "s1", "s2", "s4"])
        #expect(Browse.topSongs(songs, localPlays: [:], limit: 2).map(\.id) == ["s1", "s2"])
    }
}
