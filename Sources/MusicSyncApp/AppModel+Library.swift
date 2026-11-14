import AppKit
import Library
import Subsonic

/// Local library mirror: lifecycle, reads with network fallback, and the controls of the status UI.
/// Mirror and database problems only change `mirrorStatus`; they never raise alerts.
extension AppModel {
    func makeLibrary(_ server: ServerConfig) -> Library {
        Library(server: server, settings: mirrorSettings)
    }

    /// Starts the mirror for `client` and follows its status; a finished pass reloads the lists.
    func startLibrary(_ library: Library, client: SubsonicClient) {
        self.library = library
        mirrorStatus = library.mirror.currentStatus
        observeMirror(library)
        Task {
            lastLibrarySync = await library.database.lastFullSync
            await library.mirror.start(client: client)
        }
    }

    func stopLibrary() async {
        statusTask?.cancel()
        guard let old = library else { return }
        library = nil
        usesLocalLibrary = false
        await old.mirror.stop()
    }

    private func observeMirror(_ library: Library) {
        statusTask = Task { [weak self] in
            for await status in library.mirror.status {
                guard let self, !Task.isCancelled else { return }
                let finished = status.lastSuccess != nil && status.lastSuccess != self.mirrorStatus.lastSuccess
                let wasRunning = self.mirrorStatus.state == .running
                self.mirrorStatus = status
                // Failed passes may still have stored data, so reload after any pass end.
                if finished || (wasRunning && status.state != .running) {
                    self.lastLibrarySync = await library.database.lastFullSync
                    if await self.reloadFromDatabase(library) { await self.loadHome() }
                }
            }
        }
    }

    /// Takes artists, albums and playlists from the database when it is complete and healthy.
    /// Returns false (and leaves the lists alone) otherwise.
    @discardableResult
    func reloadFromDatabase(_ library: Library) async -> Bool {
        let db = library.database
        guard await db.isHealthy, await db.isPopulated else { return false }
        let artists = await db.artists(), albums = await db.albums(), playlists = await db.playlists()
        guard self.library?.database === db, !albums.isEmpty else { return false }
        usesLocalLibrary = true
        apply(artists: artists, albums: albums, playlists: playlists, onlyIfChanged: true)
        return true
    }

    // MARK: Reads with fallback

    /// Album with songs: local database, else `LibraryStore` (disk cache, then server).
    func album(_ id: String) async throws -> Album? {
        if let local = await library?.database.album(id: id) { return local }
        return try await store?.album(id)
    }

    /// Playlist with entries: local database, else server.
    func playlist(_ id: String) async throws -> Playlist? {
        if let local = await library?.database.playlist(id: id) { return local }
        return try await store?.playlist(id)
    }

    /// Lyrics from memory, then the library database, then the server; server replies (also "none") are kept.
    func lyrics(for song: Song) async -> Lyrics? {
        if let hit = lyricsCache[song.id] { return hit }
        do {
            let found = try await fetchLyrics(song)
            lyricsCache[song.id] = .some(found)
            return found
        } catch { return nil }  // a failed request is not kept as "none"
    }

    private func fetchLyrics(_ song: Song) async throws -> Lyrics? {
        func best(_ list: [StructuredLyrics]) -> Lyrics? { (list.first(where: \.synced) ?? list.first).flatMap(Lyrics.init) }
        let database = library?.database
        if let stored = await database?.storedLyrics(songId: song.id) { return best(stored) }
        guard let client else { return nil }
        if let list = try? await client.getLyricsBySongId(id: song.id) {
            try? await database?.storeLyrics(songId: song.id, lyrics: list)
            if let lyrics = best(list) { return lyrics }
        }
        guard let artist = song.artist else { return nil }
        return try await Lyrics(plain: client.getLyrics(artist: artist, title: song.title).value ?? "")
    }

    /// The 96 px local thumbnail of a cover, if the mirror has it.
    func smallCover(_ id: String) async -> NSImage? {
        guard let url = await library?.database.smallCoverURL(coverArtId: id) else { return nil }
        return await covers?.image(file: url, key: id)
    }

    // MARK: Controls

    var isMirrorRunning: Bool { mirrorStatus.state == .running }

    func syncLibraryNow() {
        guard let library else { return }
        Task { await library.mirror.syncNow() }
    }

    func toggleMirrorPause() {
        guard let library else { return }
        let paused = mirrorStatus.state == .paused
        Task { if paused { await library.mirror.resume() } else { await library.mirror.pause() } }
    }

    /// Size of the database file (with its journal) and the thumbnails.
    func libraryDiskSize() async -> Int64 {
        guard let db = library?.database else { return 0 }
        let files = [db.fileURL.path, db.fileURL.path + "-wal", db.fileURL.path + "-shm"].map(URL.init(fileURLWithPath:))
        return await Task.detached { files.reduce(0) { $0 + fileSize($1) } + directorySize(db.coversDirectory) }.value
    }

    /// Deletes the local database and thumbnails, then starts a fresh mirror. Lists come from the server meanwhile.
    func resetLibrary() async {
        guard let old = library, let client else { return }
        await stopLibrary()
        let path = old.database.fileURL.path, covers = old.database.coversDirectory
        await Task.detached {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            try? FileManager.default.removeItem(at: covers)
        }.value
        lastLibrarySync = nil
        startLibrary(makeLibrary(client.config), client: client)
        await refresh(force: true)
    }
}

private func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}

private func directorySize(_ url: URL) -> Int64 {
    let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    return (files?.allObjects as? [URL] ?? []).reduce(0) { $0 + fileSize($1) }
}
