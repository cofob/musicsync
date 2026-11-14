import Foundation
import Library
import Recommend
import Subsonic

/// "Your Stats": the local play history, or the server's play counts while there is none.
extension BrowseModel {
    /// History and songs, read once per visit; each period is computed from them.
    struct StatsInput: Sendable {
        let events: [PlayEvent]
        let tracks: [String: Track]
    }

    /// The numbers of one period with the items they name.
    struct StatsPage {
        let stats: ListeningStats
        let songs: [Song]
        let albums: [Album]
        let artists: [Artist]
    }

    func statsInput() async -> StatsInput {
        guard let library = app.library else { return StatsInput(events: [], tracks: [:]) }
        let events = await library.history.events(limit: 50_000)
        let tracks = await library.database.recommendationTracks()
        return StatsInput(events: events, tracks: Dictionary(tracks.map { ($0.id, $0) }) { a, _ in a })
    }

    func statsPage(_ input: StatsInput, period: StatsPeriod) async -> StatsPage {
        let stats = await Task.detached(priority: .userInitiated) {
            input.events.isEmpty ? ListeningStats(serverPlays: Array(input.tracks.values))
                                 : ListeningStats(events: input.events, tracks: input.tracks, period: period)
        }.value
        let songs = await app.library?.database.songs(ids: stats.songs.map(\.key)) ?? []
        let albums = Dictionary(app.albums.map { ($0.id, $0) }) { a, _ in a }
        let artists = Dictionary(app.artists.map { ($0.name, $0) }) { a, _ in a }
        return StatsPage(stats: stats, songs: songs, albums: stats.albums.compactMap { albums[$0.key] },
                         artists: stats.artists.compactMap { artists[$0.key] })
    }
}
