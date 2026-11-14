import AppKit
import Library
import Observation
import Subsonic
import Sync

/// Navigation targets pushed on the detail stack.
enum Route: Hashable {
    case album(Album)
    case artist(String)
    case playlist(Playlist)
    case deviceAlbum(String)
    case devicePlaylist(Int)
    case genre(String)
}

@MainActor @Observable
final class AppModel {
    private static let configKey = "serverConfig"
    private static let mirrorKey = "libraryMirrorSettings"

    private(set) var config: ServerConfig?
    /// Nil until a server is configured and its password is in the Keychain.
    private(set) var client: SubsonicClient?
    private(set) var store: LibraryStore?
    private(set) var covers: CoverArtCache?
    /// Local mirror of the server library; nil without a server.
    var library: Library?
    /// Latest mirror progress, for the sidebar and Settings.
    var mirrorStatus = MirrorStatus()
    /// End of the last complete listing (survives restarts, unlike `mirrorStatus.lastSuccess`).
    var lastLibrarySync: Date?
    /// True when lists come from the local database instead of the network.
    var usesLocalLibrary = false
    /// Settings > Library; saved on every change (not in demo mode).
    var mirrorSettings = MirrorSettings() {
        didSet {
            guard mirrorSettings != oldValue else { return }
            if !demo { UserDefaults.standard.set(try? JSONEncoder().encode(mirrorSettings), forKey: Self.mirrorKey) }
            let settings = mirrorSettings
            Task { await library?.mirror.update(settings: settings) }
        }
    }
    @ObservationIgnored var statusTask: Task<Void, Never>?

    private(set) var artists: [Artist] = []
    private(set) var albums: [Album] = []
    private(set) var playlists: [Playlist] = []
    /// Bumped on every library update; cheap change signal for sorted/grouped copies.
    private(set) var libraryVersion = 0
    private(set) var isLoading = false
    /// Alert for failed user actions; set through `report(_:)`.
    var errorMessage: String?
    /// Inline messages for failed background loads (library, Home, songs, search).
    private(set) var libraryError: String?
    private(set) var songsError: String?

    var selection: SidebarItem? = .home
    var path: [Route] = []
    var searchText = ""
    /// Bumped by Edit > Find; the toolbar search field takes focus.
    var searchFocusRequest = 0
    /// Set by the toolbar search field.
    var searchFieldFocused = false
    @ObservationIgnored private(set) lazy var search = SearchModel(app: self)
    var showNowPlaying = false
    var nowPlayingPanel = NowPlayingPanel.lyrics
    /// Song shown in the "Get Info" sheet.
    var infoSong: Song?
    /// Song id -> lyrics (nil = none) seen this session.
    @ObservationIgnored var lyricsCache: [String: Lyrics?] = [:]
    /// Getting-started guide; opens by itself on the first launch.
    var showGuide = false

    /// Home shelves, loaded by `loadHome()`.
    private(set) var shelves: [Shelf] = []
    /// Every song of the library, loaded page by page by `loadSongs()`.
    private(set) var songs: [Song] = []
    private(set) var songsLoaded = false
    @ObservationIgnored private var songsVersion = -1
    /// Star state changed in this session, by song id.
    private var starOverrides: [String: Bool] = [:]

    let player = Player()
    /// The connected iPod (read-only snapshot, eject). Sync UI hooks live here.
    let ipod = DeviceModel()
    let sync = SyncModel()
    /// Sync options (Settings > Sync); saved on every change.
    var syncSettings = SyncSettings.load() {
        didSet {
            syncSettings.save()
            if syncSettings.fullAlbums != oldValue.fullAlbums { sync.schedulePlan() }
        }
    }
    @ObservationIgnored private var spaceMonitor: Any?

    /// Development only: `MUSICSYNC_DEMO=1` uses the public Navidrome demo and stores nothing in the Keychain or defaults.
    @ObservationIgnored let demo = ProcessInfo.processInfo.environment["MUSICSYNC_DEMO"] == "1"
    /// Demo mode keeps the library and its covers here and removes nothing else.
    @ObservationIgnored private lazy var demoDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-demo")

