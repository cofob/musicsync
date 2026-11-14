import Foundation
import Library
import Recommend
import Subsonic

/// Data of the artist, genre and stats pages: the local mirror first, the server for what it lacks.
/// Artist pages are kept per artist until the server changes.
@MainActor
final class BrowseModel {
    /// One artist page; nil fields are still loading.
    struct ArtistPage: Sendable {
        var artist: Artist
        /// Newest first.
        var albums: [Album]
        /// Every song of the artist, when the mirror has them.
        var songs: [Song]?
        var topSongs: [Song]?
        var appearsOn: [Album]?
        var similar: [Artist]?
        var biography: String?
        var imageURL: URL?
        var infoLoaded = false

        var isComplete: Bool { topSongs != nil && appearsOn != nil && infoLoaded }
    }

    /// One genre page.
    struct GenrePage {
        /// Newest first.
        var albums: [Album]
        /// Most played first.
        var songs: [Song]
    }

    unowned let app: AppModel
    private var artists: [String: ArtistPage] = [:]
    /// The store the cached pages came from; a new server starts an empty cache.
    private var owner: LibraryStore?

    init(app: AppModel) { self.app = app }

    // MARK: Artist

    func cached(artist id: String) -> ArtistPage? {
        guard owner === app.store else { artists = [:]; owner = app.store; return nil }
        return artists[id]
    }

    func keep(_ page: ArtistPage) {
        if owner !== app.store { artists = [:]; owner = app.store }
        artists[page.artist.id] = page
    }

    /// The artist and its albums: from the mirror when it is complete, else from the server.
    func artistPage(_ id: String) async throws -> ArtistPage? {
        if app.usesLocalLibrary, let db = app.library?.database, let artist = app.artists.first(where: { $0.id == id }) {
            let albums = app.albums.filter { $0.artistId == id }
            if !albums.isEmpty {
                return ArtistPage(artist: artist, albums: Self.newestFirst(albums), songs: await db.songs(artistId: id))
            }
        }
        guard let fetched = try await app.client?.getArtist(id: id) else { return nil }
        return ArtistPage(artist: fetched, albums: Self.newestFirst(fetched.album ?? []))
    }

    /// The server's top songs when it answers within 3 s, filled up to ten with the most played songs here.
    func topSongs(_ page: ArtistPage) async -> [Song] {
        let name = page.artist.name, client = app.client
        let server: [Song] = await firstResult(within: 3) { try await client?.getTopSongs(artist: name, count: 10) ?? [] } ?? []
        let stats = await app.library?.history.stats() ?? [:]
        let local = Browse.topSongs(page.songs ?? [], localPlays: stats.mapValues(\.plays))
        let ids = Set(server.map(\.id))
        return Array((server + local.filter { !ids.contains($0.id) }).prefix(10))
    }

    func appearsOn(_ id: String) async -> [Album] {
        guard app.usesLocalLibrary, let db = app.library?.database else { return [] }
        return await db.appearsOn(artistId: id)
    }

    /// Biography, large image and the similar artists that are in the library. Empty when the server has none.
    func info(_ artist: Artist) async -> (biography: String?, imageURL: URL?, similar: [Artist]) {
        let info = try? await app.client?.getArtistInfo2(id: artist.id)
        let similar = Browse.similarInLibrary(info?.similarArtist ?? [], library: app.artists).filter { $0.id != artist.id }
        return (info?.plainBiography, info?.largeImageUrl.flatMap(URL.init(string:)), similar)
    }

    /// Every song of the artist for Play and Shuffle: the mirror's list, else each album from the server.
    func songs(of page: ArtistPage) async -> [Song] {
        if let songs = page.songs, !songs.isEmpty { return songs }
        var songs: [Song] = []
        for album in page.albums { songs += (try? await app.album(album.id))?.song ?? [] }
        return songs
    }

    private static func newestFirst(_ albums: [Album]) -> [Album] {
        albums.sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }
    }

    // MARK: Genres

    /// Genres of the mirror, else the server's list with covers from the albums in memory.
    func genres() async throws -> [GenreSummary] {
        if app.usesLocalLibrary, let db = app.library?.database { return await db.genres() }
        guard let client = app.client else { return [] }
        let covers = Dictionary(grouping: app.albums.filter { $0.coverArt != nil }) { $0.genre ?? "" }
        return try await client.getGenres()
            .map { GenreSummary(name: $0.value, albumCount: $0.albumCount ?? 0, songCount: $0.songCount ?? 0,
                                covers: (covers[$0.value] ?? []).prefix(4).compactMap(\.coverArt)) }
            .filter { $0.albumCount > 0 }
            .sorted { $0.albumCount == $1.albumCount ? $0.name < $1.name : $0.albumCount > $1.albumCount }
    }

    func genrePage(_ name: String) async throws -> GenrePage {
        if app.usesLocalLibrary, let db = app.library?.database {
            return GenrePage(albums: await db.albums(genre: name), songs: await db.songs(genre: name))
        }
        let albums = Self.newestFirst(app.albums.filter { $0.genre == name })
        let songs = try await app.client?.getSongsByGenre(name, count: 500) ?? []
        return GenrePage(albums: albums, songs: songs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) })
    }
}

/// The result of `work`, or nil when it fails or takes longer than `seconds`.
func firstResult<T: Sendable>(within seconds: Double, _ work: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await work() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
