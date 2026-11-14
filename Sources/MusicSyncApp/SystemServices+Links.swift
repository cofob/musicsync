import AppKit
import CoreSpotlight
import Integration
import Subsonic

/// Deep links (`musicsync://`), Spotlight results, Handoff activities and playback commands all end here.
extension SystemServices {
    func open(_ link: DeepLink) {
        switch link {
        case .command(let command): run(command)
        case .search(let text): search(text)
        case .show(.artist, let id): app.show(.artist(id))
        case .show(let kind, let id): load { [app] in
            switch kind {
            case .album: if let album = try await app.album(id) { app.show(.album(album)) }
            case .playlist: if let playlist = try await app.playlist(id) { app.show(.playlist(playlist)) }
            default: if let song = try await app.client?.getSong(id: id) { app.goToAlbum(song) }
            }
        }
        case .play(let kind, let id): load { [app, weak self] in
            if let songs = try await self?.songs(kind, id: id), !songs.isEmpty { app.player.play(songs) }
        }
        }
    }

    /// Runs a load for the current server; a server change meanwhile drops the result, failures show an alert.
    private func load(_ body: @escaping @MainActor () async throws -> Void) {
        let store = app.store
        Task {
            do { try await body() } catch where store === app.store { app.report(error) } catch {}
        }
    }

    private func songs(_ kind: DeepLink.Kind, id: String) async throws -> [Song] {
        switch kind {
        case .album: return try await app.album(id)?.song ?? []
        case .playlist: return try await app.playlist(id)?.entry ?? []
        case .song:
            guard let client = app.client else { return [] }
            return [try await client.getSong(id: id)]
        case .artist:
            var songs: [Song] = []
            for album in try await app.client?.getArtist(id: id).album ?? [] { songs += try await app.album(album.id)?.song ?? [] }
            return songs
        }
    }

    private func search(_ text: String) {
        app.selection = .search
        // A new selection clears the search text a moment later (`RootView`).
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            app.searchText = text
            if !text.isEmpty { app.search.submit(text) }
        }
    }

    func run(_ command: DeepLink.Command) {
        let player = app.player
        switch command {
        case .play: if !player.isPlaying { player.toggle() }
        case .pause: if player.isPlaying { player.toggle() }
        case .toggle: player.toggle()
        case .next: player.next()
        case .previous: player.previous()
        case .favorite: if let song = currentSong, !app.isStarred(song) { app.toggleStar(song) }
        }
    }

    var currentSong: Song? {
        if case .server(let song)? = app.player.current { return song }
        return nil
    }

    /// The page on screen, else the playing song: the Handoff activity and Spotlight suggestion.
    var activityLink: (link: DeepLink, title: String)? {
        if !app.showNowPlaying {
            switch app.path.last {
            case .album(let album)?: return (.show(.album, id: album.id), album.name)
            case .playlist(let playlist)?: return (.show(.playlist, id: playlist.id), playlist.name)
            case .artist(let id)?: return (.show(.artist, id: id), app.artists.first { $0.id == id }?.name ?? "Artist")
            default: break
            }
            if app.path.isEmpty, case .playlist(let id)? = app.selection, let playlist = app.playlists.first(where: { $0.id == id }) {
                return (.show(.playlist, id: id), playlist.name)
            }
        }
        return currentSong.map { (.show(.song, id: $0.id), $0.title) }
    }

    /// The link inside a continued activity: ours (`userInfo["url"]`) or a picked Spotlight result.
    static func link(in activity: NSUserActivity) -> DeepLink? {
        let text = activity.userInfo?["url"] as? String ?? activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        return text.flatMap(URL.init(string:)).flatMap(DeepLink.init(url:))
    }
}
