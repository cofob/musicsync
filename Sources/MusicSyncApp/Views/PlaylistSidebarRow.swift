import Integration
import SwiftUI
import Subsonic

/// Playlist in the sidebar: rename in place, context menu, and a drop target for songs and albums.
struct PlaylistSidebarRow: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let isSelected: Bool
    @State private var draft: String?
    @State private var isTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        let editable = model.canEdit(playlist)
        Label {
            if draft != nil {
                TextField("Name", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { draft = nil }
                    .onChange(of: focused) { if !focused { commit() } }
            } else {
                Text(playlist.name).lineLimit(1).fontWeight(isSelected ? .semibold : nil)
            }
        } icon: {
            CoverImage(id: playlist.coverArt, size: 64, cornerRadius: 3, symbol: "music.note.list").frame(width: 20, height: 20)
        }
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.musicAccent, lineWidth: 2).padding(-4).opacity(isTargeted ? 1 : 0))
        .contextMenu {
            Button("Play", systemImage: "play.fill") { model.play(playlist) }
            PinMenuItem(reason: .playlist(playlist.id)) { model.download(playlist) }
            StationButton(seed: .playlist(playlist))
            SyncMenuItem(isOn: model.sync.isPlaylistSelected(playlist.id)) { model.sync.togglePlaylist(playlist.id) }
            ShareMenuItems(target: ShareTarget(playlist: playlist))
            Divider()
            if editable {
                Button("Rename", systemImage: "pencil") { startRename() }
                Button("Delete Playlist…", systemImage: "trash") { model.playlistPrompt = .delete(playlist) }
            }
            Button("New Playlist…", systemImage: "plus") { model.playlistPrompt = .create(songIds: []) }
        }
        .dropDestination(for: String.self) { items, _ in
            let payloads = items.compactMap(DragPayload.init)
            guard editable, !payloads.isEmpty else { return false }
            Task { model.add(await model.songIds(payloads), to: playlist) }
            return true
        } isTargeted: { isTargeted = $0 && editable }
    }

    private func startRename() {
        draft = playlist.name
        Task { focused = true }
    }

    private func commit() {
        guard let name = draft else { return }
        draft = nil
        model.rename(playlist, to: name, comment: playlist.comment)
    }
}

/// "Playlists" section title with a "+" for a new playlist, as in Apple Music.
struct PlaylistsHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("Playlists")
            Spacer()
            if model.client != nil {
                Button("New Playlist", systemImage: "plus") { model.playlistPrompt = .create(songIds: []) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .help("New Playlist")
            }
        }
    }
}
