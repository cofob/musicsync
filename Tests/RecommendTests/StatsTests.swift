import Foundation
import Testing
@testable import Recommend

@Suite struct StatsTests {
    private let day: TimeInterval = 86400
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// 2026-03-01 00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_772_323_200)

    private func play(_ id: String, daysAgo: Double, played: Double = 200) -> PlayEvent {
        PlayEvent(songId: id, startedAt: now.addingTimeInterval(-daysAgo * day), played: played, duration: 200)
    }

    private let tracks = [
        "s1": Track(id: "s1", title: "One", artist: "A", albumId: "al1", duration: 200, serverPlays: 3),
        "s2": Track(id: "s2", title: "Two", artist: "A", albumId: "al1", duration: 200, serverPlays: 10),
        "s3": Track(id: "s3", title: "Three", artist: "B", albumId: "al2", duration: 100),
    ]

    @Test func topListsAndTotalsOfAPeriod() {
        let events = [play("s1", daysAgo: 1), play("s1", daysAgo: 2), play("s2", daysAgo: 3), play("s3", daysAgo: 3),
                      play("s3", daysAgo: 4, played: 5),  // a skip: time counts, the play does not
                      play("s3", daysAgo: 40), play("s3", daysAgo: 41), play("s3", daysAgo: 42),
                      play("gone", daysAgo: 5)]
        let month = ListeningStats(events: events, tracks: tracks, period: .month, now: now, calendar: calendar)
        #expect(month.songs.map(\.key) == ["s1", "s3", "gone", "s2"])  // ties: by time, then by id
        #expect(month.songs.first == .init(key: "s1", plays: 2, seconds: 400))
        #expect(month.albums.map(\.key) == ["al1", "al2"] && month.albums[0].plays == 3)
        #expect(month.artists.map(\.key) == ["A", "B"])
        #expect(month.plays == 5 && month.seconds == 1005 && !month.fromServer)
        #expect(month.bars.count == 29 && month.bars.last?.start == now)  // 28 days back, today included
        #expect(month.bars.reduce(0) { $0 + $1.seconds } == 1005)
        #expect(month.bars[month.bars.count - 2].seconds == 200)

        let half = ListeningStats(events: events, tracks: tracks, period: .halfYear, now: now, calendar: calendar)
        #expect(half.songs.first?.key == "s3" && half.songs.first?.plays == 4 && half.artists.first?.key == "B")
        let all = ListeningStats(events: events, tracks: tracks, period: .allTime, now: now, calendar: calendar, limit: 1)
        #expect(all.songs.count == 1 && all.plays == 8 && all.bars.count == 3)  // January to March
    }

    @Test func emptyHistoryAndServerCounts() {
        let none = ListeningStats(events: [], tracks: tracks, period: .allTime, now: now, calendar: calendar)
        #expect(none.isEmpty && none.bars.isEmpty && none.songs.isEmpty)
        let server = ListeningStats(serverPlays: Array(tracks.values))
        #expect(server.fromServer && server.songs.map(\.key) == ["s2", "s1"] && server.plays == 13)
        #expect(server.albums == [.init(key: "al1", plays: 13, seconds: 2600)] && server.artists.map(\.key) == ["A"])
        #expect(server.seconds == 2600 && server.bars.isEmpty)
    }

    @Test func junkServerCountsDoNotOverflow() {
        let junk = [Track(id: "a", title: "A", artist: "A", albumId: "al", duration: .max, serverPlays: .max),
                    Track(id: "b", title: "B", artist: "A", albumId: "al", duration: .max, serverPlays: .max)]
        let server = ListeningStats(serverPlays: junk)
        #expect(server.plays == 2_000_000_000 && server.albums.first?.plays == 2_000_000_000)
    }
}
