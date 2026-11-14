import Integration
import SwiftUI
import Subsonic

/// Starred songs, albums and artists. Items unstarred here leave the list at once.
struct FavoritesView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case songs = "Songs", albums = "Albums", artists = "Artists"
        var id: Self { self }
    }

    /// Remembered between launches (and set by `Shot`).
    static let segmentKey = "favoritesSegment"

    @Environment(AppModel.self) private var model
    @AppStorage(FavoritesView.segmentKey, store: .app) private var segment = Segment.songs
    @State private var result: SearchResult3?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Favorites").font(.system(size: 30, weight: .bold))
                    Spacer()
                    Picker("Show", selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if let loadError {
                    LoadFailedView(message: loadError) { Task { await load() } }
                } else if let result {
                    content(result)
                } else if segment == .songs {
                    PlaceholderRows(count: 10, cover: true)
                } else {
                    LazyVGrid(columns: albumGridColumns, spacing: 28) { ForEach(0..<8, id: \.self) { _ in PlaceholderCard() } }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .navigationTitle("Favorites")
        .task(id: model.libraryVersion) { await load() }
    }

    private func load() async {
        do {
            let found = try await model.favorites()
            guard !Task.isCancelled else { return }
            result = found
            loadError = nil
        } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }

    @ViewBuilder private func content(_ result: SearchResult3) -> some View {
        switch segment {
        case .songs:
            let songs = result.song.filter { model.isStarred($0) && matches($0.title, $0.artistName, $0.album) }
            if songs.isEmpty { empty("No Favorite Songs", "music.note") } else {
                PlayShuffleButtons(onPlay: { model.player.play(songs, shuffled: false) }, onShuffle: { model.player.play(songs, shuffled: true) })
                SongList(songs: songs, leading: .cover) { model.player.play(songs, startAt: $0) }
            }
        case .albums:
            let albums = result.album.filter { model.isStarred($0) && matches($0.name, $0.artistName) }
            if albums.isEmpty { empty("No Favorite Albums", "square.stack") } else {
                LazyVGrid(columns: albumGridColumns, spacing: 28) { ForEach(albums) { AlbumCard(album: $0) } }
            }
        case .artists:
            let artists = result.artist.filter { model.isStarred($0) && matches($0.name) }
            if artists.isEmpty { empty("No Favorite Artists", "music.microphone") } else {
                LazyVGrid(columns: albumGridColumns, spacing: 28) { ForEach(artists) { ArtistCard(artist: $0) } }
            }
        }
    }

    /// "Find in Favorites".
    private func matches(_ fields: String?...) -> Bool {
        model.query.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(model.query) == true }
    }

    private func empty(_ title: String, _ symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text("Items you mark with a star appear here."))
            .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// Round artist image and name; opens the artist.
private struct ArtistCard: View {
    @Environment(AppModel.self) private var model
    let artist: Artist

    var body: some View {
        NavigationLink(value: Route.artist(artist.id)) {
            VStack(spacing: 8) {
                ArtistImage(artist: artist).aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                Text(artist.name).lineLimit(2).multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ArtistMenuItems(artist: artist) }
    }
}

/// Artist actions for context menus.
struct ArtistMenuItems: View {
    @Environment(AppModel.self) private var model
    let artist: Artist

    var body: some View {
        StationButton(seed: .artist(artist.name))
        Button(model.isStarred(artist) ? "Undo Favorite" : "Favorite", systemImage: model.isStarred(artist) ? "star.slash" : "star") {
            model.toggleStar(artist)
        }
        ShareMenuItems(target: ShareTarget(artist: artist))
    }
}
