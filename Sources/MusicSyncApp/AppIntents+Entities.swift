import AppIntents
import Integration
import Subsonic

/// Library items for Shortcuts and Siri, found by name in the library lists in memory (local mirror or server).
struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumQuery()
    let id: String
    let name: String
    let artist: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(artist ?? "")") }
}

struct AlbumQuery: EntityStringQuery {
    @MainActor private var all: [AlbumEntity] {
        get async throws { try await IntentHost.library().albums.map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artistName) } }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [AlbumEntity] { try await all.filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [AlbumEntity] { NameMatch.rank(try await all, by: \.name, matching: string) }
    @MainActor func suggestedEntities() async throws -> [AlbumEntity] { Array((try await all).prefix(50)) }
}

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistQuery: EntityStringQuery {
    @MainActor private var all: [PlaylistEntity] {
        get async throws { try await IntentHost.library().playlists.map { PlaylistEntity(id: $0.id, name: $0.name) } }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [PlaylistEntity] { try await all.filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [PlaylistEntity] { NameMatch.rank(try await all, by: \.name, matching: string) }
    @MainActor func suggestedEntities() async throws -> [PlaylistEntity] { try await all }
}

struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static let defaultQuery = ArtistQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ArtistQuery: EntityStringQuery {
    @MainActor private var all: [ArtistEntity] {
        get async throws { try await IntentHost.library().artists.map { ArtistEntity(id: $0.id, name: $0.name) } }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [ArtistEntity] { try await all.filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [ArtistEntity] { NameMatch.rank(try await all, by: \.name, matching: string) }
    @MainActor func suggestedEntities() async throws -> [ArtistEntity] { Array((try await all).prefix(50)) }
}

/// A song; its title, artist and album are outputs that other Shortcuts actions can use.
struct SongEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static let defaultQuery = SongQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Artist") var artist: String
    @Property(title: "Album") var album: String

    init(_ song: Song) {
        id = song.id
        title = song.title
        artist = song.artistName ?? ""
        album = song.album ?? ""
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(artist)") }
}

/// Songs are too many to keep in memory, so they come from the search of the Search page.
struct SongQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [SongEntity] {
        guard let client = try await IntentHost.connected().app.client else { return [] }
        var songs: [SongEntity] = []
        for id in identifiers { songs.append(SongEntity(try await client.getSong(id: id))) }
        return songs
    }

    @MainActor func entities(matching string: String) async throws -> [SongEntity] {
        try await IntentHost.find(string)?.song.map(SongEntity.init) ?? []
    }
}

enum RepeatModeEntity: String, AppEnum {
    case off, all, one

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repeat"
    static let caseDisplayRepresentations: [RepeatModeEntity: DisplayRepresentation] = [.off: "Off", .all: "All", .one: "One"]
}
