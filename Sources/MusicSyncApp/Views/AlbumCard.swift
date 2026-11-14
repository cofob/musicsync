import SwiftUI
import Subsonic

/// Grid cell for an album. `badge` is drawn over the cover's top-right corner
/// (extension point: e.g. a device sync status).
struct AlbumCard<Badge: View>: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @ViewBuilder var badge: Badge

    var body: some View {
        NavigationLink(value: Route.album(album)) {
            VStack(alignment: .leading, spacing: 2) {
                CoverImage(id: album.coverArt, size: 400, cornerRadius: 10)
                    .overlay(alignment: .topTrailing) { badge.padding(6) }
                    .albumHoverActions(album)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .padding(.bottom, 6)
                Text(album.name).lineLimit(2)
                Text(album.artistName ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(DragPayload.album(album.id).text)
        .contextMenu { AlbumMenuItems(album: album) }
    }
}

extension AlbumCard where Badge == SyncBadge {
    init(album: Album) { self.init(album: album) { SyncBadge(album: album) } }
}

/// Album actions for context menus.
struct AlbumMenuItems: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.play(album) }
        Button("Shuffle", systemImage: "shuffle") { model.play(album, shuffled: true) }
        Divider()
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { songs { model.playNext($0) } }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { songs { model.addToQueue($0) } }
        AddToPlaylistMenu { (try? await model.album(album.id))?.song?.map(\.id) ?? [] }
        Divider()
        Button(model.isStarred(album) ? "Undo Favorite" : "Favorite", systemImage: model.isStarred(album) ? "star.slash" : "star") {
            model.toggleStar(album)
        }
        if let artistId = album.artistId {
            Divider()
            Button("Go to Artist", systemImage: "music.microphone") { model.show(.artist(artistId)) }
        }
        SyncMenuItem(isOn: model.sync.isSelected(album), isEnabled: !model.sync.isSelectedByArtist(album)) { model.sync.toggle(album) }
    }

    private func songs(_ action: @escaping ([Song]) -> Void) {
        Task { if let full = try? await model.album(album.id) { action(full.song ?? []) } }
    }
}

let albumGridColumns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 24, alignment: .top)]

/// Adaptive grid of `AlbumCard`s.
struct AlbumGrid<Badge: View>: View {
    let albums: [Album]
    @ViewBuilder var badge: (Album) -> Badge

    var body: some View {
        ScrollView {
            LazyVGrid(columns: albumGridColumns, spacing: 28) {
                ForEach(albums) { album in AlbumCard(album: album) { badge(album) } }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}

extension AlbumGrid where Badge == SyncBadge {
    init(albums: [Album]) { self.init(albums: albums) { SyncBadge(album: $0) } }
}

/// Album grid over a paged list: cards are made as they scroll in, and pages far away are dropped.
struct PagedAlbumGrid: View {
    let list: PagedList<Album>

    var body: some View {
        ScrollView {
            LazyVGrid(columns: albumGridColumns, spacing: 28) {
                ForEach(0..<list.count, id: \.self) { i in
                    PagedRow(list: list, index: i) { album in AlbumCard(album: album) { SyncBadge(album: album) } } placeholder: { PlaceholderCard() }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}
