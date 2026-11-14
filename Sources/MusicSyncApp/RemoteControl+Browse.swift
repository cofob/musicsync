import Integration
import Recommend
import Remote
import Subsonic

/// The remote's library: lists, opened artists, albums, playlists and mixes, search, play and lyrics.
extension RemoteControl {
    /// A page of all artists, albums, playlists or mixes, from the library lists.
    func list(_ kind: RemoteKind, offset: Int) async -> HTTPResponse {
        switch kind {
        case .artist:
            return .json(remember(.page(app.artists, offset: offset, title: "Artists") { Self.item($0) }))
        case .album:
            return .json(remember(.page(app.albums, offset: offset, title: "Albums") { Self.item($0) }))
        case .playlist:
            return .json(remember(.page(app.playlists, offset: offset, title: "Playlists") { Self.item($0) }))
        case .mix:
            let mixes = app.mixes
            if mixes.isAvailable { await mixes.load() }
            return .json(remember(.page(mixes.mixes + mixes.because, offset: offset, title: "Mixes") { mix(item: $0) }))
        case .song:
            return .error(.badRequest)
        }
    }

    /// The albums of an artist, or the songs of an album, playlist or mix, a page at a time.
    func detail(_ kind: RemoteKind, id: String, offset: Int) async -> HTTPResponse {
        let store = app.store
        do {
            var list: RemoteList
            switch kind {
            case .artist:
                var albums = app.albums.filter { $0.artistId == id }
                if albums.isEmpty, let client = app.client { albums = try await client.getArtist(id: id).album ?? [] }
                let artist = app.artists.first { $0.id == id }
                list = .page(albums, offset: offset, title: artist?.name ?? albums.first?.artist ?? "Artist") { Self.item($0) }
                list.cover = artist?.coverArt.map(RemoteState.coverPath)
            case .album:
                guard let album = try await app.album(id) else { return .error(.notFound) }
                list = .page(album.song ?? [], offset: offset, title: album.name) { Self.item($0, detail: $0.artist == album.artist ? "" : $0.artist) }
                (list.detail, list.cover) = (album.artist, album.coverArt.map(RemoteState.coverPath))
            case .playlist:
                guard let playlist = try await app.playlist(id) else { return .error(.notFound) }
                list = .page(playlist.entry ?? [], offset: offset, title: playlist.name) { Self.item($0) }
                (list.detail, list.cover) = ("\(playlist.songCount ?? playlist.entry?.count ?? 0) songs", playlist.coverArt.map(RemoteState.coverPath))
            case .mix:
                guard let mix = app.mixes.mix(id: id) else { return .error(.notFound) }
                let songs = app.mixes.songs(of: mix)
                list = .page(songs, offset: offset, title: Self.mixTitle(mix)) { Self.item($0) }
                (list.detail, list.cover) = (mix.kind == .because ? mix.reason : mix.subtitle, songs.first?.coverArt.map(RemoteState.coverPath))
            case .song:
                return .error(.badRequest)
            }
            guard store === app.store else { return .error(.conflict) }
            return .json(remember(list))
        } catch {
            return .error(.unavailable)
        }
    }

    /// Artists, albums and songs from the server search, then playlists and mixes by name.
    func search(_ text: String) async -> HTTPResponse {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let client = app.client else { return .json(RemoteList(title: "Search", items: [])) }
        let store = app.store
        do {
            let found = try await client.search3(text, artistCount: 6, albumCount: 12, songCount: 12)
            guard store === app.store else { return .error(.conflict) }
            let playlists = app.playlists.filter { $0.name.localizedStandardContains(text) }.prefix(6)
            let mixes = (app.mixes.mixes + app.mixes.because).filter { Self.mixTitle($0).localizedStandardContains(text) }
            let items = found.artist.map { Self.item($0) } + found.album.map { Self.item($0) }
                + found.song.map { Self.item($0) } + playlists.map { Self.item($0) } + mixes.map { mix(item: $0) }
            return .json(remember(RemoteList(title: "Search", items: items)))
        } catch {
            return .error(.unavailable)
        }
    }

    /// Plays an artist, album, playlist, mix or song now (from song `start`), next, or at the end of the queue.
    func play(_ kind: RemoteKind, id: String, mode: PlayMode, start: Int) async -> HTTPResponse {
        let store = app.store
        var songs: [Song] = []
        if kind == .mix {
            songs = app.mixes.mix(id: id).map(app.mixes.songs(of:)) ?? []
        } else if let link = DeepLink.Kind(rawValue: kind.rawValue) {
            do { songs = try await app.system.songs(link, id: id) } catch { return .error(.unavailable) }
        }
        guard store === app.store else { return .error(.conflict) }
        guard !songs.isEmpty else { return .error(.notFound) }
        switch mode {
        case .now: app.mixes.play(songs, from: PlaySource(rawValue: kind.rawValue) ?? .other, startAt: min(start, songs.count - 1))
        case .next: app.player.playNext(songs.map(PlayItem.server))
        case .last: app.player.addToQueue(songs.map(PlayItem.server))
        }
        return .json(state())
    }

    /// Lyrics of the current song; none for radio and podcasts.
    func lyrics() async -> RemoteLyrics {
        guard let song = currentSong else { return RemoteLyrics(id: app.player.current?.id, lines: []) }
        let found = await app.lyrics(for: song)
        return RemoteLyrics(id: song.id, lines: found?.lines.map { RemoteLyrics.Line(start: $0.start, text: $0.text) } ?? [])
    }

    // MARK: Items

    /// Lets the page load the covers of `list` (see `cover`).
    private func remember(_ list: RemoteList) -> RemoteList {
        if listedCovers.count > 5000 { listedCovers.removeAll() }
        let ids = ([list.cover] + list.items.map(\.cover)).compactMap { $0?.split(separator: "/").last?.removingPercentEncoding }
        listedCovers.formUnion(ids)
        return list
    }

    private func mix(item mix: Mix) -> RemoteItem {
        RemoteItem(kind: .mix, id: mix.id, name: Self.mixTitle(mix), detail: mix.kind == .because ? mix.reason : mix.subtitle,
                   coverArt: app.mixes.songs(of: mix).first?.coverArt)
    }

    private static func mixTitle(_ mix: Mix) -> String { mix.kind == .because ? "Because You Listened to \(mix.title)" : mix.title }

    private static func item(_ artist: Artist) -> RemoteItem {
        RemoteItem(kind: .artist, id: artist.id, name: artist.name, detail: artist.albumCount.map { $0 == 1 ? "1 album" : "\($0) albums" },
                   coverArt: artist.coverArt)
    }

    private static func item(_ album: Album) -> RemoteItem {
        RemoteItem(kind: .album, id: album.id, name: album.name, detail: album.artist, coverArt: album.coverArt)
    }

    private static func item(_ playlist: Playlist) -> RemoteItem {
        RemoteItem(kind: .playlist, id: playlist.id, name: playlist.name, detail: playlist.songCount.map { "\($0) songs" }, coverArt: playlist.coverArt)
    }

    private static func item(_ song: Song, detail: String? = nil) -> RemoteItem {
        RemoteItem(kind: .song, id: song.id, name: song.title, detail: detail ?? [song.artist, song.album].compactMap { $0 }.joined(separator: " · "),
                   coverArt: song.coverArt)
    }
}
