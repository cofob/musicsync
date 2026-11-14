import AppIntents
import Integration
import Recommend
import Subsonic

/// Shortcuts and Siri actions. `scripts/bundle.sh` writes their metadata (`Metadata.appintents`) into the app,
/// as Xcode would. They run without a window and use the same models as the app and the `musicsync://` links.
@MainActor enum IntentHost {
    /// Set at launch.
    static weak var system: SystemServices?

    static func open(_ link: DeepLink) { system?.open(link) }

    /// The services once a server is connected; a launch made for the intent gets a few seconds to read the settings.
    static func connected() async throws -> SystemServices {
        for _ in 0..<50 where system?.app.client == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let system, system.app.client != nil else { throw IntentError.notConnected }
        return system
    }

    /// The app once its library lists are loaded.
    static func library() async throws -> AppModel {
        let app = try await connected().app
        for _ in 0..<100 where app.libraryVersion == 0 { try await Task.sleep(for: .milliseconds(100)) }
        return app
    }

    /// The results of the Search page (local mirror, else the server).
    static func find(_ text: String) async throws -> SearchResult3? {
        // A debounce, even zero, keeps a failure off the Search page.
        try await connected().app.search.lookup(text, limit: 20, debounce: .zero)
    }

    /// Plays the loaded songs, unless the server changed meanwhile.
    static func play(from source: PlaySource = .other, shuffled: Bool? = nil, _ load: (SystemServices) async throws -> [Song]) async throws {
        let system = try await connected(), store = system.app.store
        let songs = try await load(system)
        guard store === system.app.store else { throw CancellationError() }
        guard !songs.isEmpty else { throw IntentError.noSongs }
        system.app.mixes.play(songs, from: source, shuffled: shuffled)
    }

    static func currentSong() throws -> Song {
        guard let song = system?.currentSong else { throw IntentError.nothingPlaying }
        return song
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConnected, nothingPlaying, notFound(String), noSongs, readOnly(String), needsLibrary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "MusicSync is not connected to a server. Open MusicSync and sign in first."
        case .nothingPlaying: "Nothing is playing in MusicSync."
        case .notFound(let text): "MusicSync found nothing for “\(text)”."
        case .noSongs: "There are no songs to play."
        case .readOnly(let name): "You cannot add songs to the playlist “\(name)”."
        case .needsLibrary: "Stations need the library on this Mac. Turn it on in MusicSync Settings > Library."
        }
    }
}

// MARK: Playback

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

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Volume"
    @Parameter(title: "Volume", inclusiveRange: (0, 100)) var level: Int

    @MainActor func perform() async throws -> some IntentResult {
        IntentHost.system?.app.player.volume = Double(min(max(level, 0), 100)) / 100
        return .result()
    }
}

struct ToggleShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Shuffle On or Off"

    @MainActor func perform() async throws -> some IntentResult {
        if let player = IntentHost.system?.app.player { player.setShuffle(!player.shuffle) }
        return .result()
    }
}

struct SetRepeatIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Repeat"
    @Parameter(title: "Repeat") var mode: RepeatModeEntity

    @MainActor func perform() async throws -> some IntentResult {
        if let mode = RepeatMode(rawValue: mode.rawValue) { IntentHost.system?.app.player.repeatMode = mode }
        return .result()
    }
}

struct GetCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Song"
    static let description = IntentDescription("Gives the title, artist and album of the song that plays in MusicSync.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SongEntity> {
        .result(value: SongEntity(try IntentHost.currentSong()))
    }
}

// MARK: Library

struct PlayAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Album"
    @Parameter(title: "Album") var album: AlbumEntity
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await IntentHost.play(from: .album, shuffled: shuffle) { [id = album.id] in try await $0.songs(.album, id: id) }
        return .result()
    }
}

struct PlayArtistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Artist"
    @Parameter(title: "Artist") var artist: ArtistEntity
    @Parameter(title: "Shuffle", default: true) var shuffle: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await IntentHost.play(shuffled: shuffle) { [id = artist.id] in try await $0.songs(.artist, id: id) }
        return .result()
    }
}

struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    @Parameter(title: "Playlist") var playlist: PlaylistEntity
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await IntentHost.play(from: .playlist, shuffled: shuffle) { [id = playlist.id] in try await $0.songs(.playlist, id: id) }
        return .result()
    }
}

