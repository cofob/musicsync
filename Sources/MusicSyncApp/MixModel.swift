import Foundation
import Library
import Observation
import Recommend
import Subsonic
import Support

/// Recommendations made on this Mac from the library and the play history: "Made for You" mixes, stations and AutoPlay.
/// They need the complete local mirror (`AppModel.usesLocalLibrary`); without it everything here stays empty or hidden.
@MainActor @Observable
final class MixModel {
    /// What a station starts from.
    enum StationSeed {
        case song(Song), album(Album), artist(String), playlist(Playlist)
    }

    private static let autoPlayKey = "autoPlay"

    private(set) var mixes: [Mix] = []
    /// "Because You Listened to" shelves.
    private(set) var because: [Mix] = []
    /// Songs of `mixes` and `because` by id.
    private(set) var songs: [String: Song] = [:]
    /// When the queue ends, go on with similar songs.
    var autoPlay = UserDefaults.app.object(forKey: autoPlayKey) as? Bool ?? true {
        didSet { UserDefaults.app.set(autoPlay, forKey: Self.autoPlayKey); extendQueue() }
    }

    var isAvailable: Bool { app.usesLocalLibrary }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored let recorder: PlayRecorder
    /// Library songs and playlists; read again only when the library changes.
    @ObservationIgnored private var input: (database: LibraryDatabase, version: Int, tracks: [Track], playlists: [[String]])?
    /// Day, library and refresh the shown mixes were made for.
    @ObservationIgnored private var loadedKey: String?
    /// Set by Refresh: other mixes for the rest of the day.
    @ObservationIgnored private var salt = ""
    @ObservationIgnored private var extending = false

    init(app: AppModel) {
        self.app = app
        recorder = PlayRecorder(player: app.player) { [weak app] in app?.library }
        recorder.onTrackStart = { [weak self] in self?.extendQueue() }
    }

    /// Plays songs and notes where they came from, for the play history.
    func play(_ list: [Song], from source: PlaySource, startAt: Int = 0, shuffled: Bool? = nil) {
        recorder.tag(list, as: source)
        app.player.play(list, startAt: startAt, shuffled: shuffled)
    }

    func songs(of mix: Mix) -> [Song] { mix.trackIds.compactMap { songs[$0] } }

    func mix(id: String) -> Mix? { (mixes + because).first { $0.id == id } }

    // MARK: Mixes

    /// Makes the mixes of the day; nothing happens when they are up to date. `refresh` makes new ones.
    func load(refresh: Bool = false) async {
        guard app.usesLocalLibrary, let db = app.library?.database else { mixes = []; because = []; return }
        if refresh { salt = UUID().uuidString }
        let day = Self.today + salt
        let key = "\(ObjectIdentifier(db).hashValue)|\(app.libraryVersion)|\(day)"
        guard key != loadedKey, let catalog = await catalog() else { return }
        let (made, shelves) = await Task.detached(priority: .userInitiated) {
            (catalog.madeForYou(day: day), catalog.becauseYouListened(day: day))
        }.value
        let found = await db.songs(ids: Array(Set((made + shelves).flatMap(\.trackIds))))
        guard app.library?.database === db else { return }
        songs = Dictionary(found.map { ($0.id, $0) }) { a, _ in a }
        mixes = made
        because = shelves
        loadedKey = key
    }

    func play(_ mix: Mix, startAt: Int = 0, shuffled: Bool? = nil) { play(songs(of: mix), from: .mix, startAt: startAt, shuffled: shuffled) }

    /// Opens the New Playlist sheet with the songs of the mix.
    func save(_ mix: Mix) { app.playlistPrompt = .create(songIds: songs(of: mix).map(\.id)) }

    private static var today: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Stations and AutoPlay

    /// Plays a station: songs similar to the seed, drifting further away.
    func startStation(_ seed: StationSeed) {
        Task {
            guard let db = app.library?.database, let base = await catalog() else { return }
            var seeds: [String]
            switch seed {
            case .song(let song): seeds = [song.id]
            case .album(let album): seeds = base.seeds(base.songs(albumId: album.id))
            case .artist(let name):
                let client = app.client
                let top = await quick { try await client?.getTopSongs(artist: name, count: 20).map(\.id) ?? [] }
                seeds = base.seeds(top.isEmpty ? base.songs(artist: name) : top)
            case .playlist(let playlist): seeds = base.seeds((try? await app.playlist(playlist.id))?.entry?.map(\.id) ?? [])
            }
            guard let first = seeds.first else {
                app.errorMessage = "There are not enough songs for a station."
                return
            }
            let catalog = base.adding(similar: [first: await similarSongs(first)])
            let ids = await Task.detached { catalog.radio(seeds: seeds, count: 50, seed: .random(in: 0 ... .max)) }.value
            let list = await db.songs(ids: ids)
            guard !list.isEmpty, app.library?.database === db else { return }
            play(list, from: .radio, shuffled: false)
        }
    }

    /// AutoPlay: when one song is left, appends a station from the end of the queue.
    private func extendQueue() {
        let player = app.player
        guard app.usesLocalLibrary, !extending, case .server? = player.current,
              AutoPlay.shouldExtend(remaining: player.upcoming.count, enabled: autoPlay, repeating: player.repeatMode != .off) else { return }
        let queue = player.queue.compactMap { if case .server(let s) = $0 { s.id } else { nil } }
        guard let last = queue.last else { return }
        extending = true
        Task {
            defer { extending = false }
            guard let db = app.library?.database, let base = await catalog() else { return }
            let catalog = base.adding(similar: [last: await similarSongs(last)])
            let ids = await Task.detached { catalog.continuation(of: queue, seed: .random(in: 0 ... .max)) }.value
            let list = await db.songs(ids: ids)
            // Extend only the queue this was made for.
            guard !list.isEmpty, player.queue.last?.id == last, app.library?.database === db else { return }
            recorder.tagAutoPlay(list)
            player.addAutoPlay(list.map(PlayItem.server))
        }
    }

    /// The server's similar songs; empty when it has none (no Last.fm), fails or is slow.
    private func similarSongs(_ id: String) async -> [String] {
        guard let client = app.client else { return [] }
        return await quick { try await client.getSimilarSongs2(id: id, count: 50).map(\.id) }
    }

    /// Server hints are optional: a server asking Last.fm can hang for long, so wait at most 3 s.
    private func quick(_ body: @escaping @Sendable () async throws -> [String]) async -> [String] {
        let request = Task { (try? await body()) ?? [] }
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); request.cancel() }
        defer { timeout.cancel() }
        return await request.value
    }

    /// A catalog with the newest history.
    private func catalog() async -> Catalog? {
        guard app.usesLocalLibrary, let library = app.library else { return nil }
        let db = library.database, version = app.libraryVersion
        if input?.database !== db || input?.version != version {
            let tracks = await db.recommendationTracks(), playlists = await db.playlistMembers()
            guard app.library?.database === db else { return nil }
            input = (db, version, tracks, playlists)
        }
        guard let input, !input.tracks.isEmpty else { return nil }
        let events = await library.history.events(), stats = await library.history.stats()
        return await Task.detached(priority: .userInitiated) {
            Catalog(tracks: input.tracks, playlists: input.playlists, history: events, stats: stats)
        }.value
    }
}
