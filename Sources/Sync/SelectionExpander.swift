import Foundation
import Subsonic
import Transcode

/// Everything a selection resolves to.
public struct Expansion: Sendable {
    public var songs: [DesiredSong] = []
    public var playlists: [DesiredPlaylist] = []
    /// Selected ids the server no longer knows. Their songs are not desired.
    public var missing: [String] = []
}

public enum ExpansionError: Error, LocalizedError, Equatable {
    case unknownPreset(String)
    public var errorDescription: String? {
        switch self { case .unknownPreset(let id): "Unknown preset \(id)" }
    }
}

/// Turns a `Selection` into songs through the Subsonic API (8 requests in parallel, cached).
public actor SelectionExpander {
    /// An album with its songs from a local copy of the library; nil asks the server.
    public typealias LocalAlbum = @Sendable (String) async -> Album?
    /// Albums resolved so far and in all.
    public typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    private let client: SubsonicClient
    private let concurrency: Int
    private let local: LocalAlbum?
    private var albums: [String: Album] = [:]

    public init(client: SubsonicClient, concurrency: Int = 8, local: LocalAlbum? = nil) {
        self.client = client
        self.concurrency = concurrency
        self.local = local
    }

    public func clearCache() { albums = [:] }

    /// Throws on network errors: guessing here would make the planner delete songs.
    /// `fullAlbums`: playlist songs bring their whole albums (the iPod playlist still holds only its own songs).
    public func expand(_ selection: Selection, defaultPresetID: String, soundCheck: SyncSettings.SoundCheckSource,
                       fullAlbums: Bool = false, presets: [Preset] = Preset.builtIns,
                       progress: Progress? = nil) async throws -> Expansion {
        var result = Expansion()
        var albumIDs = selection.albums.sorted()
        async let fetchedArtists = fetchAll(selection.artists.sorted()) { try await self.client.getArtist(id: $0) }
        async let fetchedLists = fetchAll(selection.playlists.sorted()) { try await self.client.getPlaylist(id: $0) }
        let (artists, lists) = try await (fetchedArtists, fetchedLists)
        for (id, artist) in artists {
            if let artist { albumIDs += (artist.album ?? []).map(\.id).filter { !selection.excludedAlbums.contains($0) } } else { result.missing.append(id) }
        }
        var listed: [(Playlist, [Song])] = []
        for (id, list) in lists {
            if let list { listed.append((list, list.entry ?? [])) } else { result.missing.append(id) }
        }

        // Playlist songs need their album for track/disc totals.
        let extra = listed.flatMap { $0.1.compactMap(\.albumId) }
        let ids = Array(Set(albumIDs + extra)).sorted()
        let details = try await fetchAll(ids, progress: progress) { try await self.album($0) }
        var known: [String: Album] = [:]
        for (id, album) in details {
            if let album { known[id] = album } else if selection.albums.contains(id) { result.missing.append(id) }
        }

        let presetsByID = Dictionary(presets.map { ($0.id, $0) }) { a, _ in a }
        var seen = Set<String>()
        func add(_ song: Song, in album: Album?) throws {
            guard seen.insert(song.id).inserted else { return }
            let presetID = selection.presetID(forAlbum: song.albumId, default: defaultPresetID)
            guard let preset = presetsByID[presetID] else { throw ExpansionError.unknownPreset(presetID) }
            result.songs.append(Self.desired(song, album: album, preset: preset, soundCheck: soundCheck))
        }
        for id in Set(albumIDs).sorted() {
            guard let album = known[id] else { continue }
            for song in album.song ?? [] { try add(song, in: album) }
        }
        for (list, songs) in listed {
            for song in songs { try add(song, in: song.albumId.flatMap { known[$0] }) }
            if fullAlbums {
                for album in Set(songs.compactMap(\.albumId)).sorted().compactMap({ known[$0] }) {
                    for song in album.song ?? [] { try add(song, in: album) }
                }
            }
            result.playlists.append(DesiredPlaylist(id: list.id, name: list.name, songIDs: songs.map(\.id)))
        }
        return result
    }

    private func album(_ id: String) async throws -> Album {
        if let cached = albums[id] { return cached }
        let album = if let found = await local?(id) { found } else { try await client.getAlbum(id: id) }
        albums[id] = album
        return album
    }

    /// Runs `body` for every id, `concurrency` at a time. A server "not found" gives nil; other errors are thrown.
    private func fetchAll<T: Sendable>(_ ids: [String], progress: Progress? = nil, _ body: @escaping @Sendable (String) async throws -> T)
        async throws -> [(String, T?)]
    {
        try await withThrowingTaskGroup(of: (String, T?).self) { group in
            var next = ids.makeIterator()
            var out: [(String, T?)] = []
            func start() {
                guard let id = next.next() else { return }
                group.addTask {
                    do { return (id, try await body(id)) } catch SubsonicError.api(let code, _) where code == 70 { return (id, nil) }
                }
            }
            for _ in 0..<concurrency { start() }
            while let item = try await group.next() {
                out.append(item)
                progress?(out.count, ids.count)
                start()
            }
            return out.sorted { $0.0 < $1.0 }
        }
    }

    static func desired(_ song: Song, album: Album?, preset: Preset, soundCheck: SyncSettings.SoundCheckSource) -> DesiredSong {
        let siblings = album?.song ?? []
        let disc = song.discNumber ?? 1
        let trackTotal = siblings.filter { ($0.discNumber ?? 1) == disc }.count
        let discTotal = siblings.compactMap(\.discNumber).max() ?? 0
        let tags = TrackTags(
            title: song.title, artist: song.artistName ?? "", album: song.album ?? album?.name ?? "",
            albumArtist: song.displayAlbumArtist ?? song.albumArtist ?? album?.artistName ?? "",
            genre: song.genre ?? album?.genre ?? "", year: song.year ?? album?.year,
            trackNumber: song.track, trackTotal: trackTotal > 0 ? trackTotal : nil,
            discNumber: song.discNumber, discTotal: discTotal > 0 ? discTotal : nil,
            compilation: album?.isCompilation ?? false)
        let gain: Double? = switch soundCheck {
        case .album: song.replayGain?.albumGain ?? song.replayGain?.trackGain
        case .track: song.replayGain?.trackGain ?? song.replayGain?.albumGain
        case .off: nil
        }
        return DesiredSong(song: song, preset: preset, tags: tags, coverArtID: album?.coverArt ?? song.coverArt,
                           soundCheckGain: gain)
    }
}
