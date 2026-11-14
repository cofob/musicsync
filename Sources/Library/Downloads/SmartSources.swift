import Foundation
import Recommend
import Subsonic

/// Input of the smart download rules, read from the local library only.
extension Library {
    /// The songs each enabled rule wants, best first; nil while the mirror has no complete library.
    /// `day` (e.g. "2026-11-14") picks the "Made for You" mixes, as on Home.
    public func smartCandidates(_ settings: SmartSettings, day: String, now: Date = Date()) async -> [SmartRule: [Song]]? {
        let db = database
        guard await db.isHealthy, await db.isPopulated else { return nil }
        var out: [SmartRule: [Song]] = [:]
        if settings.favorites.isOn {
            let starred = await db.starred()
            var list = starred.song
            for album in starred.album { list += await db.album(id: album.id)?.song ?? [] }
            out[.favorites] = list
        }
        if settings.recentAlbums.isOn {
            let cutoff = now.addingTimeInterval(-Double(settings.recentDays) * 86400)
            var list: [Song] = []
            for album in await db.albums(sort: .newest, limit: 500) {
                guard let created = album.created.flatMap(parseDate), created >= cutoff else { break }
                list += await db.album(id: album.id)?.song ?? []
            }
            out[.recentAlbums] = list
        }
        if settings.playlists.isOn {
            var list: [Song] = []
            for id in settings.playlistIDs { list += await db.playlist(id: id)?.entry ?? [] }
            out[.playlists] = list
        }
        guard settings.mostPlayed.isOn || settings.mixes.isOn else { return out }
        let tracks = await db.recommendationTracks(), stats = await history.stats()
        if settings.mostPlayed.isOn {
            out[.mostPlayed] = await db.songs(ids: Self.mostPlayed(tracks, stats, count: settings.mostPlayedCount))
        }
        if settings.mixes.isOn {
            let catalog = Catalog(tracks: tracks, playlists: await db.playlistMembers(), history: await history.events(), stats: stats)
            out[.mixes] = await db.songs(ids: Self.interleave(catalog.madeForYou(day: day).map(\.trackIds)))
        }
        return out
    }

    /// Top `count` by plays (the server's count or the local history, whichever is higher), then the last play.
    static func mostPlayed(_ tracks: [Track], _ stats: [String: SongStats], count: Int) -> [String] {
        let plays = Dictionary(tracks.map { ($0.id, max($0.serverPlays, stats[$0.id]?.plays ?? 0)) }) { a, _ in a }
        let last: (String) -> Date = { stats[$0]?.lastPlayed ?? .distantPast }
        return plays.filter { $0.value > 0 }.keys.sorted { a, b in
            if plays[a] != plays[b] { return plays[a] ?? 0 > plays[b] ?? 0 }
            if last(a) != last(b) { return last(a) > last(b) }
            return a < b
        }.prefix(count).map { $0 }
    }

    /// First song of each mix, then the second of each, and so on: a tight budget still gets some of every mix.
    static func interleave(_ lists: [[String]]) -> [String] {
        (0..<(lists.map(\.count).max() ?? 0)).flatMap { i in lists.compactMap { i < $0.count ? $0[i] : nil } }
    }
}
