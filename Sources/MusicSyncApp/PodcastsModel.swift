import Foundation
import Observation
import Playback
import Subsonic

/// Podcasts the server follows. The page shows only when the server answers `getPodcasts` and has channels, or the
/// user may add some; a server without podcasts (an error, e.g. code 50 or 70, or Navidrome's HTTP 501) hides it.
@MainActor @Observable
final class PodcastsModel {
    /// Channels without their episodes; a channel page loads those.
    var channels: [PodcastChannel] = []
    var newest: [PodcastEpisode] = []
    /// Users with the podcast role may add and delete channels and episodes.
    var canEdit = false
    /// True once the listing answered.
    var isLoaded = false
    /// Set by a failed listing after an earlier one worked; the page shows it with a retry.
    private(set) var error: String?
    /// Episodes marked as played in this session, by episode id.
    var played: Set<String> = []

    var isVisible: Bool { isLoaded && (!channels.isEmpty || canEdit) }

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    func load() async {
        guard let client = app.client else { channels = []; newest = []; canEdit = false; isLoaded = false; return }
        async let user = try? client.getUser(username: client.config.username)
        do {
            let list = try await client.getPodcasts(includeEpisodes: false)
            let latest = (try? await client.getNewestPodcasts(count: 20)) ?? []
            let role = await user.map { $0.podcastRole == true || $0.adminRole == true } ?? false
            guard isCurrent(client) else { return }
            channels = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            newest = latest
            canEdit = role
            isLoaded = true
            error = nil
        } catch where !error.isCancellation {
            guard isCurrent(client) else { return }
            if case .api(let code, _)? = error as? SubsonicError, [50, 70].contains(code) { isLoaded = false }
            self.error = error.friendlyMessage
        } catch {}
    }

    /// One channel with its episodes, newest first.
    func channel(_ id: String) async throws -> PodcastChannel? {
        guard let client = app.client else { return nil }
        return try await client.getPodcasts(includeEpisodes: true, id: id).first { $0.id == id }
    }

    /// Plays the episodes the server has files for, from `episode`; a bookmark makes it go on where it stopped.
    func play(_ episode: PodcastEpisode, in episodes: [PodcastEpisode]) {
        let songs = episodes.compactMap(\.song)
        guard let song = episode.song, let start = songs.firstIndex(where: { $0.id == song.id }) else { return }
        app.player.play(songs, startAt: start, shuffled: false)
    }

    /// Saved position of an episode (0...1), for its progress bar.
    func progress(_ episode: PodcastEpisode) -> Double? {
        guard !isPlayed(episode), let song = episode.song, let position = app.bookmarks.positions[song.id],
              let duration = song.duration else { return nil }
        return ResumePoint.progress(position: position, duration: TimeInterval(duration))
    }

    func isPlayed(_ episode: PodcastEpisode) -> Bool { played.contains(episode.id) || (episode.playCount ?? 0) > 0 }

    /// Counts a play on the server and drops the bookmark.
    func markPlayed(_ episode: PodcastEpisode) {
        guard let song = episode.song, let client = app.client else { return }
        played.insert(episode.id)
        app.bookmarks.clear(song.id)
        Task { do { try await client.scrobble(ids: [song.id]) } catch { app.report(error) } }
    }

    /// Asks the server to download the episode, so it can be played.
    func download(_ episode: PodcastEpisode) async {
        do { try await app.client?.downloadPodcastEpisode(id: episode.id) } catch { app.report(error) }
    }

    func deleteEpisode(_ episode: PodcastEpisode) async {
        do { try await app.client?.deletePodcastEpisode(id: episode.id) } catch { app.report(error) }
    }

    func add(url: String) async {
        do {
            try await app.client?.createPodcastChannel(url: url)
            await load()
        } catch { app.report(error) }
    }

    func delete(_ channel: PodcastChannel) async {
        do {
            try await app.client?.deletePodcastChannel(id: channel.id)
            await load()
        } catch { app.report(error) }
    }

    /// Makes the server look for new episodes.
    func refresh() async {
        do {
            try await app.client?.refreshPodcasts()
            await load()
        } catch { app.report(error) }
    }

    private func isCurrent(_ client: SubsonicClient) -> Bool { client.baseURL == app.client?.baseURL }
}
