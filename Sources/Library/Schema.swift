/// Database layout. Bump `version` on any change: an older file is replaced, not migrated,
/// because everything in it can be fetched from the server again.
enum Schema {
    static let version = 1

    static let statements: [String] = [
        "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",

        """
        CREATE TABLE artists(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, sortName TEXT NOT NULL, albumCount INTEGER,
          seen TEXT, json TEXT NOT NULL)
        """,
        "CREATE INDEX artists_sort ON artists(sortName)",

        """
        CREATE TABLE albums(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, artist TEXT, artistId TEXT, year INTEGER, genre TEXT,
          created TEXT, songCount INTEGER, duration INTEGER, coverArt TEXT,
          sortName TEXT NOT NULL, artistKey TEXT NOT NULL, playCount INTEGER NOT NULL DEFAULT 0,
          fingerprint TEXT NOT NULL, tracksSyncedAt REAL, seen TEXT, json TEXT NOT NULL)
        """,
        "CREATE INDEX albums_sort ON albums(sortName)",
        "CREATE INDEX albums_artist ON albums(artistKey, year)",
        "CREATE INDEX albums_created ON albums(created)",
        "CREATE INDEX albums_plays ON albums(playCount)",
        "CREATE INDEX albums_cover ON albums(coverArt)",

        """
        CREATE TABLE songs(
          id TEXT PRIMARY KEY, albumId TEXT, title TEXT NOT NULL, artist TEXT, album TEXT, track INTEGER, disc INTEGER,
          duration INTEGER, suffix TEXT, bitRate INTEGER, created TEXT, playCount INTEGER NOT NULL DEFAULT 0, starred TEXT,
          titleKey TEXT NOT NULL, artistKey TEXT NOT NULL, albumKey TEXT NOT NULL, json TEXT NOT NULL)
        """,
        "CREATE INDEX songs_album ON songs(albumId, disc, track)",
        "CREATE INDEX songs_title ON songs(titleKey)",
        "CREATE INDEX songs_artist ON songs(artistKey, albumKey)",
        "CREATE INDEX songs_created ON songs(created)",
        "CREATE INDEX songs_plays ON songs(playCount)",

        """
        CREATE TABLE playlists(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, songCount INTEGER, duration INTEGER, created TEXT, changed TEXT,
          fingerprint TEXT NOT NULL, entriesSyncedAt REAL, seen TEXT, json TEXT NOT NULL)
        """,
        """
        CREATE TABLE playlist_entries(
          playlistId TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, position INTEGER NOT NULL,
          songId TEXT NOT NULL, PRIMARY KEY(playlistId, position)) WITHOUT ROWID
        """,

        // status: "found" or "none" (the server has no lyrics; avoids asking again).
        """
        CREATE TABLE lyrics(
          songId TEXT PRIMARY KEY, status TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0, json TEXT,
          fetchedAt REAL NOT NULL) WITHOUT ROWID
        """,
        // path is a file name inside the covers directory; NULL records a failed fetch.
        """
        CREATE TABLE covers(
          coverArtId TEXT NOT NULL, size INTEGER NOT NULL, path TEXT, fetchedAt REAL NOT NULL,
          PRIMARY KEY(coverArtId, size)) WITHOUT ROWID
        """,
    ] + fts(table: "artists", columns: ["name"])
      + fts(table: "albums", columns: ["name", "artist"])
      + fts(table: "songs", columns: ["title", "artist", "album"])

    /// Tables added after version 1, created on every open, so an existing library is kept.
    /// external_lyrics: lyrics from other sources than the server (json NULL = that source has none).
    static let additions = [
        """
        CREATE TABLE IF NOT EXISTS external_lyrics(
          songId TEXT NOT NULL, source TEXT NOT NULL, json TEXT, fetchedAt REAL NOT NULL,
          PRIMARY KEY(songId, source)) WITHOUT ROWID
        """,
    ]

    /// External-content FTS5 index kept in sync by triggers. Upserts must use `ON CONFLICT DO UPDATE`
    /// (not `REPLACE`) so the rowid stays stable.
    private static func fts(table: String, columns: [String]) -> [String] {
        let list = columns.joined(separator: ", ")
        let new = columns.map { "new.\($0)" }.joined(separator: ", ")
        let old = columns.map { "old.\($0)" }.joined(separator: ", ")
        let remove = "INSERT INTO \(table)_fts(\(table)_fts, rowid, \(list)) VALUES('delete', old.rowid, \(old));"
        let add = "INSERT INTO \(table)_fts(rowid, \(list)) VALUES(new.rowid, \(new));"
        return [
            "CREATE VIRTUAL TABLE \(table)_fts USING fts5(\(list), content='\(table)', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')",
            "CREATE TRIGGER \(table)_ai AFTER INSERT ON \(table) BEGIN \(add) END",
            "CREATE TRIGGER \(table)_ad AFTER DELETE ON \(table) BEGIN \(remove) END",
            "CREATE TRIGGER \(table)_au AFTER UPDATE ON \(table) BEGIN \(remove) \(add) END",
        ]
    }
}
