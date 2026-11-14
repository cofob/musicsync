import Foundation

/// One lyric line. `start` is in milliseconds and only present in synced lyrics.
public struct LyricLine: Codable, Hashable, Sendable {
    public let start: Int?
    public let value: String
}

/// OpenSubsonic `songLyrics` extension: lyrics of one language and kind.
public struct StructuredLyrics: Codable, Hashable, Sendable {
    public let displayArtist: String?
    public let displayTitle: String?
    public let lang: String?
    /// Offset in milliseconds to add to every `start`.
    public let offset: Int?
    public let synced: Bool
    public let line: [LyricLine]
}

/// Plain lyrics from the legacy `getLyrics` call.
public struct LegacyLyrics: Codable, Hashable, Sendable {
    public let artist: String?
    public let title: String?
    public let value: String?
}

struct LyricsListBody: Decodable { let structuredLyrics: [StructuredLyrics]? }

public extension SubsonicClient {
    /// Empty when the song has no lyrics. Needs the `songLyrics` server extension.
    func getLyricsBySongId(id: String) async throws -> [StructuredLyrics] {
        try await (fetch("getLyricsBySongId", "lyricsList", [("id", id)]) as LyricsListBody).structuredLyrics ?? []
    }

    /// Legacy plain-text lyrics lookup.
    func getLyrics(artist: String, title: String) async throws -> LegacyLyrics {
        try await fetch("getLyrics", "lyrics", [("artist", artist), ("title", title)])
    }

    /// Starred artists, albums and songs.
    func getStarred2() async throws -> SearchResult3 {
        try await fetch("getStarred2", "starred2")
    }
}
