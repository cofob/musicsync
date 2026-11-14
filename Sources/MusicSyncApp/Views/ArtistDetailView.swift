import SwiftUI
import Subsonic

/// Artist page as in Apple Music: portrait and Play / Shuffle, then Top Songs, Albums, Appears On,
/// Similar Artists and the biography. Sections fill in as they load; a page is kept until the server changes.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// False inside the Artists split view, which keeps its own title.
    var setsTitle = true
    @State private var page: BrowseModel.ArtistPage?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let page {
                VStack(alignment: .leading, spacing: 0) {
                    header(page)
                    ArtistSections(page: page).padding(.horizontal, 32).padding(.bottom, 32)
                }
            } else if let loadError {
                LoadFailedView(message: loadError) { Task { await load() } }
            } else {
                ArtistPageSkeleton()
            }
        }
        .navigationTitle(setsTitle ? page?.artist.name ?? "Artist" : "Artists")
        .task(id: id) { await load() }
    }

    private func load() async {
        let browse = model.browse
        if let hit = browse.cached(artist: id) {
            page = hit
            if hit.isComplete { return }
        }
        loadError = nil
        do {
            guard let base = try await browse.artistPage(id), !Task.isCancelled else { return }
            if page == nil { page = base }
            async let appears = browse.appearsOn(id)
            async let top = browse.topSongs(base)
            async let info = browse.info(base.artist)
            var found = base
            found.appearsOn = await appears
            page = found
            found.topSongs = await top
            page = found
            (found.biography, found.imageURL, found.similar) = await info
            found.infoLoaded = true
            guard !Task.isCancelled else { return }
            page = found
            browse.keep(found)
        } catch where !error.isCancellation {
            if page == nil { loadError = error.friendlyMessage }
        } catch {}
    }

    private func header(_ page: BrowseModel.ArtistPage) -> some View {
        let artist = page.artist
        return MediaHeader(cover: { ArtistPortrait(artist: artist, imageURL: page.imageURL) }, title: artist.name, canPlay: !page.albums.isEmpty,
                           onPlay: { play(page, shuffled: false) }, onShuffle: { play(page, shuffled: true) }) {
            Text(summary(page)).font(.callout.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
        } accessory: {
            FavoriteButton(isOn: model.isStarred(artist)) { model.toggleStar(artist) }
            SyncButton(isOn: model.sync.isArtistSelected(artist.id)) { model.sync.toggleArtist(artist.id) }
                .help(model.sync.isArtistSelected(artist.id) ? "Remove all albums by this artist from iPod" : "Sync all albums by this artist")
            RowMenu { ArtistMenuItems(artist: artist) }
        }
    }

    private func summary(_ page: BrowseModel.ArtistPage) -> String {
        let genres = Dictionary(grouping: page.albums.compactMap(\.genre).filter { !$0.isEmpty }) { $0 }
        let genre = genres.max { $0.value.count < $1.value.count }?.key
        let songs = page.albums.reduce(0) { $0 + ($1.songCount ?? 0) }
        let albums = "\(page.albums.count) \(page.albums.count == 1 ? "album" : "albums")"
        return [genre, albums, formatSongs(songs)].compactMap { $0 }.joined(separator: " · ")
    }

    private func play(_ page: BrowseModel.ArtistPage, shuffled: Bool) {
        Task {
            let songs = await model.browse.songs(of: page)
            model.mixes.play(songs, from: .album, shuffled: shuffled)
        }
    }
}

/// Round artist image: the server's artist cover, else the large image from the artist info, else the initials.
struct ArtistPortrait: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    var imageURL: URL?
    /// Requested edge in pixels.
    var size = 600
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Circle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if failed {
                    GeometryReader { geo in
                        Text(initials).font(.system(size: geo.size.width * 0.36, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(Circle())
            .aspectRatio(1, contentMode: .fit)
            .task(id: [artist.coverArt, imageURL?.absoluteString]) {
                if let id = artist.coverArt, let found = await model.covers?.image(id: id, size: size) { image = found; return }
                if let imageURL, let found = await Self.download(imageURL) { image = found; return }
                if !Task.isCancelled { failed = true }
            }
    }

    private var initials: String {
        String(artist.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    /// Fetches and decodes the image off the main thread.
    private static func download(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let image = await Task.detached { CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }.value
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

/// Gray layout of the artist page while it loads.
private struct ArtistPageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .bottom, spacing: 30) {
                Circle().fill(.quaternary).frame(width: 260, height: 260)
                VStack(alignment: .leading, spacing: 12) {
                    PlaceholderBlock(width: 260, height: 30)
                    PlaceholderBlock(width: 180, height: 14)
                    PlaceholderBlock(width: 190, height: 32, cornerRadius: 16).padding(.top, 10)
                }
            }
            PlaceholderBlock(width: 140, height: 22)
            PlaceholderRows(count: 5, cover: true)
        }
        .shimmering()
        .padding(.horizontal, 32).padding(.vertical, 28)
    }
}
