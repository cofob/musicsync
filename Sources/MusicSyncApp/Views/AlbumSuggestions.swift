import SwiftUI
import Subsonic

/// "More by <artist>" and "You Might Also Like" (same genre or decade) under an album's track list.
struct AlbumSuggestions: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var similar: [Album] = []

    var body: some View {
        let more = model.albums.filter { $0.artistId != nil && $0.artistId == album.artistId && $0.id != album.id }
            .sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }
        VStack(alignment: .leading, spacing: 30) {
            if !more.isEmpty, let artist = album.artistName {
                AlbumShelf(title: "More by \(artist)", albums: Array(more.prefix(20)),
                           action: album.artistId.map { id in { model.show(.artist(id)) } })
            }
            if !similar.isEmpty { AlbumShelf(title: "You Might Also Like", albums: similar) }
        }
        .task(id: album.id) { similar = await load() }
    }

    /// Mirror query when the library is local, else the albums in memory with the same genre.
    private func load() async -> [Album] {
        if model.usesLocalLibrary, let db = model.library?.database { return await db.similarAlbums(to: album) }
        guard let genre = album.genre, !genre.isEmpty else { return [] }
        return Array(model.albums.filter { $0.genre == genre && $0.artistId != album.artistId }
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(20))
    }
}
