import Foundation
import Recommend
import Subsonic

/// Input for the recommender (`Recommend.Catalog`).
extension LibraryDatabase {
    /// Every mirrored song, with its album's last play as a hint for songs the local history has not seen.
    public func recommendationTracks() -> [Track] {
        read([]) { db in
            try db.rows("SELECT s.json, json_extract(a.json, '$.played') FROM songs s LEFT JOIN albums a ON a.id = s.albumId") { row in
                decode(Song.self, row).map { Track($0, albumPlayed: row.text(1).flatMap(parseDate)) }
            }.compactMap { $0 }
        }
    }

    /// The songs with these ids, in this order; unknown ids are left out.
    public func songs(ids: [String]) -> [Song] {
        read([]) { db in
            let lookup = try db.prepare("SELECT json FROM songs WHERE id = ?")
            return try ids.compactMap { try lookup.first([$0]) { decode(Song.self, $0) } ?? nil }
        }
    }

    /// Song ids of each mirrored playlist, in playlist order.
    public func playlistMembers() -> [[String]] {
        read([]) { db in
            let rows = try db.rows("SELECT playlistId, songId FROM playlist_entries ORDER BY playlistId, position") { ($0.text(0) ?? "", $0.text(1) ?? "") }
            var lists: [[String]] = [], last: String?
            for (playlist, song) in rows {
                if playlist != last { lists.append([]); last = playlist }
                lists[lists.count - 1].append(song)
            }
            return lists
        }
    }
}

extension Track {
    init(_ song: Song, albumPlayed: Date?) {
        self.init(id: song.id, title: song.title, artist: song.artistName, albumArtist: song.displayAlbumArtist ?? song.albumArtist,
                  albumId: song.albumId, genre: song.genre, year: song.year, duration: song.duration, starred: song.starred != nil,
                  rating: song.userRating ?? 0, serverPlays: song.playCount ?? 0, created: song.created.flatMap(parseDate),
                  lastPlayed: albumPlayed)
    }
}

/// Server dates, with or without fractional seconds.
func parseDate(_ text: String) -> Date? {
    (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
}
