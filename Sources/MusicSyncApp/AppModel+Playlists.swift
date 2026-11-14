import Foundation
import Library
import Subsonic

/// What a playlist action asks before it runs; shown by `PlaylistDialogs`.
enum PlaylistPrompt: Identifiable {
    /// New Playlist sheet; these songs go into the new playlist.
    case create(songIds: [String])
    case delete(Playlist)
    /// `count` of the songs are already in the playlist.
    case duplicates(songIds: [String], Playlist, count: Int)

    var id: String {
        switch self {
        case .create: "create"
        case .delete(let p): "delete-\(p.id)"
        case .duplicates(_, let p, _): "duplicates-\(p.id)"
        }
    }
}

/// Playlist changes. Every change goes to the server, then the fresh playlist goes into the local library
/// and the playlist list, so the sidebar and pages show it without waiting for the mirror.
extension AppModel {
    /// Own playlists only: smart playlists and those of other users cannot be changed.
    func canEdit(_ playlist: Playlist) -> Bool {
        playlist.readonly != true && playlist.validUntil == nil && (playlist.owner == nil || playlist.owner == client?.username)
    }

    var editablePlaylists: [Playlist] { playlists.filter(canEdit) }

    /// Asks first when some of the songs are already in the playlist.
    func add(_ songIds: [String], to playlist: Playlist) {
        Task {
            do {
                let present = Set(try await self.playlist(playlist.id)?.entry?.map(\.id) ?? [])
                let count = songIds.filter(present.contains).count
                if count > 0 { playlistPrompt = .duplicates(songIds: songIds, playlist, count: count) } else { await append(songIds, to: playlist) }
            } catch { report(error) }
        }
    }

    /// Adds without the duplicate check.
    func append(_ songIds: [String], to playlist: Playlist) async {
        guard !songIds.isEmpty else { return }
        do {
            try await client?.updatePlaylist(id: playlist.id, songIdsToAdd: songIds)
            await reloadPlaylist(playlist.id)
        } catch { report(error) }
    }

    /// Creates the playlist and opens it.
    func createPlaylist(name: String, comment: String, songIds: [String]) async {
        guard let client, let store else { return }
        do {
            guard let created = try await client.createPlaylist(name: name, songIds: songIds) else {
                if store === self.store { await refresh(force: true) }  // old server: no id in the reply
                return
            }
            if !comment.isEmpty { try await client.updatePlaylist(id: created.id, comment: comment) }
            guard store === self.store else { return }
            await reloadPlaylist(created.id)
            selection = .playlist(created.id)
        } catch { report(error) }
    }

    /// Shown at once; the old name comes back if the server refuses.
    func rename(_ playlist: Playlist, to name: String, comment: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != playlist.name || comment != playlist.comment else { return }
        let before = playlists, store = store
        put(playlist.renamed(name, comment: comment))
        Task {
            do {
                try await client?.updatePlaylist(id: playlist.id, name: name, comment: comment ?? "")
                await reloadPlaylist(playlist.id)
            } catch { undo(before, error, store) }
        }
    }

    func setPublic(_ playlist: Playlist, _ isPublic: Bool) {
        Task {
            do {
                try await client?.updatePlaylist(id: playlist.id, isPublic: isPublic)
                await reloadPlaylist(playlist.id)
            } catch { report(error) }
        }
    }

    func delete(_ playlist: Playlist) {
        let before = playlists, store = store
        apply(artists: artists, albums: albums, playlists: playlists.filter { $0.id != playlist.id })
        if selection == .playlist(playlist.id) { selection = .playlists }
        path.removeAll { if case .playlist(let p) = $0 { p.id == playlist.id } else { false } }
        let database = library?.database
        Task {
            do {
                try await client?.deletePlaylist(id: playlist.id)
                try? await database?.deletePlaylist(id: playlist.id)
                sync.libraryChanged()  // a check that ran meanwhile may have cached the playlist
            } catch { undo(before, error, store) }
        }
    }

    /// `indexes` are positions in the playlist's own order. Returns the playlist as the server now has it.
    func removeSongs(at indexes: [Int], from playlist: Playlist) async throws -> Playlist? {
        try await client?.updatePlaylist(id: playlist.id, songIndexesToRemove: indexes)
        return await reloadPlaylist(playlist.id)
    }

    /// Sends the whole new order.
    func reorder(_ playlist: Playlist, songIds: [String]) async throws -> Playlist? {
        try await client?.replacePlaylistSongs(id: playlist.id, songIds: songIds)
        return await reloadPlaylist(playlist.id)
    }

    /// Fetches the playlist and puts it into the local library and the playlist list.
    @discardableResult
    func reloadPlaylist(_ id: String) async -> Playlist? {
        guard let client, let store, let fresh = try? await client.getPlaylist(id: id), store === self.store else { return nil }
        try? await library?.database.storePlaylist(fresh)
        put(fresh.withEntries(nil))
        return fresh
    }

    /// Replaces the playlist in the list, or inserts a new one by name.
    private func put(_ playlist: Playlist) {
        var list = playlists
        if let i = list.firstIndex(where: { $0.id == playlist.id }) {
            list[i] = playlist
        } else {
            let i = list.firstIndex { $0.name.localizedCaseInsensitiveCompare(playlist.name) == .orderedDescending } ?? list.endIndex
            list.insert(playlist, at: i)
        }
        apply(artists: artists, albums: albums, playlists: list)
    }

    /// Puts the list back, unless the server changed meanwhile.
    private func undo(_ playlists: [Playlist], _ error: Error, _ store: LibraryStore?) {
        guard store === self.store else { return }
        apply(artists: artists, albums: albums, playlists: playlists)
        report(error)
    }
}
