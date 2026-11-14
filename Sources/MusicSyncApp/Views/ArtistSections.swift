import SwiftUI
import Subsonic

/// The sections under the artist header. A nil list is still loading and shows gray rows; an empty one is left out.
struct ArtistSections: View {
    let page: BrowseModel.ArtistPage

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            if let top = page.topSongs {
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader(title: "Top Songs")
                        TopSongsGrid(songs: top)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    PlaceholderBlock(width: 130, height: 22).shimmering()
                    HStack(alignment: .top, spacing: 28) { PlaceholderRows(count: 3, cover: true); PlaceholderRows(count: 3, cover: true) }
                }
            }
            if !page.albums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Albums")
                    LazyVGrid(columns: albumGridColumns, spacing: 28) {
                        ForEach(page.albums) { AlbumCard(album: $0) }
                    }
                }
            }
            if let appears = page.appearsOn, !appears.isEmpty { AlbumShelf(title: "Appears On", albums: appears) }
            if let similar = page.similar, !similar.isEmpty { ArtistShelf(title: "Similar Artists", artists: similar) }
            if let bio = page.biography {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeader(title: "About \(page.artist.name)")
                    ExpandableText(text: bio)
                }
            }
        }
    }
}
