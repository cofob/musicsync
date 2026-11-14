import AppKit
import Library
import Observation
import Subsonic
import Support
import Sync

/// Navigation targets pushed on the detail stack.
enum Route: Hashable {
    case album(Album)
    case artist(String)
    case playlist(Playlist)
    case deviceAlbum(String)
    case devicePlaylist(Int)
    case genre(String)
    case mix(String)
    case podcast(PodcastChannel)
    case stats
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
    var mirrorStatus = MirrorStatus() {
        // Stored, so the menus (the whole App body) do not rebuild on every progress step.
        didSet { if isMirrorRunning != (mirrorStatus.state == .running) { isMirrorRunning.toggle() } }
    }
    private(set) var isMirrorRunning = false
    /// End of the last complete listing (survives restarts, unlike `mirrorStatus.lastSuccess`).
    var lastLibrarySync: Date?
    /// True when lists come from the local database instead of the network.
    var usesLocalLibrary = false
    /// Settings > Library; saved on every change.
    var mirrorSettings = MirrorSettings() {
        didSet {
            guard mirrorSettings != oldValue else { return }
            UserDefaults.app.set(try? JSONEncoder().encode(mirrorSettings), forKey: Self.mirrorKey)
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
    var isLoading: Bool { loadingStore != nil }
    /// Store whose refresh runs; a refresh for another server is not blocked by it.
    private var loadingStore: LibraryStore?
    /// Alert for failed user actions; set through `report(_:)`.
    var errorMessage: String?
    /// Inline messages for failed background loads (library, Home, songs, search).
    private(set) var libraryError: String?

    var selection: SidebarItem? = AppPreferences.shared.startPage
    var path: [Route] = []
    var searchText = ""
    /// `searchText` without leading and trailing spaces; the filter of the list pages.
    var query: String { searchText.trimmingCharacters(in: .whitespaces) }
    /// Bumped by Edit > Find; the toolbar search field takes focus.
    var searchFocusRequest = 0
    /// Set by the toolbar search field.
    var searchFieldFocused = false
    @ObservationIgnored private(set) lazy var search = SearchModel(app: self)
    @ObservationIgnored private(set) lazy var mixes = MixModel(app: self)
    @ObservationIgnored private(set) lazy var browse = BrowseModel(app: self)
    @ObservationIgnored private(set) lazy var radio = RadioModel(app: self)
    @ObservationIgnored private(set) lazy var podcasts = PodcastsModel(app: self)
    @ObservationIgnored private(set) lazy var bookmarks = BookmarkKeeper(app: self)
    @ObservationIgnored private(set) lazy var smartDownloads = SmartDownloads(app: self)
    /// Sharing, deep links, Spotlight, global shortcuts, notifications.
    @ObservationIgnored private(set) lazy var system = SystemServices(app: self)
    /// The web remote for iPhone, iPad and Apple Watch (Settings > Remote).
    @ObservationIgnored private(set) lazy var remote = RemoteControl(app: self)
    @ObservationIgnored private(set) lazy var queueKeeper = QueueKeeper(app: self)
    @ObservationIgnored private(set) lazy var serverQueue = ServerQueue(app: self)
    /// The server's own audio output as a player output (Subsonic jukebox).
    @ObservationIgnored private(set) lazy var jukebox = Jukebox(app: self)
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
    /// Star state changed in this session, by song, album or artist id.
    var starOverrides: [String: Bool] = [:]
    /// Ratings changed in this session, by song id.
    var ratingOverrides: [String: Int] = [:]
    /// Set when the server refuses `setRating`; the rating controls are hidden then.
    var ratingUnsupported = false
    /// New Playlist sheet, delete confirmation or duplicate warning (`PlaylistDialogs`).
    var playlistPrompt: PlaylistPrompt?

    let player = Player()
    let downloads = DownloadsModel()
    /// The connected iPod (read-only snapshot, eject). Sync UI hooks live here.
    let ipod = DeviceModel()
    let sync = SyncModel()
    /// Sync options (Settings > Sync); saved on every change.
    var syncSettings = SyncSettings.load() {
        didSet {
            syncSettings.save()
            let (new, old) = (syncSettings, oldValue)
            if (new.fullAlbums, new.keepFreeGB, new.deviceNames, new.aacBitrate, new.opusBitrate)
                != (old.fullAlbums, old.keepFreeGB, old.deviceNames, old.aacBitrate, old.opusBitrate) { sync.schedulePlan() }
        }
    }
    @ObservationIgnored private var spaceMonitor: Any?

    /// Development only: `MUSICSYNC_DEMO=1` uses the public Navidrome demo (see `Paths.isDemo`),
    /// or `MUSICSYNC_DEMO_SERVER`, e.g. the big library of `scripts/big-server.py`.
    @ObservationIgnored let demo = Paths.isDemo

    init() {
        if demo {
            let server = ProcessInfo.processInfo.environment["MUSICSYNC_DEMO_SERVER"].flatMap(URL.init(string:))
            config = ServerConfig(baseURL: server ?? URL(string: "https://demo.navidrome.org")!, username: "demo")
        } else if let data = UserDefaults.app.data(forKey: Self.configKey) {
            config = try? JSONDecoder().decode(ServerConfig.self, from: data)
        }
        if let data = UserDefaults.app.data(forKey: Self.mirrorKey),
           let saved = try? JSONDecoder().decode(MirrorSettings.self, from: data) {
            mirrorSettings = saved
        }
        ipod.manualGuid = { [weak self] device in device.volumeUUID.flatMap { self?.syncSettings.manualGuids[$0] } }
        sync.attach(self)
        downloads.attach(to: player)
        _ = mixes  // starts the play history
        _ = smartDownloads
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
        UserDefaults.app.set(try? JSONEncoder().encode(config), forKey: Self.configKey)
        await connect()
    }

    private func connect() async {
        path = []
        shelves = []; starOverrides = [:]; ratingOverrides = [:]; ratingUnsupported = false; lyricsCache = [:]
        queueKeeper.leave()
        jukebox.leave()
        player.stop()
        await stopLibrary()
        await downloads.stop()
        let session = AppPreferences.shared.advanced.session()
        let client = demo ? config.map { SubsonicClient(baseURL: $0.baseURL, username: $0.username, password: "demo", session: session) }
                          : config.flatMap { SubsonicClient(config: $0, session: session) }
        guard let client else {
            self.client = nil; store = nil; covers = nil
            player.client = nil; player.covers = nil
            apply(artists: [], albums: [], playlists: [])
            return
        }
        let store = LibraryStore(client: client)
        downloads.start(client: client)
        let covers = CoverArtCache(client: client, offline: downloads.manager?.coversDirectory)
        self.client = client; self.store = store; self.covers = covers
        player.client = client; player.covers = covers
        trimCoverCache()
        Task { await player.loadFeatures(client) }
        sync.flushScrobbles(client)
        sync.deviceUpdated()  // the manifest belongs to the server
        let library = makeLibrary(client.config)
        startLibrary(library, client: client)
        Task { await queueKeeper.restore(client, library: library); await serverQueue.connected(client); await bookmarks.connected(client) }
        Task { await jukebox.connected(client) }
        if await reloadFromDatabase(library) { return }
        let cache = await store.load()
        guard store === self.store else { return }
        apply(artists: cache.artists, albums: cache.albums, playlists: cache.playlists)
        await refresh()
    }

    /// Reads lists from the local database when it is complete, else from the server (`LibraryStore`).
    func refresh(force: Bool = false) async {
        if !force, let library, await reloadFromDatabase(library) { return }
        guard let store, loadingStore !== store else { return }
        loadingStore = store
        defer { if loadingStore === store { loadingStore = nil } }
        do {
            let cache = try await store.refresh(force: force)
            guard store === self.store else { return }
            if !usesLocalLibrary { apply(artists: cache.artists, albums: cache.albums, playlists: cache.playlists) }
            libraryError = nil
        } catch where !error.isCancellation && store === self.store {
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
            let base = [Shelf(id: "newest", title: "Recently Added", albums: newest),
                        Shelf(id: "recent", title: "Recently Played", albums: Array(recent)),
                        Shelf(id: "frequent", title: "Most Played", albums: frequent),
                        Shelf(id: "random", title: "Discover", albums: Array(albums.shuffled().prefix(20)))]
                .filter { !$0.albums.isEmpty }
            shelves = mixes.personalized(base, albums: albums)
            libraryError = nil
            await mixes.load()
            shelves = mixes.personalized(base, albums: albums)
            return
        }
        guard let client else { return }
        let kinds = [("newest", "Recently Added"), ("recent", "Recently Played"), ("frequent", "Most Played"), ("random", "Discover")]
        var result: [Shelf] = []
        do {
            let lists = try await withThrowingTaskGroup(of: (String, [Album]).self) { group in
                for (type, _) in kinds { group.addTask { (type, try await client.getAlbumList2(type: type, size: 20)) } }
                var lists: [String: [Album]] = [:]
                for try await (type, albums) in group { lists[type] = albums }
                return lists
            }
            result = kinds.compactMap { type, title in lists[type].flatMap { $0.isEmpty ? nil : Shelf(id: type, title: title, albums: $0) } }
            libraryError = nil
        } catch where !error.isCancellation {
            libraryError = error.localizedDescription
        } catch { return }
        if client.baseURL == self.client?.baseURL { shelves = result }
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
                mixes.play(full?.entry ?? [], from: .playlist, shuffled: shuffled)
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
