import SwiftUI
import Subsonic

/// Row of cards that scrolls sideways; it reaches into the page margins so the card shadows are not cut.
struct SideShelf<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 18) { content }.padding(.horizontal, 32).padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -32).padding(.vertical, -20)
    }
}

/// Titled row of album cards that scrolls sideways.
struct AlbumShelf: View {
    let title: String
    let albums: [Album]
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title, action: action)
            SideShelf {
                ForEach(albums) { AlbumCard(album: $0).frame(width: 170) }
            }
        }
    }
}

/// Titled row of round artist images; a click opens the artist.
struct ArtistShelf: View {
    let title: String
    let artists: [Artist]
    /// Line under the name, e.g. the play count.
    var detail: (Artist) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title)
            SideShelf {
                ForEach(artists) { artist in
                    NavigationLink(value: Route.artist(artist.id)) {
                        VStack(spacing: 6) {
                            ArtistPortrait(artist: artist, size: 300).frame(width: 140, height: 140)
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            Text(artist.name).lineLimit(1)
                            if let line = detail(artist) { Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(width: 140).contentShape(Rectangle())
                    }
                    .buttonStyle(CardPressStyle())
                    .contextMenu { ArtistMenuItems(artist: artist) }
                }
            }
        }
    }
}

/// Songs in two columns with small covers, as "Top Songs" on Apple Music artist pages. Double-click plays from the row.
struct TopSongsGrid: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], alignment: .leading, spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                TrackRow(title: song.title, subtitle: [song.album, song.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                         time: song.duration.map(TimeInterval.init), isCurrent: model.player.current?.id == song.id,
                         isStarred: model.isStarred(song)) {
                    CoverImage(id: song.coverArt, size: 100, cornerRadius: 4).frame(width: 40, height: 40)
                } menu: {
                    SongMenuItems(song: song)
                }
                .overlay(alignment: .bottom) { Divider().padding(.leading, 64).padding(.trailing, 10) }
                .onTapGesture(count: 2) { model.player.play(songs, startAt: index) }
            }
        }
        .padding(.horizontal, -10)
    }
}

/// Text cut to three lines with a "More" button that shows all of it; the button is there only when the text is cut.
struct ExpandableText: View {
    let text: String
    @State private var expanded = false
    /// Heights of the text as shown and in full, at the same width.
    @State private var heights = (shown: 0.0, full: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).lineLimit(expanded ? nil : 3).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { heights.shown = $0 }
                .background {
                    Text(text).fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: Double.self) { $0.size.height } action: { heights.full = $0 }
                }
            if expanded || heights.full > heights.shown + 1 {
                Button(expanded ? "Less" : "More") { withAnimation(.smooth) { expanded.toggle() } }
                    .buttonStyle(HitAreaButtonStyle()).font(.callout.weight(.semibold)).foregroundStyle(Color.musicAccent)
            }
        }
    }
}
