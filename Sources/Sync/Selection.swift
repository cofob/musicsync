import Foundation
import Subsonic
import Support

/// What the user wants on one device.
public struct Selection: Codable, Sendable, Equatable {
    public var albums: Set<String> = []
    /// Dynamic: every album of the artist.
    public var artists: Set<String> = []
    /// Albums left out of their artist's selection (deleted from the device).
    public var excludedAlbums: Set<String> = []
    public var playlists: Set<String> = []
    /// Device default preset; nil uses `SyncSettings.presetID`.
    public var presetID: String?
    /// albumID -> presetID (e.g. a Rockbox preset for one album).
    public var albumPresets: [String: String] = [:]
    /// The user's favorite songs, also as a "Favorites" playlist.
    public var favorites = false
    /// Fills the space left with the most played albums, as many as fit.
    public var fillMostPlayed = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albums = try c.decodeIfPresent(Set<String>.self, forKey: .albums) ?? []
        artists = try c.decodeIfPresent(Set<String>.self, forKey: .artists) ?? []
        excludedAlbums = try c.decodeIfPresent(Set<String>.self, forKey: .excludedAlbums) ?? []
        playlists = try c.decodeIfPresent(Set<String>.self, forKey: .playlists) ?? []
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        albumPresets = try c.decodeIfPresent([String: String].self, forKey: .albumPresets) ?? [:]
        favorites = try c.decodeIfPresent(Bool.self, forKey: .favorites) ?? false
        fillMostPlayed = try c.decodeIfPresent(Bool.self, forKey: .fillMostPlayed) ?? false
    }

    public var isEmpty: Bool { albums.isEmpty && artists.isEmpty && playlists.isEmpty && !favorites && !fillMostPlayed }

    public func selects(_ album: Album) -> Bool {
        !excludedAlbums.contains(album.id) && (albums.contains(album.id) || album.artistId.map(artists.contains) == true)
    }

    public func presetID(forAlbum id: String?, default fallback: String) -> String {
        id.flatMap { albumPresets[$0] } ?? presetID ?? fallback
    }
}

/// Persists one `Selection` per device at `<appSupport>/devices/<key>/selection.json`.
public struct SelectionStore: Sendable {
    public var locations: SyncLocations

    public init(locations: SyncLocations = .standard) { self.locations = locations }

    private func url(_ key: String) -> URL { locations.deviceDirectory(key: key).appendingPathComponent("selection.json") }

    public func load(deviceKey: String) -> Selection {
        (try? Data(contentsOf: url(deviceKey))).flatMap { try? JSONDecoder().decode(Selection.self, from: $0) } ?? Selection()
    }

    public func save(_ selection: Selection, deviceKey: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.atomicWrite(try encoder.encode(selection), to: url(deviceKey))
    }
}
