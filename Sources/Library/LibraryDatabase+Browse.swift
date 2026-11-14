import Foundation
import Recommend
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

extension GenreSummary {
    /// One summary per genre: tags are split, spellings merged under the most common one.
    /// `albums`: genre tag, a cover (the most played first) and how many albums the row stands for. `songs`: songs per genre tag.
    public static func grouped(albums: [(genre: String, cover: String?, count: Int)], songs: [(genre: String, count: Int)]) -> [GenreSummary] {
        var spellings: [String: Int] = [:], albumCounts: [String: Int] = [:], songCounts: [String: Int] = [:], covers: [String: [String]] = [:]
        for album in albums {
            for name in GenreName.split(album.genre) {
                let key = GenreName.key(name)
                spellings[name, default: 0] += album.count
                albumCounts[key, default: 0] += album.count
                if let cover = album.cover, !cover.isEmpty, covers[key, default: []].count < 4 { covers[key, default: []].append(cover) }
            }
        }
        for song in songs {
            for name in GenreName.split(song.genre) {
                spellings[name, default: 0] += song.count
                songCounts[GenreName.key(name), default: 0] += song.count
            }
        }
        return GenreName.displayNames(spellings).compactMap { key, name in
            albumCounts[key].flatMap { $0 == 0 ? nil : GenreSummary(name: name, albumCount: $0, songCount: songCounts[key] ?? 0, covers: covers[key] ?? []) }
        }
        .sorted { ($0.albumCount, $1.name) > ($1.albumCount, $0.name) }
    }
}

/// Reads for the artist, genre and album pages.
extension LibraryDatabase {
    /// Genres of the albums, the most albums first. Spellings of one genre are merged.
    public func genres() -> [GenreSummary] {
        read([]) { db in
            let albums = try db.rows("""
                SELECT genre, coverArt FROM albums WHERE genre IS NOT NULL AND genre != '' ORDER BY playCount DESC, sortName
                """) { (genre: $0.text(0) ?? "", cover: $0.text(1), count: 1) }
            let songs = try db.rows("""
                SELECT json_extract(json, '$.genre') g, COUNT(*) FROM songs WHERE g IS NOT NULL AND g != '' GROUP BY g
                """) { (genre: $0.text(0) ?? "", count: $0.int(1)) }
            return GenreSummary.grouped(albums: albums, songs: songs)
        }
    }

    /// Albums of a genre, any spelling, the newest release first.
    public func albums(genre: String) -> [Album] {
        read([]) { db in
            let tags = try matchingTags(db, "SELECT DISTINCT genre FROM albums WHERE genre IS NOT NULL", genre)
            return try decodeAll(db, Album.self, """
                SELECT json FROM albums WHERE genre IN (SELECT value FROM json_each(?)) ORDER BY COALESCE(year, 0) DESC, sortName, id
                """, [tags])
        }
    }

    /// Songs of a genre, any spelling, the most played first.
    public func songs(genre: String, limit: Int? = nil) -> [Song] {
        read([]) { db in
            let tags = try matchingTags(db, "SELECT DISTINCT json_extract(json, '$.genre') g FROM songs WHERE g IS NOT NULL", genre)
            return try decodeAll(db, Song.self, """
                SELECT json FROM songs WHERE json_extract(json, '$.genre') IN (SELECT value FROM json_each(?))
                ORDER BY playCount DESC, titleKey, id LIMIT ?
                """, [tags, limit ?? -1])
        }
    }

    /// The tags from `sql` that contain `genre` in any spelling, as a JSON array for `json_each`.
    private func matchingTags(_ db: SQLiteConnection, _ sql: String, _ genre: String) throws -> String {
        let key = GenreName.key(genre)
        let tags = try db.rows(sql) { $0.text(0) ?? "" }.filter { GenreName.split($0).contains { GenreName.key($0) == key } }
        return String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)
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
