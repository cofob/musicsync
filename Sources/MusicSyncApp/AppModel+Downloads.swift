import Library
import Subsonic

/// Download actions of the menus, buttons and the Downloaded page. Failures go to `report(_:)`.
extension AppModel {
    func download(_ song: Song) {
        downloadAction { try await $0.download([song]) }
    }

    func download(_ album: Album) {
        downloadAction { manager in
            guard let full = try await self.album(album.id), manager === self.downloads.manager else { return }
            try await manager.pin(.album(full), songs: full.song ?? [])
        }
    }

    func download(_ playlist: Playlist) {
        downloadAction { manager in
            guard let full = try await self.playlist(playlist.id), manager === self.downloads.manager else { return }
            try await manager.pin(.playlist(full), songs: full.entry ?? [])
        }
    }

    /// Removes the song's own download; it stays while an album or playlist keeps it.
    func removeDownload(_ song: Song) {
        downloadAction { try await $0.remove(.song, songIDs: [song.id]) }
    }

    func removeDownload(_ reason: DownloadReason) {
        downloadAction { try await $0.remove(reason) }
    }

    func removeAllDownloads() {
        downloadAction { try await $0.removeAll() }
    }

    /// Follows changes of pinned albums and playlists after a library sync, then the smart download rules.
    /// Only the local library is read.
    func refreshDownloadPins() {
        guard let manager = downloads.manager, let db = library?.database else { return }
        Task {
            await manager.refreshPins { pin in
                switch pin {
                case .album(let album): await db.album(id: album.id)?.song
                case .playlist(let playlist): await db.playlist(id: playlist.id)?.entry
                }
            }
            smartDownloads.run()
        }
    }

    private func downloadAction(_ body: @escaping (DownloadManager) async throws -> Void) {
        guard let manager = downloads.manager else { return }
        Task {
            do { try await body(manager) } catch { report(error) }
        }
    }
}
