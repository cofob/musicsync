import Library
import SwiftUI
import Subsonic

/// One genre: Play / Shuffle of all its songs, its most played songs and its albums, newest first.
struct GenreDetailView: View {
    @Environment(AppModel.self) private var model
    let genre: String
    @State private var page: BrowseModel.GenrePage?
    @State private var loadError: String?

    var body: some View {
        let songs = page?.songs ?? []
        ScrollView {
            MediaHeader(cover: { cover }, title: genre, canPlay: !songs.isEmpty,
                        onPlay: { model.mixes.play(songs, from: .other, shuffled: false) },
                        onShuffle: { model.mixes.play(songs, from: .other, shuffled: true) }) {
                Text(page.map { genreCounts(GenreSummary(name: genre, albumCount: $0.albums.count, songCount: $0.songs.count)) } ?? " ")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            Group {
                if let loadError {
                    LoadFailedView(message: loadError) { Task { await load() } }
                } else if let page {
                    sections(page)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        PlaceholderBlock(width: 130, height: 22).shimmering()
                        PlaceholderRows(count: 5, cover: true)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 32)
        }
        .navigationTitle(genre)
        .task(id: genre) { await load() }
    }

    private var cover: some View {
        Color.genre(genre)
            .overlay(alignment: .bottomTrailing) {
                GenreCollage(covers: page?.albums.compactMap(\.coverArt) ?? []).frame(width: 190).offset(x: 24, y: 30)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func sections(_ page: BrowseModel.GenrePage) -> some View {
        if page.albums.isEmpty && page.songs.isEmpty {
            ContentUnavailableView("No Albums", systemImage: "square.stack", description: Text("Nothing in the library has this genre."))
        }
        VStack(alignment: .leading, spacing: 34) {
            let top = Array(page.songs.prefix(10))
            if !top.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeader(title: "Top Songs")
                    TopSongsGrid(songs: top)
                }
            }
            if !page.albums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Albums")
                    LazyVGrid(columns: albumGridColumns, spacing: 28) { ForEach(page.albums) { AlbumCard(album: $0) } }
                }
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let found = try await model.browse.genrePage(genre)
            if !Task.isCancelled { page = found }
        } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }
}
