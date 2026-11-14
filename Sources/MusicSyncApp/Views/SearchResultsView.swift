import Library
import SwiftUI
import Subsonic

/// Search page: Browse genres (empty query), or the results of the committed query (Apple Music layout).
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        Group {
            if search.query.isEmpty {
                if search.scope == .ipod { SearchPlaceholder(title: "Searching Your iPod") } else { BrowseGenresView() }
            } else if search.scope == .ipod {
                DeviceSearchResults(result: search.deviceResult, query: search.query)
            } else if let error = search.error {
                LoadFailedView(message: error) { search.reload() }
            } else if let result = search.result {
                if result.artist.isEmpty && result.album.isEmpty && result.song.isEmpty {
                    ContentUnavailableView.search(text: search.query)
                } else {
                    LibrarySearchResults(result: result)
                }
            } else {
                LibrarySearchSkeleton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search")
    }
}

/// Big gray magnifier and a title, like "Searching Your Library".
private struct SearchPlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 64, weight: .regular))
            Text(title).font(.system(size: 30, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .padding(.bottom, 60)
    }
}

// MARK: Browse

/// Genre tiles built from the library albums; a tile opens the albums of its genre.
private struct BrowseGenresView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [Genre] = []

    struct Genre: Identifiable {
        let name: String
        let cover: String?
        var id: String { name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Browse Categories").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 18)], spacing: 20) {
                    if genres.isEmpty && model.albums.isEmpty {
                        ForEach(0..<12, id: \.self) { _ in PlaceholderBlock(height: 120, cornerRadius: 12) }.shimmering()
                    }
                    ForEach(genres) { genre in
                        NavigationLink(value: Route.genre(genre.name)) { GenreTile(genre: genre) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .overlay {
            if genres.isEmpty && !model.albums.isEmpty {
                SearchPlaceholder(title: "Searching Your Library")
            }
        }
        .onChange(of: model.libraryVersion, initial: true) { genres = Self.genres(model.albums) }
    }

    /// Genres with the most albums first, spellings merged; the cover of the most played album represents a genre.
    static func genres(_ albums: [Album]) -> [Genre] {
        let rows = albums.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.map { (genre: $0.genre ?? "", cover: $0.coverArt, count: 1) }
        return GenreSummary.grouped(albums: rows, songs: []).prefix(32).map { Genre(name: $0.name, cover: $0.covers.first) }
    }
}

/// Colored tile: a cover tinted with a color picked from the genre name, title at the bottom left.
private struct GenreTile: View {
    let genre: BrowseGenresView.Genre

    var body: some View {
        Color.genre(genre.name)
            .overlay(alignment: .trailing) {
                CoverImage(id: genre.cover, size: 300, cornerRadius: 0)
                    .saturation(0).blendMode(.multiply).opacity(0.9)
                    .aspectRatio(1, contentMode: .fit)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
            }
            .overlay(alignment: .bottomLeading) {
                Text(genre.name).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.25), radius: 4).padding(14)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: Library results

private let topColumns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 3)

private struct LibrarySearchResults: View {
    @Environment(AppModel.self) private var model
    let result: SearchResult3

    var body: some View {
        let top = SearchModel.topItems(result, count: 6)
        let topSongs = Set(top.compactMap { if case .song(let s) = $0 { s.id } else { nil } })
        let songs = result.song.filter { !topSongs.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Top Results")
                    LazyVGrid(columns: topColumns, spacing: 14) {
                        ForEach(top) { TopResultCard(item: $0) }
                    }
                }
                if !result.artist.isEmpty { ArtistsRow(artists: result.artist) }
                if !result.album.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ShelfHeader(title: "Albums")
                        HorizontalShelf {
                            ForEach(result.album) { AlbumCard(album: $0).frame(width: 170) }
                        }
                    }
                }
                if !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader(title: "Songs")
                        SongList(songs: songs, leading: .cover) { model.player.play(songs, startAt: $0) }
                            .padding(.horizontal, -10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}

/// Gray card: artwork, title, "Kind · Artist"; a chevron for artists and albums, a "•••" menu for songs.
private struct TopResultCard: View {
    @Environment(AppModel.self) private var model
    let item: SearchModel.Item

    var body: some View {
        HStack(spacing: 10) {
            SearchItemArtwork(item: item).frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if case .song(let song) = item {
                RowMenu(tint: .primary) { SongMenuItems(song: song) }
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.search.open(item) }
        .contextMenu { if case .song(let song) = item { SongMenuItems(song: song) } }
    }
}

/// Round artist images in a row with a paging arrow.
private struct ArtistsRow: View {
    let artists: [Artist]
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Artists")
            GeometryReader { geo in
                let perPage = max(1, Int((geo.size.width + 18) / 168))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(artists) { artist in
                                NavigationLink(value: Route.artist(artist.id)) {
                                    VStack(spacing: 8) {
                                        ArtistImage(artist: artist).frame(width: 150, height: 150)
                                        Text(artist.name).lineLimit(1)
                                    }
                                    .frame(width: 150).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(artist.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .overlay(alignment: .trailing) {
                        if artists.count > perPage {
                            HStack {
                                if page > 0 { pager("chevron.left") { go(-perPage, perPage, proxy) } }
                                Spacer()
                                if (page + 1) * perPage < artists.count { pager("chevron.right") { go(perPage, perPage, proxy) } }
                            }
                            .padding(.bottom, 26)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private func pager(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2.weight(.semibold))
        }
        .buttonStyle(HitAreaButtonStyle(width: 36, height: 60))
        .glass(in: Capsule(), interactive: true)
    }

    private func go(_ delta: Int, _ perPage: Int, _ proxy: ScrollViewProxy) {
        let first = max(0, min(page * perPage + delta, artists.count - 1))
        page = first / perPage
        withAnimation(.smooth) { proxy.scrollTo(artists[first].id, anchor: .leading) }
    }
}

/// Horizontal row that lets card shadows overflow the page margins.
private struct HorizontalShelf<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 18) { content }.padding(.horizontal, 32).padding(.vertical, 16)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -32).padding(.vertical, -16)
    }
}

/// Final layout in gray while results load, so nothing jumps when they arrive.
private struct LibrarySearchSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    PlaceholderBlock(width: 140, height: 22)
                    LazyVGrid(columns: topColumns, spacing: 14) {
                        ForEach(0..<6, id: \.self) { _ in PlaceholderBlock(height: 72, cornerRadius: 12) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    PlaceholderBlock(width: 90, height: 22)
                    HStack(spacing: 18) {
                        ForEach(0..<5, id: \.self) { _ in PlaceholderBlock(width: 150, height: 150, cornerRadius: 75) }
                    }
                    .frame(height: 180, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 24)
            .shimmering()
        }
        .disabled(true)
    }
}

// MARK: iPod results

private struct DeviceSearchResults: View {
    @Environment(AppModel.self) private var model
    let result: SearchModel.DeviceResult
    let query: String

    var body: some View {
        if result.albums.isEmpty && result.tracks.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !result.albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: "Albums")
                            HorizontalShelf {
                                ForEach(result.albums) { album in
                                    DeviceCard(route: .deviceAlbum(album.id), imageID: album.imageID, title: album.name,
                                               subtitle: album.artist) { model.play(album.tracks) }
                                        .frame(width: 170)
                                }
                            }
                        }
                    }
                    if !result.tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ShelfHeader(title: "Songs")
                            LazyVStack(spacing: 0) {
                                ForEach(Array(result.tracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(title: track.title, subtitle: [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "),
                                             time: track.duration) {
                                        DeviceCoverImage(imageID: track.imageID, cornerRadius: 4).frame(width: 40, height: 40)
                                    } menu: {
                                        Button("Play", systemImage: "play.fill") { model.play(result.tracks, startAt: index) }
                                    }
                                    .onTapGesture(count: 2) { model.play(result.tracks, startAt: index) }
                                }
                            }
                            .padding(.horizontal, -10)
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
            }
        }
    }
}
