import Foundation
import Library
import Observation
import Preferences
import Subsonic
import Sync

/// The list saved as itself under `defaultsKey`. A wrapper, as Library does not see Preferences.
private struct SavedSmartPlaylists: StoredSettings {
    static let defaultsKey = "smartPlaylists"
    var list = SmartPlaylistList()
    init() {}
    init(_ list: SmartPlaylistList) { self.list = list }
    init(from decoder: Decoder) throws { list = try SmartPlaylistList(from: decoder) }
    func encode(to encoder: Encoder) throws { try list.encode(to: encoder) }
}

/// Smart playlists: rules kept on this Mac and evaluated against the local library, never sent to the server.
/// Pages show them as read-only playlists with ids that start with `SmartPlaylist.idPrefix`.
@MainActor @Observable
final class SmartPlaylistsModel {
    /// By name.
    private(set) var list = SavedSmartPlaylists.load().list.playlists
    /// Songs and cover of each playlist at its last evaluation.
    private(set) var summaries: [String: Summary] = [:]
    /// The playlist in the editor sheet.
    var editing: SmartPlaylist?
    /// Asks before the playlist is deleted.
    var deleting: SmartPlaylist?
    @ObservationIgnored private unowned let app: AppModel

    struct Summary: Equatable {
        var matches: SmartPlaylist.Matches
        var coverArt: String?
    }

    init(app: AppModel) { self.app = app }

    /// Smart playlists need the local library.
    var isAvailable: Bool { app.library != nil }

    func definition(_ id: String) -> SmartPlaylist? { list.first { $0.id == id } }

    /// The playlist as pages show it. `changed` follows the rules and every library update, so an open page evaluates again.
    func playlist(_ id: String) -> Playlist? {
        guard let p = definition(id) else { return nil }
        let summary = summaries[id]
        return Playlist(localID: id, name: p.name, songCount: summary?.matches.ids.count, duration: summary?.matches.duration,
                        changed: "\(p.hashValue)-\(app.libraryVersion)", coverArt: summary?.coverArt)
    }

    var playlists: [Playlist] { list.compactMap { playlist($0.id) } }

    /// The playlist with its songs; nil when it is unknown or there is no local library.
    func full(_ id: String) async -> Playlist? {
        guard let p = definition(id), let library = app.library else { return nil }
        let songs = await library.smartSongs(p, downloaded: downloadedIDs)
        guard app.library?.database === library.database else { return nil }
        let matches = SmartPlaylist.Matches(ids: songs.map(\.id), duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
                                            size: songs.reduce(0) { $0 + Int64($1.size ?? 0) })
        let summary = Summary(matches: matches, coverArt: songs.first { $0.coverArt != nil }?.coverArt)
        if summaries[id] != summary { summaries[id] = summary }
        return playlist(id)?.withEntries(songs)
    }

    /// Count, length and size of what `draft` matches now, for the editor.
    func preview(_ draft: SmartPlaylist) async -> SmartPlaylist.Matches? {
        var live = draft
        live.liveUpdating = true
        return await app.library?.smartMatches(live, downloaded: downloadedIDs)
    }

    func create() { editing = SmartPlaylist() }

    func edit(_ id: String) { editing = definition(id) }

    /// Stores the playlist, opens a new one, and updates its download and iPod selection.
    /// Without live updating its songs stay as they match now.
    func save(_ draft: SmartPlaylist) async {
        var p = draft
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = "Untitled Smart Playlist" }
        p.frozen = nil
        if !p.liveUpdating, let library = app.library { p.frozen = await library.smartMatches(p, downloaded: downloadedIDs).ids }
        let isNew = definition(p.id) == nil
        list.removeAll { $0.id == p.id }
        list.append(p)
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        SavedSmartPlaylists(SmartPlaylistList(playlists: list)).save()
        if isNew { app.selection = .playlist(p.id) }
        if app.downloads.isPinned(.playlist(p.id)), let playlist = playlist(p.id) { app.download(playlist) }
        if app.sync.isPlaylistSelected(p.id) { app.sync.libraryChanged() }
    }

    func duplicate(_ id: String) {
        guard let p = definition(id) else { return }
        Task { await save(p.duplicated()) }
    }

    /// Also removes its download and its iPod selection.
    func delete(_ p: SmartPlaylist) {
        list.removeAll { $0.id == p.id }
        summaries[p.id] = nil
        SavedSmartPlaylists(SmartPlaylistList(playlists: list)).save()
        if app.downloads.isPinned(.playlist(p.id)) { app.removeDownload(.playlist(p.id)) }
        if app.sync.isPlaylistSelected(p.id) { app.sync.togglePlaylist(p.id) }
        if app.selection == .playlist(p.id) { app.selection = .playlists }
        app.path.removeAll { if case .playlist(let q) = $0 { q.id == p.id } else { false } }
    }

    private var downloadedIDs: Set<String> { Set(app.downloads.entries.values.filter { $0.state == .done }.map(\.id)) }
}

extension AppModel {
    /// The mirror as a sync source, with smart playlists resolved from their rules.
    var syncLibrary: LocalLibrary? {
        guard let db = library?.database else { return nil }
        var local = db.local
        let plain = local.playlist
        local.playlist = { [weak self] id in SmartPlaylist.isSmart(id) ? await self?.smartPlaylist(id) : await plain(id) }
        return local
    }

    private func smartPlaylist(_ id: String) async -> Playlist? { await smartPlaylists.full(id) }
}
