import SwiftUI
import Subsonic

/// "All Playlists": grid of playlist covers.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.query
        let playlists = query.isEmpty ? model.playlists : model.playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        ScrollView {
            LazyVGrid(columns: albumGridColumns, spacing: 28) {
                ForEach(playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist)) {
                        VStack(alignment: .leading, spacing: 2) {
                            CoverImage(id: playlist.coverArt, size: 400, cornerRadius: 10, symbol: "music.note.list")
                                .playlistHoverActions(playlist)
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2).padding(.bottom, 6)
                            Text(playlist.name).lineLimit(2)
                            Text(playlist.songCount.map(formatSongs) ?? "").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { model.play(playlist) }
                        Button("Shuffle", systemImage: "shuffle") { model.play(playlist, shuffled: true) }
                        SyncMenuItem(isOn: model.sync.isPlaylistSelected(playlist.id)) { model.sync.togglePlaylist(playlist.id) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .overlay {
            if playlists.isEmpty { ContentUnavailableView("No Playlists", systemImage: "music.note.list") }
        }
        .navigationTitle("Playlists")
    }
}
