import SwiftUI
import Subsonic

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var full: Playlist?
    @State private var loadError: String?

    var body: some View {
        let songs = filter(full?.entry ?? [])
        ScrollView {
            MediaHeader(cover: { CoverImage(id: playlist.coverArt, size: 600, cornerRadius: 10, symbol: "music.note.list") },
                        title: playlist.name, canPlay: !songs.isEmpty, onPlay: { model.player.play(songs, shuffled: false) },
                        onShuffle: { model.player.play(songs, shuffled: true) }) {
                if let owner = playlist.owner { Text(owner).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.musicAccent) }
                if let comment = playlist.comment, !comment.isEmpty { Text(comment).foregroundStyle(.secondary).lineLimit(3) }
                Text([playlist.songCount.map { "\($0) songs" }, playlist.duration.map(formatTotal)].compactMap { $0 }.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            } accessory: {
                SyncButton(isOn: model.sync.isPlaylistSelected(playlist.id)) { model.sync.togglePlaylist(playlist.id) }
            }
            if let loadError {
                LoadFailedView(message: loadError) { Task { await load() } }
            } else if full == nil {
                PlaceholderRows(count: playlist.songCount.map { min($0, 12) } ?? 10, cover: true).padding(.horizontal, 22)
            } else {
                VStack(spacing: 0) {
                    TrackListHeader()
                    SongList(songs: songs, leading: .cover) { model.player.play(songs, startAt: $0) }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
        }
        .navigationTitle(playlist.name)
        .task(id: playlist.id) { await load() }
    }

    private func load() async {
        loadError = nil
        do { full = try await model.playlist(playlist.id) } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }

    /// "Find in Playlist".
    private func filter(_ songs: [Song]) -> [Song] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return songs }
        return songs.filter { [$0.title, $0.artistName, $0.album].contains { $0?.localizedCaseInsensitiveContains(query) == true } }
    }
}
