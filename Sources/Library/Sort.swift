import Foundation

public enum AlbumSort: Sendable {
    case name, artist
    /// Newest release year first.
    case year
    /// Recently added first.
    case newest
    case mostPlayed

    var sql: String {
        switch self {
        case .name: "sortName, id"
        case .artist: "artistKey, COALESCE(year, 0), sortName, id"
        case .year: "COALESCE(year, 0) DESC, sortName, id"
        case .newest: "COALESCE(created, '') DESC, id"
        case .mostPlayed: "playCount DESC, sortName, id"
        }
    }
}

public enum SongSort: Sendable {
    case title, artist, album, duration
    /// Recently added first.
    case newest
    case mostPlayed

    var sql: String { terms.joined(separator: ", ") }

    /// ORDER BY terms, kept apart so a descending sort can flip each one.
    var terms: [String] {
        switch self {
        case .title: ["titleKey", "id"]
        case .artist: ["artistKey", "albumKey", "COALESCE(disc, 1)", "COALESCE(track, 0)", "id"]
        case .album: ["albumKey", "COALESCE(disc, 1)", "COALESCE(track, 0)", "id"]
        case .duration: ["COALESCE(duration, 0)", "titleKey", "id"]
        case .newest: ["COALESCE(created, '') DESC", "id"]
        case .mostPlayed: ["playCount DESC", "titleKey", "id"]
        }
    }
}

/// Case and diacritic insensitive key for sorting ("Café" sorts with "cafe").
func sortKey(_ text: String?) -> String {
    (text ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}

/// FTS5 query matching every word as a prefix, or nil when the text has no words.
func ftsQuery(_ text: String) -> String? {
    let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return words.isEmpty ? nil : words.map { "\"\($0)\"*" }.joined(separator: " ")
}
