import SwiftUI

struct DevicePlaylistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let playlists = model.ipod.snapshot?.playlists ?? []
        Group {
            if model.ipod.snapshot == nil {
                ProgressView()
            } else if playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list")
            } else {
                ScrollView {
                    LazyVGrid(columns: albumGridColumns, spacing: 24) {
                        ForEach(playlists) { playlist in
                            DeviceCard(route: .devicePlaylist(playlist.id), imageID: playlist.tracks.lazy.compactMap(\.imageID).first,
                                       symbol: "music.note.list", title: playlist.name,
                                       subtitle: formatSongs(playlist.tracks.count)) { model.play(playlist.tracks) }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Playlists")
    }
}

struct DevicePlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let id: Int

    var body: some View {
        if let playlist = model.ipod.snapshot?.playlists.first(where: { $0.id == id }) {
            ScrollView {
                MediaHeader(cover: { DeviceCoverImage(imageID: playlist.tracks.lazy.compactMap(\.imageID).first, cornerRadius: 10, symbol: "music.note.list") },
                            title: playlist.name, canPlay: !playlist.tracks.isEmpty,
                            onPlay: { model.play(playlist.tracks) }, onShuffle: { model.play(playlist.tracks, shuffled: true) }) {
                    Text("\(formatSongs(playlist.tracks.count)) · \(formatTotal(Int(playlist.duration)))").foregroundStyle(.secondary)
                }
                DeviceTrackList(tracks: playlist.tracks, leading: .cover)
            }
            .navigationTitle(playlist.name)
        } else {
            ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
        }
    }
}
