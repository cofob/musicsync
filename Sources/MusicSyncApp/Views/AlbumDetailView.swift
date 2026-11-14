import SwiftUI
import Subsonic

/// Album page. `headerAccessory` is drawn next to the Play / Shuffle buttons
/// (extension point: e.g. a device sync toggle and status).
struct AlbumDetailView<Accessory: View>: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @ViewBuilder var headerAccessory: (Album) -> Accessory
    @State private var full: Album?
    @State private var loadError: String?

    var body: some View {
        let songs = full?.song ?? []
        ScrollView {
            MediaHeader(cover: { CoverImage(id: album.coverArt, size: 600, cornerRadius: 10) }, title: album.name,
                        canPlay: !songs.isEmpty, onPlay: { model.player.play(songs, shuffled: false) },
                        onShuffle: { model.player.play(songs, shuffled: true) }) {
                ArtistLink(name: album.artistName, id: album.artistId)
                Text(meta(songs)).font(.callout.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            } accessory: {
                FavoriteButton(isOn: model.isStarred(album)) { model.toggleStar(album) }
                headerAccessory(full ?? album)
            }
            if let loadError {
                LoadFailedView(message: loadError) { Task { await load() } }
            } else if full == nil {
                PlaceholderRows(count: album.songCount.map { min($0, 14) } ?? 10).padding(.horizontal, 22)
            } else {
                discs(songs).padding(.horizontal, 22)
                Text(footer(songs)).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.vertical, 20)
            }
        }
        .navigationTitle(album.name)
        .task(id: album.id) { await load() }
    }

    private func load() async {
        loadError = nil
        do { full = try await model.album(album.id) } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }

    /// One `SongList` per disc, with "Disc N" titles when there are several.
    @ViewBuilder private func discs(_ songs: [Song]) -> some View {
        let numbers = songs.map { $0.discNumber ?? 1 }
        let discs = Array(Set(numbers)).sorted()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(discs, id: \.self) { disc in
                let indices = songs.indices.filter { numbers[$0] == disc }
                if discs.count > 1 { Text("Disc \(disc)").font(.headline).foregroundStyle(.secondary).padding(.leading, 10).padding(.top, 8) }
                SongList(songs: indices.map { songs[$0] }, albumArtist: album.artistName) { model.player.play(songs, startAt: indices[$0]) }
            }
        }
    }

    private func meta(_ songs: [Song]) -> String {
        [album.genre, album.year.map(String.init), sourceFormat(songs)].compactMap { $0 }.joined(separator: " · ")
    }

    private func footer(_ songs: [Song]) -> String {
        let count = album.songCount ?? songs.count
        return [formatSongs(count), album.duration.map(formatTotal)].compactMap { $0 }.joined(separator: ", ")
    }

    /// Most common source format among the tracks.
    private func sourceFormat(_ songs: [Song]) -> String? {
        Dictionary(grouping: songs, by: \.sourceFormat).max { $0.value.count < $1.value.count }?.key
    }
}

extension AlbumDetailView where Accessory == AlbumHeaderButtons {
    init(album: Album) { self.init(album: album) { AlbumHeaderButtons(album: $0) } }
}

/// Artist name in the accent color; opens the artist when its id is known.
struct ArtistLink: View {
    @Environment(AppModel.self) private var model
    let name: String?
    let id: String?

    var body: some View {
        if let name {
            Button(name) { if let id { model.show(.artist(id)) } }
                .buttonStyle(.plain).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.musicAccent)
                .disabled(id == nil).lineLimit(1)
        }
    }
}
