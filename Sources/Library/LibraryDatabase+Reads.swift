import Foundation
import Subsonic

/// Read API for the UI. Nothing here throws: on any database problem the result is empty (or nil),
/// and `isHealthy` tells the caller to use the network instead.
extension LibraryDatabase {
    private func decode<T: Decodable>(_ type: T.Type, _ row: SQLiteRow, _ column: Int32 = 0) -> T? {
        row.text(column).flatMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    private func decodeAll<T: Decodable>(_ db: SQLiteConnection, _ type: T.Type, _ sql: String, _ params: [any SQLConvertible] = []) throws -> [T] {
        try db.rows(sql, params) { decode(T.self, $0) }.compactMap { $0 }
    }

    /// True once a complete album listing has been mirrored.
    public var isPopulated: Bool { meta("lastFullSync") != nil }

    /// End of the last complete library listing.
    public var lastFullSync: Date? { meta("lastFullSync").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }

    public func artists() -> [Artist] {
        read([]) { try decodeAll($0, Artist.self, "SELECT json FROM artists ORDER BY sortName, id") }
    }

    public func albums(sort: AlbumSort = .name, limit: Int? = nil, offset: Int = 0) -> [Album] {
        read([]) { try decodeAll($0, Album.self, "SELECT json FROM albums ORDER BY \(sort.sql) LIMIT ? OFFSET ?", [limit ?? -1, offset]) }
    }

    public func albumCount() -> Int { read(0) { try $0.scalar("SELECT COUNT(*) FROM albums") } }
    public func artistCount() -> Int { read(0) { try $0.scalar("SELECT COUNT(*) FROM artists") } }
    public func songCount() -> Int { read(0) { try $0.scalar("SELECT COUNT(*) FROM songs") } }

    /// The album with its songs ordered by disc and track. Nil when unknown or its songs are not mirrored yet.
    public func album(id: String) -> Album? {
        read(nil) { db in
            guard let album = try db.prepare("SELECT json FROM albums WHERE id = ? AND tracksSyncedAt IS NOT NULL")
                .first([id], { decode(Album.self, $0) }) ?? nil else { return nil }
            let songs = try decodeAll(db, Song.self, """
                SELECT json FROM songs WHERE albumId = ? ORDER BY COALESCE(disc, 1), COALESCE(track, 0), titleKey, id
                """, [id])
            return album.withSongs(songs)
        }
    }

    public func songs(sort: SongSort = .title, limit: Int? = nil, offset: Int = 0) -> [Song] {
        read([]) { try decodeAll($0, Song.self, "SELECT json FROM songs ORDER BY \(sort.sql) LIMIT ? OFFSET ?", [limit ?? -1, offset]) }
    }

    /// Playlists without entries.
    public func playlists() -> [Playlist] {
        read([]) { try decodeAll($0, Playlist.self, "SELECT json FROM playlists ORDER BY name COLLATE NOCASE, id") }
    }

    /// The playlist with its songs in order. Nil when unknown or its entries are not mirrored yet.
    public func playlist(id: String) -> Playlist? {
        read(nil) { db in
            guard let playlist = try db.prepare("SELECT json FROM playlists WHERE id = ? AND entriesSyncedAt IS NOT NULL")
                .first([id], { decode(Playlist.self, $0) }) ?? nil else { return nil }
            let songs = try decodeAll(db, Song.self, """
                SELECT s.json FROM playlist_entries e JOIN songs s ON s.id = e.songId WHERE e.playlistId = ? ORDER BY e.position
                """, [id])
            return playlist.withEntries(songs)
        }
    }

    /// Prefix search over names; every word must match. Handles Cyrillic and ignores case and diacritics.
    public func search(_ query: String, limit: Int = 30) -> SearchResult3 {
        guard let match = ftsQuery(query) else { return SearchResult3(artist: [], album: [], song: []) }
        func find<T: Decodable>(_ db: SQLiteConnection, _ type: T.Type, _ table: String) throws -> [T] {
            try decodeAll(db, type, """
                SELECT t.json FROM \(table)_fts f JOIN \(table) t ON t.rowid = f.rowid WHERE \(table)_fts MATCH ? ORDER BY f.rank LIMIT ?
                """, [match, limit])
        }
        return read(SearchResult3(artist: [], album: [], song: [])) {
            SearchResult3(artist: try find($0, Artist.self, "artists"), album: try find($0, Album.self, "albums"),
                          song: try find($0, Song.self, "songs"))
        }
    }

    /// Best lyrics for the song (synced preferred). Nil when none were mirrored or the server has none.
    public func lyrics(songId: String) -> StructuredLyrics? {
        read(nil) { db in
            let list = try db.prepare("SELECT json FROM lyrics WHERE songId = ? AND status = 'found'")
                .first([songId], { decode([StructuredLyrics].self, $0) }) ?? nil
            return list?.first { $0.synced } ?? list?.first
        }
    }

    /// Stored lyrics list: nil = not asked yet (or an old "none"), empty = the server has none.
    public func storedLyrics(songId: String) -> [StructuredLyrics]? {
        let cutoff = Date().timeIntervalSince1970 - Self.retryAfter
        return read(nil) { db in
            try db.prepare("SELECT json FROM lyrics WHERE songId = ? AND (status = 'found' OR fetchedAt > ?)")
                .first([songId, cutoff], { $0.text(0) == nil ? [] : decode([StructuredLyrics].self, $0) ?? [] })
        }
    }

    /// Local thumbnail file. A missing file removes its record, so the mirror fetches it again.
    public func smallCoverURL(coverArtId: String) -> URL? {
        let name = read(nil) { db in
            try db.prepare("SELECT path FROM covers WHERE coverArtId = ? AND size = ? AND path IS NOT NULL")
                .first([coverArtId, Self.smallCoverSize]) { $0.text(0) } ?? nil
        }
        guard let name else { return nil }
        let url = coversDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? write { try $0.run("DELETE FROM covers WHERE coverArtId = ? AND size = ?", [coverArtId, Self.smallCoverSize]) }
        return nil
    }
}
