import Foundation
import Subsonic

/// Position of an unfinished album listing, so it can resume after a restart.
struct AlbumCursor: Equatable {
    var run: String
    var offset: Int
    /// Server `lastScan` when the listing began; a listing never spans two scans.
    var scan: String
}

/// Write side, used by the mirror. Every call is one transaction, so a crash never leaves half a batch.
extension LibraryDatabase {
    func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try perform { db in try db.transaction { try body(db) } }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: Artists

    /// Stores the complete artist list and removes artists missing from it (never on an empty list).
    func replaceArtists(_ artists: [Artist]) throws {
        let run = UUID().uuidString
        let rows = try artists.map { ($0, try json($0)) }
        try write { db in
            let upsert = try db.prepare("""
                INSERT INTO artists(id, name, sortName, albumCount, seen, json) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, sortName = excluded.sortName,
                  albumCount = excluded.albumCount, seen = excluded.seen, json = excluded.json
                """)
            for (a, json) in rows { try upsert.run([a.id, a.name, sortKey(a.sortName ?? a.name), a.albumCount, run, json]) }
            if !artists.isEmpty { try db.run("DELETE FROM artists WHERE seen IS NOT ?", [run]) }
        }
    }

    // MARK: Albums

    static func fingerprint(_ a: Album) -> String {
        "\(a.songCount ?? -1)|\(a.duration ?? -1)|\(a.created ?? "")|\(a.name)|\(a.year ?? 0)"
    }

    func albumCursor() -> AlbumCursor? {
        guard let run = meta("albums.run"), let offset = meta("albums.offset").flatMap(Int.init), let scan = meta("albums.scan") else { return nil }
        return AlbumCursor(run: run, offset: offset, scan: scan)
    }

    func beginAlbumListing(_ cursor: AlbumCursor) throws {
        try setMeta(["albums.run": cursor.run, "albums.offset": String(cursor.offset), "albums.scan": cursor.scan])
    }

