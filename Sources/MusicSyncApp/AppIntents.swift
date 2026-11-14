import AppIntents
import Integration
import Subsonic

/// Shortcuts and Siri actions. `scripts/bundle.sh` writes their metadata (`Metadata.appintents`) into the app,
/// as Xcode would. Each action goes through the same handler as `musicsync://` links.
@MainActor enum IntentHost {
    /// Set at launch.
    static weak var system: SystemServices?

    static func open(_ link: DeepLink) { system?.open(link) }
}

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the current song in MusicSync.")

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.command(.toggle)); return .result() }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Song"

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.command(.next)); return .result() }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Song"

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.command(.previous)); return .result() }
}

struct FavoriteCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Current Song to Favorites"

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.command(.favorite)); return .result() }
}

struct PlayAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Album"
    @Parameter(title: "Album") var album: AlbumEntity

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.play(.album, id: album.id)); return .result() }
}

struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    @Parameter(title: "Playlist") var playlist: PlaylistEntity

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.play(.playlist, id: playlist.id)); return .result() }
}

struct PlayArtistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Artist"
    @Parameter(title: "Artist") var artist: ArtistEntity

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.play(.artist, id: artist.id)); return .result() }
}

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Library"
    static let openAppWhenRun = true
    @Parameter(title: "Text") var text: String

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.search(text)); return .result() }
}

struct MusicSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Play or pause \(.applicationName)"], shortTitle: "Play or Pause", systemImageName: "playpause")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Next song in \(.applicationName)"], shortTitle: "Next Song", systemImageName: "forward")
        AppShortcut(intent: FavoriteCurrentSongIntent(), phrases: ["Favorite this song in \(.applicationName)"],
                    shortTitle: "Favorite Song", systemImageName: "star")
        AppShortcut(intent: PlayAlbumIntent(), phrases: ["Play an album in \(.applicationName)"], shortTitle: "Play Album", systemImageName: "square.stack")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["Play a playlist in \(.applicationName)"],
                    shortTitle: "Play Playlist", systemImageName: "music.note.list")
    }
}

// MARK: Entities: found by name in the library lists in memory.

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
        IntentHost.system?.app.albums.map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artistName) } ?? []
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [AlbumEntity] { all.filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [AlbumEntity] { all.filter { $0.name.localizedStandardContains(string) } }
    @MainActor func suggestedEntities() async throws -> [AlbumEntity] { Array(all.prefix(50)) }
}

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistQuery: EntityStringQuery {
    @MainActor private var all: [PlaylistEntity] { IntentHost.system?.app.playlists.map { PlaylistEntity(id: $0.id, name: $0.name) } ?? [] }

    @MainActor func entities(for identifiers: [String]) async throws -> [PlaylistEntity] { all.filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [PlaylistEntity] { all.filter { $0.name.localizedStandardContains(string) } }
    @MainActor func suggestedEntities() async throws -> [PlaylistEntity] { all }
}

struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static let defaultQuery = ArtistQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ArtistQuery: EntityStringQuery {
    @MainActor private var all: [ArtistEntity] { IntentHost.system?.app.artists.map { ArtistEntity(id: $0.id, name: $0.name) } ?? [] }

    @MainActor func entities(for identifiers: [String]) async throws -> [ArtistEntity] { all.filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [ArtistEntity] { all.filter { $0.name.localizedStandardContains(string) } }
    @MainActor func suggestedEntities() async throws -> [ArtistEntity] { Array(all.prefix(50)) }
}
