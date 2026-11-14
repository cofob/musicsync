import Foundation
import Support

public struct LibraryCache: Codable, Sendable {
    public var server: String?
    public var artists: [Artist] = []
    public var albums: [Album] = []
    public var playlists: [Playlist] = []
    public var lastScan: String?
}

/// Library snapshot cached on disk for instant start; refreshed from the server on demand.
public actor LibraryStore {
    public let client: SubsonicClient
    private let directory: URL
    private var cache: LibraryCache
    private var albumCache: [String: Album] = [:]

    private var libraryFile: URL { directory.appendingPathComponent("library.json") }
    private var albumsDir: URL { directory.appendingPathComponent("albums", isDirectory: true) }
    private var serverKey: String { "\(client.username)@\(client.baseURL.absoluteString)" }

    public init(client: SubsonicClient, directory: URL = Paths.appSupport) {
        self.client = client
        self.directory = directory
        cache = LibraryCache()
    }

    /// Cached library from disk (empty if none or if it belongs to another server).
    public func load() -> LibraryCache {
        if let data = try? Data(contentsOf: libraryFile),
           let loaded = try? JSONDecoder().decode(LibraryCache.self, from: data), loaded.server == serverKey {
            cache = loaded
        }
        return cache
    }

    /// Re-reads the server when its last scan changed (or `force`). Playlists are always refreshed.
    public func refresh(force: Bool = false) async throws -> LibraryCache {
        let scan = try? await client.getScanStatus()
        let unchanged = !force && scan?.lastScan != nil && scan?.lastScan == cache.lastScan && !cache.albums.isEmpty
        if !unchanged {
            let artists = try await client.getArtists().flatMap { $0.artist ?? [] }
            var albums: [Album] = []
            while true {
                let page = try await client.getAlbumList2(type: "alphabeticalByName", size: 500, offset: albums.count)
                albums += page
                if page.count < 500 { break }
            }
            cache.artists = artists
            cache.albums = albums
            cache.lastScan = scan?.lastScan
            albumCache = [:]
            try? FileManager.default.removeItem(at: albumsDir)
        }
        cache.playlists = try await client.getPlaylists()
        cache.server = serverKey
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.atomicWrite(JSONEncoder().encode(cache), to: libraryFile)
        return cache
    }

    /// Album with its songs: memory, then disk, then server.
    public func album(_ id: String) async throws -> Album {
        if let album = albumCache[id] { return album }
        let file = albumsDir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
        if let data = try? Data(contentsOf: file), let album = try? JSONDecoder().decode(Album.self, from: data) {
            albumCache[id] = album
            return album
        }
        let album = try await client.getAlbum(id: id)
        albumCache[id] = album
        try? FileManager.default.createDirectory(at: albumsDir, withIntermediateDirectories: true)
        try? FileManager.default.atomicWrite(JSONEncoder().encode(album), to: file)
        return album
    }

    /// Playlist with entries, always fresh.
    public func playlist(_ id: String) async throws -> Playlist {
        try await client.getPlaylist(id: id)
    }
}
