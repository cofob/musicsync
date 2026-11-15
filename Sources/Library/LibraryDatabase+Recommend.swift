import Foundation
import Recommend
import Subsonic

/// Input for the recommender (`Recommend.Catalog`).
extension LibraryDatabase {
    /// Every mirrored song, with its album's last play as a hint for songs the local history has not seen.
    public func recommendationTracks() -> [Track] {
        let fields = ["id", "title", "displayArtist", "artist", "displayAlbumArtist", "albumArtist", "albumId", "genre", "year", "duration",
                      "starred", "userRating", "playCount", "created"].map { "json_extract(s.json, '$.\($0)')" }.joined(separator: ", ")
        return read([]) { db in
            try db.rows("SELECT \(fields), json_extract(a.json, '$.played') FROM songs s LEFT JOIN albums a ON a.id = s.albumId") { row in
                func int(_ i: Int32) -> Int? { row.isNull(i) ? nil : row.int(i) }
                guard let id = row.text(0), let title = row.text(1) else { return nil }
                return Track(id: id, title: title, artist: row.text(2) ?? row.text(3), albumArtist: row.text(4) ?? row.text(5), albumId: row.text(6),
                             genre: row.text(7), year: int(8), duration: int(9), starred: !row.isNull(10), rating: int(11) ?? 0,
                             serverPlays: int(12) ?? 0, created: row.text(13).flatMap(parseDate), lastPlayed: row.text(14).flatMap(parseDate))
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

/// Server dates, with or without fractional seconds.
func parseDate(_ text: String) -> Date? {
    (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
}