    /// Stores one page of the album listing and advances the cursor in the same transaction.
    /// Albums whose fingerprint changed become dirty (tracks must be fetched again).
    func storeAlbumPage(_ albums: [Album], run: String, nextOffset: Int) throws {
        let rows = try albums.map { ($0, try json($0.withSongs(nil))) }
        try write { db in
            let upsert = try db.prepare("""
                INSERT INTO albums(id, name, artist, artistId, year, genre, created, songCount, duration, coverArt,
                                   sortName, artistKey, playCount, fingerprint, tracksSyncedAt, seen, json)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, artist = excluded.artist, artistId = excluded.artistId,
                  year = excluded.year, genre = excluded.genre, created = excluded.created, songCount = excluded.songCount,
                  duration = excluded.duration, coverArt = excluded.coverArt, sortName = excluded.sortName,
                  artistKey = excluded.artistKey, playCount = excluded.playCount,
                  tracksSyncedAt = CASE WHEN albums.fingerprint = excluded.fingerprint THEN albums.tracksSyncedAt END,
                  fingerprint = excluded.fingerprint, seen = excluded.seen, json = excluded.json
                """)
            for (a, json) in rows {
                try upsert.run([a.id, a.name, a.artistName, a.artistId, a.year, a.genre, a.created, a.songCount, a.duration,
                                a.coverArt, sortKey(a.sortName ?? a.name), sortKey(a.artistName), a.playCount ?? 0,
                                Self.fingerprint(a), run, json])
            }
            try db.run("INSERT INTO meta(key, value) VALUES('albums.offset', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [String(nextOffset)])
        }
    }

    /// Called after a COMPLETE listing: removes albums (and their songs) not seen in this run, clears the cursor.
    /// Deletes nothing when the listing was empty.
    func finishAlbumListing(run: String) throws {
        try write { db in
            if try db.scalar("SELECT COUNT(*) FROM albums WHERE seen = ?", [run]) > 0 {
                let gone = "SELECT id FROM albums WHERE seen IS NOT ?"
                try db.run("DELETE FROM lyrics WHERE songId IN (SELECT id FROM songs WHERE albumId IN (\(gone)))", [run])
                try db.run("DELETE FROM songs WHERE albumId IN (\(gone))", [run])
                try db.run("DELETE FROM albums WHERE seen IS NOT ?", [run])
            }
            try db.exec("DELETE FROM meta WHERE key IN ('albums.run', 'albums.offset', 'albums.scan')")
        }
    }

    func dirtyAlbumIDs() -> [String] {
        read([]) { try $0.rows("SELECT id FROM albums WHERE tracksSyncedAt IS NULL ORDER BY sortName") { $0.text(0)! } }
    }

    // MARK: Songs

    private static func songSQL(onConflict: String) -> String {
        """
        INSERT INTO songs(id, albumId, title, artist, album, track, disc, duration, suffix, bitRate, created, playCount,
                          starred, titleKey, artistKey, albumKey, json)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) \(onConflict)
        """
    }

    private static let songUpdate = """
        DO UPDATE SET albumId = excluded.albumId, title = excluded.title, artist = excluded.artist, album = excluded.album,
          track = excluded.track, disc = excluded.disc, duration = excluded.duration, suffix = excluded.suffix,
          bitRate = excluded.bitRate, created = excluded.created, playCount = excluded.playCount, starred = excluded.starred,
          titleKey = excluded.titleKey, artistKey = excluded.artistKey, albumKey = excluded.albumKey, json = excluded.json
        """

    private func songParams(_ s: Song, albumId: String?, json: String) -> [any SQLConvertible] {
        [s.id, albumId, s.title, s.artistName, s.album, s.track, s.discNumber, s.duration, s.suffix, s.bitRate, s.created,
         s.playCount ?? 0, s.starred, sortKey(s.title), sortKey(s.artistName), sortKey(s.album), json]
    }

    /// Replaces the songs of one album. An empty reply for an album listed with songs is refused, so a server glitch
    /// cannot wipe local data; the album stays dirty and is retried.
    func storeAlbumTracks(albumId: String, songs: [Song]) throws {
        let rows = try songs.map { ($0, try json($0)) }
        try write { db in
            guard let listed = try db.prepare("SELECT songCount FROM albums WHERE id = ?").first([albumId], { $0.isNull(0) ? 0 : $0.int(0) }) else { return }
            if songs.isEmpty && listed > 0 { throw LibraryError.suspiciousEmpty }
            let upsert = try db.prepare(Self.songSQL(onConflict: Self.songUpdate))
            for (song, json) in rows { try upsert.run(songParams(song, albumId: albumId, json: json)) }
            let keep = Set(songs.map(\.id))
            for id in try db.rows("SELECT id FROM songs WHERE albumId = ?", [albumId], { $0.text(0)! }) where !keep.contains(id) {
                try db.run("DELETE FROM songs WHERE id = ?", [id])
                try db.run("DELETE FROM lyrics WHERE songId = ?", [id])
            }
            try db.run("UPDATE albums SET tracksSyncedAt = ? WHERE id = ?", [now, albumId])
        }
    }

    // MARK: Playlists

    static func fingerprint(_ p: Playlist) -> String {
        // Without `changed` a change cannot be detected, so the playlist is always refreshed.
        p.changed.map { "\($0)|\(p.songCount ?? -1)|\(p.duration ?? -1)" } ?? "volatile-\(UUID().uuidString)"
    }

    /// Stores the complete playlist list and removes playlists missing from it. Playlists with a new
    /// `changed`/size become dirty.
    func replacePlaylists(_ playlists: [Playlist]) throws {
        let run = UUID().uuidString
        let rows = try playlists.map { ($0, try json($0.withEntries(nil))) }
        try write { db in
            let upsert = try db.prepare("""
                INSERT INTO playlists(id, name, songCount, duration, created, changed, fingerprint, entriesSyncedAt, seen, json)
                VALUES(?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, songCount = excluded.songCount, duration = excluded.duration,
                  created = excluded.created, changed = excluded.changed,
                  entriesSyncedAt = CASE WHEN playlists.fingerprint = excluded.fingerprint THEN playlists.entriesSyncedAt END,
                  fingerprint = excluded.fingerprint, seen = excluded.seen, json = excluded.json
                """)
            for (p, json) in rows {
                try upsert.run([p.id, p.name, p.songCount, p.duration, p.created, p.changed, Self.fingerprint(p), run, json])
            }
            try db.run("DELETE FROM playlists WHERE seen IS NOT ?", [run])  // entries cascade
        }
    }

    func dirtyPlaylistIDs() -> [String] {
        read([]) { try $0.rows("SELECT id FROM playlists WHERE entriesSyncedAt IS NULL") { $0.text(0)! } }
    }

    /// Replaces the entries of a playlist. Songs not mirrored yet are added without touching existing ones.
    func storePlaylistEntries(playlistId: String, songs: [Song]) throws {
        let rows = try songs.map { ($0, try json($0)) }
        try write { db in
            guard try db.scalar("SELECT COUNT(*) FROM playlists WHERE id = ?", [playlistId]) > 0 else { return }
            let add = try db.prepare(Self.songSQL(onConflict: "DO NOTHING"))
            let entry = try db.prepare("INSERT INTO playlist_entries(playlistId, position, songId) VALUES(?, ?, ?)")
            try db.run("DELETE FROM playlist_entries WHERE playlistId = ?", [playlistId])
            for (position, (song, json)) in rows.enumerated() {
                try add.run(songParams(song, albumId: song.albumId, json: json))
                try entry.run([playlistId, position, song.id])
            }
            try db.run("UPDATE playlists SET entriesSyncedAt = ? WHERE id = ?", [now, playlistId])
        }
    }
}
