import Foundation

/// Time window of the stats page.
public enum StatsPeriod: String, CaseIterable, Sendable, Identifiable {
    case month = "Last 4 Weeks", halfYear = "Last 6 Months", allTime = "All Time"
    public var id: Self { self }

    func start(before now: Date, _ calendar: Calendar) -> Date? {
        switch self {
        case .month: calendar.date(byAdding: .day, value: -28, to: now)
        case .halfYear: calendar.date(byAdding: .month, value: -6, to: now)
        case .allTime: nil
        }
    }

    /// One chart bar covers this much time.
    public var bar: Calendar.Component {
        switch self {
        case .month: .day
        case .halfYear: .weekOfYear
        case .allTime: .month
        }
    }
}

/// Top songs, albums and artists and the listening time of one period.
public struct ListeningStats: Sendable, Equatable {
    /// A song id, album id or artist name with its plays and listened seconds.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let key: String
        public let plays: Int
        public let seconds: Double
        public var id: String { key }
    }

    public struct Bar: Sendable, Hashable, Identifiable {
        public let start: Date
        public let seconds: Double
        public var id: Date { start }
    }

    public let songs: [Entry]
    public let albums: [Entry]
    public let artists: [Entry]
    /// Completed plays (the scrobble rule).
    public let plays: Int
    /// Seconds listened, skips included.
    public let seconds: Double
    /// Listening time per day, week or month, oldest first; empty for server counts.
    public let bars: [Bar]
    /// Built from the server's play counts: there is no local history yet.
    public let fromServer: Bool

    public var isEmpty: Bool { plays == 0 }

    /// From the local history. Events of songs missing from `tracks` count for the totals only.
    public init(events: [PlayEvent], tracks: [String: Track], period: StatsPeriod, now: Date = Date(),
                calendar: Calendar = .current, limit: Int = 10) {
        let start = period.start(before: now, calendar)
        let shown = events.filter { event in event.startedAt <= now && start.map { event.startedAt >= $0 } ?? true }
        var tally = Tally()
        for event in shown {
            let track = tracks[event.songId]
            tally.add(song: event.songId, album: track?.albumId, artist: track?.artist, plays: event.completed ? 1 : 0, seconds: event.played)
        }
        self.init(tally, limit, plays: shown.filter(\.completed).count, seconds: shown.reduce(0) { $0 + $1.played },
                  bars: Self.bars(shown, from: start ?? shown.map(\.startedAt).min(), to: now, period.bar, calendar), fromServer: false)
    }

    /// From the play counts of the server (all time), for a library without local history.
    public init(serverPlays tracks: [Track], limit: Int = 10) {
        var tally = Tally()
        for track in tracks where track.serverPlays > 0 {
            let plays = min(track.serverPlays, 1_000_000_000)  // the sums must not overflow on junk counts
            tally.add(song: track.id, album: track.albumId, artist: track.artist, plays: plays,
                      seconds: Double(plays) * Double(track.duration ?? 0))
        }
        let all = tally.songs.values
        self.init(tally, limit, plays: all.reduce(0) { $0 + $1.plays }, seconds: all.reduce(0) { $0 + $1.seconds }, bars: [], fromServer: true)
    }

    private init(_ tally: Tally, _ limit: Int, plays: Int, seconds: Double, bars: [Bar], fromServer: Bool) {
        songs = Self.top(tally.songs, limit)
        albums = Self.top(tally.albums, limit)
        artists = Self.top(tally.artists, limit)
        self.plays = plays
        self.seconds = seconds
        self.bars = bars
        self.fromServer = fromServer
    }

    /// Running sums by song, album and artist.
    private struct Tally {
        typealias Sums = [String: (plays: Int, seconds: Double)]
        var songs = Sums(), albums = Sums(), artists = Sums()

        mutating func add(song: String, album: String?, artist: String?, plays: Int, seconds: Double) {
            func add(_ key: String?, _ table: inout Sums) {
                guard let key, !key.isEmpty else { return }
                let old = table[key] ?? (0, 0)
                table[key] = (old.plays + plays, old.seconds + seconds)
            }
            add(song, &songs)
            add(album, &albums)
            add(artist, &artists)
        }
    }

    /// Most plays first, then the most time, then by key; entries without a completed play are left out.
    private static func top(_ table: Tally.Sums, _ limit: Int) -> [Entry] {
        table.filter { $0.value.plays > 0 }
            .sorted { a, b in a.value.plays != b.value.plays ? a.value.plays > b.value.plays
                : a.value.seconds != b.value.seconds ? a.value.seconds > b.value.seconds : a.key < b.key }
            .prefix(limit).map { Entry(key: $0.key, plays: $0.value.plays, seconds: $0.value.seconds) }
    }

    /// One bar per day, week or month from `start` to `end`, empty ones included.
    private static func bars(_ events: [PlayEvent], from start: Date?, to end: Date, _ unit: Calendar.Component, _ calendar: Calendar) -> [Bar] {
        guard let start, var date = calendar.dateInterval(of: unit, for: start)?.start else { return [] }
        var bars: [Bar] = []
        while date <= end, let next = calendar.date(byAdding: unit, value: 1, to: date) {
            let seconds = events.filter { $0.startedAt >= date && $0.startedAt < next }.reduce(0) { $0 + $1.played }
            bars.append(Bar(start: date, seconds: seconds))
            date = next
        }
        return bars
    }
}
