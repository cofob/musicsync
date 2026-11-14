import Foundation
import Subsonic

/// Windowed reads for long lists (Songs, Albums, Artists): one page and the total, narrowed by an optional search.
extension LibraryDatabase {
    public func songs(sort: SongSort, descending: Bool = false, matching query: String, limit: Int, offset: Int) -> [Song] {
        page(Song.self, "songs", order: descending ? Self.reversed(sort.terms) : sort.sql, query, limit, offset)
    }

    public func albums(sort: AlbumSort, matching query: String, limit: Int, offset: Int) -> [Album] {
        page(Album.self, "albums", order: sort.sql, query, limit, offset)
    }

    public func artists(matching query: String, limit: Int, offset: Int) -> [Artist] {
        page(Artist.self, "artists", order: "sortName, id", query, limit, offset)
    }

    public func songCount(matching query: String) -> Int { count("songs", query) }
    public func albumCount(matching query: String) -> Int { count("albums", query) }
    public func artistCount(matching query: String) -> Int { count("artists", query) }

    private func page<T: Decodable>(_ type: T.Type, _ table: String, order: String, _ query: String, _ limit: Int, _ offset: Int) -> [T] {
        let (filter, params) = Self.filter(table, query)
        return read([]) { try decodeAll($0, type, "SELECT json FROM \(table) \(filter) ORDER BY \(order) LIMIT ? OFFSET ?", params + [limit, offset]) }
    }

    private func count(_ table: String, _ query: String) -> Int {
        let (filter, params) = Self.filter(table, query)
        return read(0) { try $0.scalar("SELECT COUNT(*) FROM \(table) \(filter)", params) }
    }

    /// Same word-prefix match as `search(_:)`; empty when the query has no words.
    private static func filter(_ table: String, _ query: String) -> (String, [any SQLConvertible]) {
        guard let match = ftsQuery(query) else { return ("", []) }
        return ("WHERE rowid IN (SELECT rowid FROM \(table)_fts WHERE \(table)_fts MATCH ?)", [match])
    }

    /// ["a", "b DESC"] -> "a DESC, b".
    static func reversed(_ terms: [String]) -> String {
        terms.map { $0.hasSuffix(" DESC") ? String($0.dropLast(5)) : $0 + " DESC" }.joined(separator: ", ")
    }
}