    init() {
        if demo {
            config = ServerConfig(baseURL: URL(string: "https://demo.navidrome.org")!, username: "demo")
        } else if let data = UserDefaults.standard.data(forKey: Self.configKey) {
            config = try? JSONDecoder().decode(ServerConfig.self, from: data)
        }
        if !demo, let data = UserDefaults.standard.data(forKey: Self.mirrorKey),
           let saved = try? JSONDecoder().decode(MirrorSettings.self, from: data) {
            mirrorSettings = saved
        }
        ipod.manualGuid = { [weak self] device in device.volumeUUID.flatMap { self?.syncSettings.manualGuids[$0] } }
        sync.attach(self)
        ipod.start()
        spaceMonitor = SpaceKeyMonitor.install { [weak self] in
            guard let player = self?.player, !player.queue.isEmpty else { return false }
            player.toggle()
            return true
        }
        Task { await connect() }
    }

    // MARK: Server

    /// Saves the server. An empty `password` keeps the stored one.
    func save(_ config: ServerConfig, password: String) async {
        if !password.isEmpty { config.setPassword(password) }
        self.config = config
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: Self.configKey)
        await connect()
    }

    private func connect() async {
        path = []
        shelves = []; songs = []; songsLoaded = false; songsVersion = -1; starOverrides = [:]
        await stopLibrary()
        let client = demo ? config.map { SubsonicClient(baseURL: $0.baseURL, username: $0.username, password: "demo") }
                          : config.flatMap { SubsonicClient(config: $0) }
        guard let client else {
            self.client = nil; store = nil; covers = nil
            player.client = nil; player.covers = nil
            apply(artists: [], albums: [], playlists: [])
            return
        }
        let store = demo ? LibraryStore(client: client, directory: demoDirectory) : LibraryStore(client: client)
        let covers = CoverArtCache(client: client)
        self.client = client; self.store = store; self.covers = covers
        player.client = client; player.covers = covers
        sync.flushScrobbles(client)
        let library = makeLibrary(client.config)
        startLibrary(library, client: client)
        if await reloadFromDatabase(library) { return }
        let cache = await store.load()
        apply(artists: cache.artists, albums: cache.albums, playlists: cache.playlists)
        await refresh()
    }

    /// Reads lists from the local database when it is complete, else from the server (`LibraryStore`).
    func refresh(force: Bool = false) async {
        if !force, let library, await reloadFromDatabase(library) { return }
        guard let store, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let cache = try await store.refresh(force: force)
            if store === self.store, !usesLocalLibrary { apply(artists: cache.artists, albums: cache.albums, playlists: cache.playlists) }
            libraryError = nil
        } catch where !error.isCancellation {
            if force { report(error) } else { libraryError = error.localizedDescription }
        } catch {}
    }

    /// Shows `error` in the alert unless it is a cancelled request (navigation, debounce).
    func report(_ error: Error) {
        if !error.isCancellation { errorMessage = error.localizedDescription }
    }

    /// Replaces the lists. `onlyIfChanged` keeps views (and their scroll state) when nothing changed.
    func apply(artists: [Artist], albums: [Album], playlists: [Playlist], onlyIfChanged: Bool = false) {
        if onlyIfChanged, artists == self.artists, albums == self.albums, playlists == self.playlists { return }
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
        libraryVersion += 1
        sync.libraryChanged()
    }

    // MARK: Actions

    func show(_ route: Route) {
        showNowPlaying = false
        path.append(route)
    }

    func play(_ album: Album, startAt: Int = 0, shuffled: Bool? = nil) {
        Task {
            do {
                let full = try await self.album(album.id)
                player.play(full?.song ?? [], startAt: startAt, shuffled: shuffled)
            } catch { report(error) }
        }
    }

    func playNext(_ songs: [Song]) { player.playNext(songs.map(PlayItem.server)) }
    func addToQueue(_ songs: [Song]) { player.addToQueue(songs.map(PlayItem.server)) }

    func goToAlbum(_ song: Song) {
        guard let id = song.albumId else { return }
        if let album = albums.first(where: { $0.id == id }) { return show(.album(album)) }
        Task {
            do { if let album = try await album(id) { show(.album(album)) } } catch { report(error) }
        }
    }

    func goToArtist(_ song: Song) {
        if let id = song.artistId { show(.artist(id)) }
    }

    func isStarred(_ song: Song) -> Bool { starOverrides[song.id] ?? (song.starred != nil) }

    func toggleStar(_ song: Song) {
        let star = !isStarred(song)
        starOverrides[song.id] = star
        Task {
            do { try await star ? client?.star(ids: [song.id]) : client?.unstar(ids: [song.id]) } catch {
                starOverrides[song.id] = !star
                report(error)
            }
        }
    }

    func add(_ songs: [Song], to playlist: Playlist) {
        Task {
            do {
                try await client?.updatePlaylist(id: playlist.id, songIdsToAdd: songs.map(\.id))
                if let fresh = try await client?.getPlaylists() { apply(artists: artists, albums: albums, playlists: fresh) }
            } catch { report(error) }
        }
    }

    func copy(_ song: Song) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([song.title, song.artistName, song.album].compactMap { $0 }.joined(separator: " — "), forType: .string)
    }

    // MARK: Home and songs

    struct Shelf: Identifiable {
        let id: String
        let title: String
        let albums: [Album]
    }

    /// Album lists for Home; empty lists are dropped. Built from the local library when it is complete.
    func loadHome() async {
        if usesLocalLibrary, let db = library?.database {
            let newest = await db.albums(sort: .newest, limit: 20)
            let frequent = await db.albums(sort: .mostPlayed, limit: 20).filter { ($0.playCount ?? 0) > 0 }
            let recent = albums.filter { $0.played != nil }.sorted { $0.played! > $1.played! }.prefix(20)
            shelves = [Shelf(id: "newest", title: "Recently Added", albums: newest),
                       Shelf(id: "recent", title: "Recently Played", albums: Array(recent)),
                       Shelf(id: "frequent", title: "Most Played", albums: frequent),
                       Shelf(id: "random", title: "Discover", albums: Array(albums.shuffled().prefix(20)))]
                .filter { !$0.albums.isEmpty }
            libraryError = nil
            return
        }
        guard let client else { return }
        let kinds = [("newest", "Recently Added"), ("recent", "Recently Played"), ("frequent", "Most Played"), ("random", "Discover")]
        var result: [Shelf] = []
        do {
            for (type, title) in kinds {
                let albums = try await client.getAlbumList2(type: type, size: 20)
                if !albums.isEmpty { result.append(Shelf(id: type, title: title, albums: albums)) }
            }
            libraryError = nil
        } catch where !error.isCancellation {
            libraryError = error.localizedDescription
        } catch { return }
        if client.baseURL == self.client?.baseURL { shelves = result }
    }

    /// Loads all songs once per library version, 500 per request; the list grows as pages arrive.
    func loadSongs() async {
        guard let client, songsVersion != libraryVersion else { return }
        songsVersion = libraryVersion
        songsLoaded = false
        songsError = nil
        var all: [Song] = []
        if usesLocalLibrary, let db = library?.database {
            // Pages keep each actor call short; the list grows like the network one.
            while true {
                let page = await db.songs(sort: .title, limit: 5000, offset: all.count)
                all += page
                songs = all
                if page.count < 5000 || Task.isCancelled { break }
            }
            if !all.isEmpty { songsLoaded = true; return }
        }
        do {
            while true {
                // `search3` with an empty query lists the whole library (Navidrome, OpenSubsonic).
                let page = try await client.search3("", artistCount: 0, albumCount: 0, songCount: 500, songOffset: all.count).song
                all += page
                songs = all
                if page.count < 500 { break }
            }
        } catch {
            songsVersion = -1
            if !error.isCancellation { songsError = error.localizedDescription }
        }
        songsLoaded = true
    }

    /// Plays iPod tracks from the local files.
    func play(_ tracks: [DeviceTrack], startAt: Int = 0, shuffled: Bool = false) {
        guard ipod.current != nil else { return }  // offline: the files are not reachable
        player.play(ipod.playItems(shuffled ? tracks.shuffled() : tracks), startAt: shuffled ? 0 : startAt)
    }

    /// Stops local playback from the iPod, then ejects it.
    func eject() async {
        guard let device = ipod.current else { return }
        player.stopPlayback(under: device.mountURL)
        do { try await ipod.eject() } catch { report(error) }
    }

    func play(_ playlist: Playlist, shuffled: Bool? = nil) {
        Task {
            do {
                let full = try await self.playlist(playlist.id)
                player.play(full?.entry ?? [], shuffled: shuffled)
            } catch { report(error) }
        }
    }
}

extension Error {
    /// A request stopped by task cancellation (view gone, new search) rather than a real failure.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if (self as? URLError)?.code == .cancelled { return true }
        if case .badResponse(let what)? = self as? SubsonicError { return what.contains("cancelled") || what.contains("CancellationError") }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
