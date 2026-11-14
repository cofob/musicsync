import Foundation
import Subsonic

/// A genre of the mirrored library: counts and a few covers for its tile.
public struct GenreSummary: Sendable, Hashable, Identifiable {
    public let name: String
    public let albumCount: Int
    public let songCount: Int
    /// Covers of its most played albums, at most four.
    public let covers: [String]
    public var id: String { name }

    public init(name: String, albumCount: Int, songCount: Int, covers: [String] = []) {
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
        self.covers = covers
    }
}

/// Reads for the artist, genre and album pages.
extension LibraryDatabase {
    /// Genres of the albums, the most albums first.
    public func genres() -> [GenreSummary] {
        read([]) { db in
            let songs = Dictionary(try db.rows("""
                SELECT json_extract(json, '$.genre') g, COUNT(*) FROM songs WHERE g IS NOT NULL AND g != '' GROUP BY g
                """) { ($0.text(0) ?? "", $0.int(1)) }) { a, _ in a }
            let covers = Dictionary(grouping: try db.rows("""
                SELECT genre, coverArt FROM (SELECT genre, coverArt, ROW_NUMBER() OVER (PARTITION BY genre ORDER BY playCount DESC, sortName) r
                  FROM albums WHERE genre IS NOT NULL AND genre != '' AND coverArt IS NOT NULL AND coverArt != '') WHERE r <= 4 ORDER BY genre, r
                """) { ($0.text(0) ?? "", $0.text(1) ?? "") }) { $0.0 }
            return try db.rows("""
                SELECT genre, COUNT(*) n FROM albums WHERE genre IS NOT NULL AND genre != '' GROUP BY genre ORDER BY n DESC, genre
                """) { row in
                let name = row.text(0) ?? ""
                return GenreSummary(name: name, albumCount: row.int(1), songCount: songs[name] ?? 0, covers: covers[name]?.map(\.1) ?? [])
            }
        }
    }

    /// Albums of a genre, the newest release first.
    public func albums(genre: String) -> [Album] {
        read([]) { try decodeAll($0, Album.self, "SELECT json FROM albums WHERE genre = ? ORDER BY COALESCE(year, 0) DESC, sortName, id", [genre]) }
    }

    /// Songs of a genre, the most played first.
    public func songs(genre: String, limit: Int? = nil) -> [Song] {
        read([]) {
            try decodeAll($0, Song.self, "SELECT json FROM songs WHERE json_extract(json, '$.genre') = ? ORDER BY playCount DESC, titleKey, id LIMIT ?",
                          [genre, limit ?? -1])
        }
    }

    /// Every song by the artist, also on albums of others: newest album first, then disc and track.
    public func songs(artistId: String) -> [Song] {
        read([]) {
            try decodeAll($0, Song.self, """
                SELECT s.json FROM songs s LEFT JOIN albums a ON a.id = s.albumId
                WHERE json_extract(s.json, '$.artistId') = ?1 OR a.artistId = ?1
                ORDER BY COALESCE(a.year, 0) DESC, a.sortName, s.albumId, COALESCE(s.disc, 1), COALESCE(s.track, 0), s.id
                """, [artistId])
        }
    }

    /// Albums of other artists (compilations, features) with songs by this artist, the newest first.
    public func appearsOn(artistId: String) -> [Album] {
        read([]) {
            try decodeAll($0, Album.self, """
                SELECT json FROM albums a WHERE COALESCE(a.artistId, '') != ?1 AND EXISTS (
                  SELECT 1 FROM songs s WHERE s.albumId = a.id AND json_extract(s.json, '$.artistId') = ?1)
                ORDER BY COALESCE(a.year, 0) DESC, a.sortName, a.id
                """, [artistId])
        }
    }

    /// Albums of other artists of the same genre or decade; both first, then the most played.
    public func similarAlbums(to album: Album, limit: Int = 20) -> [Album] {
        guard album.genre?.isEmpty == false || album.year != nil else { return [] }
        return read([]) {
            try decodeAll($0, Album.self, """
                SELECT json FROM albums WHERE id != ?1 AND COALESCE(artistId, '') != COALESCE(?2, '')
                  AND (genre = ?3 OR year / 10 = ?4 / 10)
                ORDER BY COALESCE(genre = ?3, 0) + COALESCE(year / 10 = ?4 / 10, 0) DESC, playCount DESC, sortName, id LIMIT ?5
                """, [album.id, album.artistId, album.genre, album.year, limit])
        }
    }
}