/// "Play <text>": the best match of the search, as the first item of the search suggestions.
struct PlayMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays the artist, album or song that best matches the text.")
    @Parameter(title: "Text", requestValueDialog: "What do you want to hear?") var text: String

    @MainActor func perform() async throws -> some IntentResult {
        guard let found = try await IntentHost.find(text), let best = SearchModel.topItems(found, count: 1).first else { throw IntentError.notFound(text) }
        switch best {
        case .artist(let artist): try await IntentHost.play(shuffled: true) { try await $0.songs(.artist, id: artist.id) }
        case .album(let album): try await IntentHost.play(from: .album) { try await $0.songs(.album, id: album.id) }
        case .song(let song): try await IntentHost.play { _ in [song] }
        default: throw IntentError.notFound(text)
        }
        return .result()
    }
}

struct ShuffleLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Plays the songs of 20 random albums in random order.")

    @MainActor func perform() async throws -> some IntentResult {
        let albums = try await IntentHost.library().albums.shuffled().prefix(20)
        try await IntentHost.play(shuffled: true) { system in
            var songs: [Song] = []
            for album in albums { songs += try await system.app.album(album.id)?.song ?? [] }
            return songs
        }
        return .result()
    }
}

struct StartStationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Station from Current Song"
    static let description = IntentDescription("Plays songs that are like the current song.")

    @MainActor func perform() async throws -> some IntentResult {
        let mixes = try await IntentHost.connected().app.mixes
        guard mixes.isAvailable else { throw IntentError.needsLibrary }
        mixes.startStation(.song(try IntentHost.currentSong()))
        return .result()
    }
}

struct SetAutoPlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Set AutoPlay"
    static let description = IntentDescription("When the queue ends, AutoPlay goes on with similar songs.")
    @Parameter(title: "AutoPlay") var on: Bool

    @MainActor func perform() async throws -> some IntentResult { IntentHost.system?.app.mixes.autoPlay = on; return .result() }
}

struct FavoriteCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Current Song to Favorites"

    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentHost.currentSong()
        IntentHost.open(.command(.favorite))
        return .result()
    }
}

struct AddCurrentSongToPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Current Song to Playlist"
    @Parameter(title: "Playlist") var playlist: PlaylistEntity

    @MainActor func perform() async throws -> some IntentResult {
        let app = try await IntentHost.connected().app, song = try IntentHost.currentSong()
        guard let list = app.playlists.first(where: { $0.id == playlist.id }), app.canEdit(list) else { throw IntentError.readOnly(playlist.name) }
        await app.append([song.id], to: list)
        return .result()
    }
}

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Library"
    static let openAppWhenRun = true
    @Parameter(title: "Text") var text: String

    @MainActor func perform() async throws -> some IntentResult { IntentHost.open(.search(text)); return .result() }
}

/// Ready in Spotlight and Siri without setup (at most 10).
struct MusicSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Play or pause \(.applicationName)"], shortTitle: "Play or Pause", systemImageName: "playpause")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Next song in \(.applicationName)", "Skip this song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward")
        AppShortcut(intent: PlayMusicIntent(), phrases: ["Play music in \(.applicationName)", "Play something in \(.applicationName)"],
                    shortTitle: "Play Music", systemImageName: "play")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: ["Shuffle my library in \(.applicationName)", "Shuffle all songs in \(.applicationName)"],
                    shortTitle: "Shuffle Library", systemImageName: "shuffle")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["Play \(\.$playlist) in \(.applicationName)", "Play a playlist in \(.applicationName)"],
                    shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: PlayAlbumIntent(), phrases: ["Play an album in \(.applicationName)"], shortTitle: "Play Album", systemImageName: "square.stack")
        AppShortcut(intent: PlayArtistIntent(), phrases: ["Play an artist in \(.applicationName)"], shortTitle: "Play Artist", systemImageName: "music.mic")
        AppShortcut(intent: StartStationIntent(), phrases: ["Start a station in \(.applicationName)", "Play more like this in \(.applicationName)"],
                    shortTitle: "Start Station", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: FavoriteCurrentSongIntent(), phrases: ["Favorite this song in \(.applicationName)", "I love this song in \(.applicationName)"],
                    shortTitle: "Favorite Song", systemImageName: "star")
        AppShortcut(intent: GetCurrentSongIntent(), phrases: ["What is playing in \(.applicationName)", "What song is this in \(.applicationName)"],
                    shortTitle: "Current Song", systemImageName: "music.note")
    }
}
