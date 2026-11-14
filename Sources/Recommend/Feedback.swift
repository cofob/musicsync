import Foundation

public extension PlayEvent {
    /// Stopped in the first 30 seconds or the first quarter: the listener did not want this song.
    var earlySkip: Bool { !completed && (played < 30 || played < duration * 0.25) }
}

/// What listening said about each song and its artist: a completed play counts for it, an early skip and
/// "Not for Me" against it. Old plays count less (half after about three weeks), so one skip does not hide a song for good.
struct Feedback: Sendable {
    /// Net signal: +0.5 per completed play, -1 per early skip, -2 for "Not for Me".
    let songs: [String: Double]
    /// The same sums per artist key.
    let artists: [String: Double]
    /// Songs mixes, stations and AutoPlay leave out: marked "Not for Me", or skipped more than played.
    let rejected: Set<String>

    init(_ events: [PlayEvent], tracks: [String: Track], dislikes: Set<String>, now: Date) {
        var songs: [String: Double] = [:], artists: [String: Double] = [:]
        func add(_ id: String, _ value: Double) {
            songs[id, default: 0] += value
            if let artist = tracks[id].map({ Track.key($0.artist) }), !artist.isEmpty { artists[artist, default: 0] += value }
        }
        for event in events {
            let decay = exp(-max(0, now.timeIntervalSince(event.startedAt)) / (30 * 86400))
            if event.completed { add(event.songId, 0.5 * decay) } else if event.earlySkip { add(event.songId, -decay) }
        }
        for id in dislikes.sorted() { add(id, -2) }
        self.songs = songs
        self.artists = artists
        rejected = dislikes.union(songs.filter { $0.value <= -0.5 }.keys)
    }

    /// -1...1 for a song.
    func song(_ id: String) -> Double { max(-1, min(1, songs[id] ?? 0)) }

    /// -1...1 for an artist; five net skips give the full -1, so it moves slowly.
    func artist(_ key: String) -> Double { max(-1, min(1, (artists[key] ?? 0) / 5)) }
}
