import Library
import SwiftUI
import Subsonic

/// A smart playlist in the sidebar: its cover with a gear badge and the smart playlist menu. Not a drop target:
/// the rules choose its songs.
struct SmartPlaylistSidebarRow: View {
    let playlist: Playlist
    let isSelected: Bool

    var body: some View {
        Label {
            Text(playlist.name).lineLimit(1).fontWeight(isSelected ? .semibold : nil)
        } icon: {
            SmartPlaylistCover(playlist: playlist, size: 64, cornerRadius: 3).frame(width: 20, height: 20)
        }
        .contextMenu { SmartPlaylistMenuItems(playlist: playlist) }
    }
}

/// The cover of the first song, or the gear symbol; a small gear badge marks it as smart.
struct SmartPlaylistCover: View {
    let playlist: Playlist
    var size = 600
    var cornerRadius: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            Group {
                if playlist.coverArt == nil {
                    SmartPlaylistIcon(size: side)
                } else {
                    CoverImage(id: playlist.coverArt, size: size, cornerRadius: cornerRadius, symbol: "gearshape")
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: max(7, min(side * 0.16, 20)), weight: .semibold)).foregroundStyle(.white)
                                .padding(max(1.5, side * 0.03))
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(max(1, side * 0.04))
                        }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Play, download, iPod and edit actions of a smart playlist (sidebar, grid).
struct SmartPlaylistMenuItems: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        let smart = model.smartPlaylists
        Button("Play", systemImage: "play.fill") { model.play(playlist) }
        Button("Shuffle", systemImage: "shuffle") { model.play(playlist, shuffled: true) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            Task { model.playNext(await smart.full(playlist.id)?.entry ?? []) }
        }
        PinMenuItem(reason: .playlist(playlist.id)) { model.download(playlist) }
        SyncMenuItem(isOn: model.sync.isPlaylistSelected(playlist.id)) { model.sync.togglePlaylist(playlist.id) }
        Divider()
        SmartPlaylistEditItems(id: playlist.id)
        Divider()
        Button("New Smart Playlist…", systemImage: "gearshape") { smart.create() }
    }
}

/// Edit, Duplicate and Delete.
struct SmartPlaylistEditItems: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let smart = model.smartPlaylists
        Button("Edit Smart Playlist…", systemImage: "slider.horizontal.3") { smart.edit(id) }
        Button("Duplicate", systemImage: "plus.square.on.square") { smart.duplicate(id) }
        Button("Delete Smart Playlist…", systemImage: "trash") { smart.deleting = smart.definition(id) }
    }
}

/// "Edit Rules" and "•••" on a smart playlist page.
struct SmartPlaylistHeaderButtons: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        Button("Edit Rules", systemImage: "slider.horizontal.3") { model.smartPlaylists.edit(id) }
            .buttonStyle(CircleIconStyle(size: 34))
            .help("Edit Rules")
        Menu {
            SmartPlaylistEditItems(id: id)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.musicAccent)
                .frame(width: 32, height: 32).background(Color.primary.opacity(0.07), in: Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More")
    }
}

/// The editor sheet and the delete confirmation. Attached once, to the root view.
struct SmartPlaylistDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var smart = model.smartPlaylists
        content
            .sheet(item: $smart.editing) { draft in
                SmartPlaylistEditor(draft: draft, isNew: smart.definition(draft.id) == nil)
            }
            .confirmationDialog("Delete “\(smart.deleting?.name ?? "")”?", isPresented: Binding(get: { smart.deleting != nil }, set: { if !$0 { smart.deleting = nil } })) {
                if let playlist = smart.deleting {
                    Button("Delete", role: .destructive) { smart.delete(playlist) }
                }
            } message: {
                Text("The smart playlist is deleted from this Mac. The songs stay in your library.")
            }
    }
}
