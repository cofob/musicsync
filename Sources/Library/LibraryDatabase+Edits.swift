import Foundation
import Subsonic

/// Local copies of the user's own changes (stars, ratings, playlists), so lists show them before the next mirror pass.
extension LibraryDatabase {
    /// Sets the star date (nil: not starred) of songs, albums and artists.
    public func setStarred(_ date: String?, songIds: [String] = [], albumIds: [String] = [], artistIds: [String] = []) throws {
        try write { db in
            for (table, ids) in [("songs", songIds), ("albums", albumIds), ("artists", artistIds)] {
                for id in ids { try Self.setStar(db, table, id: id, date) }
            }
        }
    }

    /// 0 removes the rating.
    public func setRating(_ rating: Int, songId: String) throws {
        try write { try $0.run("UPDATE songs SET json = json_set(json, '$.userRating', ?) WHERE id = ?", [rating, songId]) }
    }

    /// Stores a playlist as the server sent it. With entries they replace the stored ones; without, the mirror fetches them.
    public func storePlaylist(_ p: Playlist) throws {
        let row = try json(p.withEntries(nil))
        try write { db in
            try db.run("""
                INSERT INTO playlists(id, name, songCount, duration, created, changed, fingerprint, entriesSyncedAt, json)
                VALUES(?, ?, ?, ?, ?, ?, ?, NULL, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, songCount = excluded.songCount, duration = excluded.duration,
                  created = excluded.created, changed = excluded.changed, fingerprint = excluded.fingerprint,
                  entriesSyncedAt = NULL, json = excluded.json
                """, [p.id, p.name, p.songCount, p.duration, p.created, p.changed, Self.fingerprint(p), row])
        }
        if let entries = p.entry { try storePlaylistEntries(playlistId: p.id, songs: entries) }
    }

    public func deletePlaylist(id: String) throws {
        try write { try $0.run("DELETE FROM playlists WHERE id = ?", [id]) }  // entries cascade
    }

    /// Starred artists, albums and songs, most recently starred first.
    public func starred() -> SearchResult3 {
        func list<T: Decodable>(_ db: SQLiteConnection, _ type: T.Type, _ table: String) throws -> [T] {
            let column = Self.starColumn(table)
            return try decodeAll(db, type, "SELECT json FROM \(table) WHERE \(column) IS NOT NULL ORDER BY \(column) DESC, id")
        }
        return read(SearchResult3(artist: [], album: [], song: [])) {
            SearchResult3(artist: try list($0, Artist.self, "artists"), album: try list($0, Album.self, "albums"),
                          song: try list($0, Song.self, "songs"))
        }
    }

    /// Mirror phase: makes the stored stars match `getStarred2`. Only rows that change are written.
    func replaceStarred(_ starred: SearchResult3) throws {
        let lists = [("songs", starred.song.map { ($0.id, $0.starred ?? "") }),
                     ("albums", starred.album.map { ($0.id, $0.starred ?? "") }),
                     ("artists", starred.artist.map { ($0.id, $0.starred ?? "") })]
        try write { db in
            for (table, items) in lists {
                let wanted = Dictionary(items) { a, _ in a }
                let column = Self.starColumn(table)
                let stored = Dictionary(try db.rows("SELECT id, \(column) FROM \(table) WHERE \(column) IS NOT NULL", []) {
                    ($0.text(0)!, $0.text(1) ?? "")
                }) { a, _ in a }
                for id in stored.keys where wanted[id] == nil { try Self.setStar(db, table, id: id, nil) }
                for (id, date) in wanted where stored[id] != date { try Self.setStar(db, table, id: id, date) }
            }
        }
    }

    /// Songs keep the star date in a column too (for sorting); albums and artists only in their JSON.
    private static func starColumn(_ table: String) -> String {
        table == "songs" ? "starred" : "json_extract(json, '$.starred')"
    }

    private static func setStar(_ db: SQLiteConnection, _ table: String, id: String, _ date: String?) throws {
        let column = table == "songs" ? "starred = ?1, " : ""
        try db.run("UPDATE \(table) SET \(column)json = json_set(json, '$.starred', ?1) WHERE id = ?2", [date, id])
    }
}
