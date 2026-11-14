import Foundation
import Recommend
import Subsonic
import Testing
@testable import Library

@Suite struct HistoryTests {
    private func event(_ id: String, _ t: Double, played: Double = 200, duration: Double = 200, source: PlaySource = .album) -> PlayEvent {
        PlayEvent(songId: id, startedAt: Date(timeIntervalSince1970: t), played: played, duration: duration, source: source)
    }

    @Test func recordsEventsAndStats() async throws {
        let dir = TempDir()
        let history = PlayHistory(serverKey: "demo@http://stub", directory: dir.url)
        try await history.record(event("s1", 100))
        try await history.record(event("s1", 500, played: 50))
        try await history.record(event("s2", 900, played: 120, duration: 0, source: .radio))
        try await history.record(event("s1", 1300, played: 150))
        let events = await history.events()
        #expect(events.map(\.songId) == ["s1", "s1", "s2", "s1"])
        #expect(events[2].source == .radio && events[2].played == 120 && events[1].startedAt.timeIntervalSince1970 == 500)
        #expect(await history.events(limit: 2).map(\.startedAt.timeIntervalSince1970) == [900, 1300])
        let stats = await history.stats()
        #expect(stats["s1"]?.plays == 2 && stats["s1"]?.skips == 1)
        #expect(stats["s1"]?.lastPlayed?.timeIntervalSince1970 == 1300)
        #expect(abs((stats["s1"]?.completion ?? 0) - (1 + 0.25 + 0.75) / 3) < 1e-9)
        #expect(stats["s2"]?.skips == 1 && stats["s2"]?.completion == 1)  // unknown length: no completion data

        // Survives a reopen, and is separate per server.
        #expect(await PlayHistory(serverKey: "demo@http://stub", directory: dir.url).events().count == 4)
        #expect(await PlayHistory(serverKey: "other@http://stub", directory: dir.url).events().isEmpty)
    }

    @Test func clearRemovesEveryEvent() async throws {
        let dir = TempDir()
        let history = PlayHistory(serverKey: "k", directory: dir.url)
        try await history.clear()  // works before the first play
        for t in 0..<3 { try await history.record(event("s\(t)", Double(t))) }
        try await history.clear()
        #expect(await history.events().isEmpty)
        #expect(await history.stats().isEmpty)
        try await history.record(event("s9", 9))
        #expect(await history.events().map(\.songId) == ["s9"])
    }

    @Test func keepsOnlyTheNewestEvents() async throws {
        let dir = TempDir()
        let history = PlayHistory(serverKey: "k", directory: dir.url, limit: 3)
        for t in 0..<6 { try await history.record(event("s\(t)", Double(t))) }
        #expect(await history.events().map(\.songId) == ["s3", "s4", "s5"])
    }

    @Test func libraryGivesRecommenderInput() async throws {
        let db = tempDatabase()
        let starred: Song = decode(["id": "s3", "title": "Loved", "artist": "B", "albumId": "a2", "genre": "Rock; Pop", "year": 2001,
                                    "starred": "2024-05-01T00:00:00Z", "userRating": 4, "playCount": 7, "created": "2024-03-01T10:00:00.123Z"])
        try await seed(db, albums: [
            (album("a1", "One"), [song("s1", "A", albumId: "a1"), song("s2", "B", albumId: "a1", plays: 2)]),
            (decode(["id": "a2", "name": "Two", "played": "2025-01-02T03:04:05Z"]), [starred]),
        ])
        let tracks = Dictionary(uniqueKeysWithValues: await db.recommendationTracks().map { ($0.id, $0) })
        #expect(tracks.count == 3 && tracks["s2"]?.serverPlays == 2 && tracks["s1"]?.lastPlayed == nil)
        let loved = try #require(tracks["s3"])
        #expect(loved.starred && loved.rating == 4 && loved.genres == ["rock", "pop"] && loved.year == 2001 && loved.albumId == "a2")
        #expect(abs((loved.created?.timeIntervalSince1970 ?? 0) - 1_709_287_200.123) < 0.001)
        #expect(loved.lastPlayed == Date(timeIntervalSince1970: 1_735_787_045))
        #expect(await db.songs(ids: ["s3", "gone", "s1"]).map(\.id) == ["s3", "s1"])

        let playlist: Playlist = decode(["id": "p1", "name": "Mix"])
        try await db.storePlaylist(playlist.withEntries([starred, song("s1", "A", albumId: "a1")]))
        try await db.storePlaylist((decode(["id": "p2", "name": "Solo"]) as Playlist).withEntries([song("s2", "B", albumId: "a1")]))
        #expect(await db.playlistMembers() == [["s3", "s1"], ["s2"]])
    }
}
