import Foundation
import Library
import Recommend
import Subsonic

/// "Your Stats": the local play history, or the server's play counts while there is none.
extension BrowseModel {
    /// The numbers of one period with the items they name.
    struct StatsPage {
        let stats: ListeningStats
        let songs: [Song]
        let albums: [Album]
        let artists: [Artist]
    }

    func statsPage(period: StatsPeriod) async -> StatsPage {
        let library = app.library
        let events = AppPreferences.shared.listening.usesHistory ? await library?.history.events(limit: 50_000) ?? [] : []
        let tracks = Dictionary((await library?.database.recommendationTracks() ?? []).map { ($0.id, $0) }) { a, _ in a }
        let stats = await Task.detached(priority: .userInitiated) {
            events.isEmpty ? ListeningStats(serverPlays: Array(tracks.values))
                           : ListeningStats(events: events, tracks: tracks, period: period)
        }.value
        let songs = await app.library?.database.songs(ids: stats.songs.map(\.key)) ?? []
        let albums = Dictionary(app.albums.map { ($0.id, $0) }) { a, _ in a }
        let artists = Dictionary(app.artists.map { ($0.name, $0) }) { a, _ in a }
        return StatsPage(stats: stats, songs: songs, albums: stats.albums.compactMap { albums[$0.key] },
                         artists: stats.artists.compactMap { artists[$0.key] })
    }
}
