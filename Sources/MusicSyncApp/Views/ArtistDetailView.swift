import SwiftUI
import Subsonic

/// Artist name with Play / Shuffle, then every album with its songs.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// False inside the Artists split view, which keeps its own title.
    var setsTitle = true
    @State private var artist: Artist?
    /// Newest first.
    @State private var albums: [Album] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let artist {
                VStack(alignment: .leading, spacing: 0) {
                    header(artist)
                    ForEach(albums) { album in
                        ArtistAlbumSection(album: album).padding(.top, 36)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 28)
            } else if let loadError {
                LoadFailedView(message: loadError) { Task { await load() } }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        PlaceholderBlock(width: 56, height: 56, cornerRadius: 28)
                        PlaceholderBlock(width: 220, height: 28)
                    }
                    Divider()
                    PlaceholderBlock(width: 130, height: 130, cornerRadius: 8).padding(.top, 24)
                    PlaceholderBlock(width: 180, height: 20)
                    PlaceholderRows(count: 6)
                }
                .shimmering()
                .padding(.horizontal, 32).padding(.vertical, 28)
            }
        }
        .navigationTitle(setsTitle ? artist?.name ?? "Artist" : "Artists")
        .task(id: id) { await load() }
    }

    private func load() async {
        loadError = nil
        // The local library has the artist and its albums; the server is asked only when it does not.
        let local = model.albums.filter { $0.artistId == id }
        if model.usesLocalLibrary, !local.isEmpty, let known = model.artists.first(where: { $0.id == id }) {
            albums = Self.newestFirst(local)
            artist = known
            return
        }
        do {
            let fetched = try await model.client?.getArtist(id: id)
            albums = Self.newestFirst(fetched?.album ?? [])
            artist = fetched
        } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }

    private func header(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ArtistImage(artist: artist).frame(width: 56, height: 56)
                Text(artist.name).font(.system(size: 30, weight: .bold)).lineLimit(2)
                Spacer()
                Button("Play", systemImage: "play.fill") { play(artist, shuffled: false) }
                Button("Shuffle", systemImage: "shuffle") { play(artist, shuffled: true) }
                SyncButton(isOn: model.sync.isArtistSelected(artist.id)) { model.sync.toggleArtist(artist.id) }
                    .help(model.sync.isArtistSelected(artist.id) ? "Remove all albums by this artist from iPod" : "Sync all albums by this artist")
            }
            .buttonStyle(CircleIconStyle(size: 34))
            Divider()
            Text(summary(artist)).foregroundStyle(.secondary)
        }
    }

    private static func newestFirst(_ albums: [Album]) -> [Album] {
        albums.sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }
    }

    private func summary(_ artist: Artist) -> String {
        let songs = albums.reduce(0) { $0 + ($1.songCount ?? 0) }
        return "\(albums.count) \(albums.count == 1 ? "album" : "albums"), \(songs) \(songs == 1 ? "song" : "songs")"
    }

    private func play(_ artist: Artist, shuffled: Bool) {
        Task {
            var songs: [Song] = []
            for album in albums { songs += (try? await model.album(album.id))?.song ?? [] }
            model.player.play(songs, shuffled: shuffled)
        }
    }
}

/// Album cover, title and its songs on an artist page.
private struct ArtistAlbumSection: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var songs: [Song]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.album(album)) {
                CoverImage(id: album.coverArt, size: 300, cornerRadius: 8).frame(width: 130, height: 130)
                    .albumHoverActions(album)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).font(.title2.bold())
                    Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RowMenu { AlbumMenuItems(album: album) }
            }
            Divider()
            if let songs {
                SongList(songs: songs, albumArtist: album.artistName) { model.player.play(songs, startAt: $0) }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: album.id) { songs = (try? await model.album(album.id))?.song ?? [] }
    }
}
