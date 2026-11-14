import Foundation

/// A library song as the recommender sees it.
public struct Track: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let albumId: String?
    /// Genre keys (`GenreName.key`).
    public let genres: [String]
    /// The genres as tagged, for display.
    let genreNames: [String]
    public let year: Int?
    public let duration: Int?
    public let starred: Bool
    /// 0 (none) to 5.
    public let rating: Int
    public let serverPlays: Int
    public let created: Date?
    /// Last play the server knows of (album level); a hint when there is no local history.
    public let lastPlayed: Date?
    /// Lowercased artist and album artist, for "same artist" checks.
    let artistKeys: Set<String>

    public init(id: String, title: String, artist: String?, albumArtist: String? = nil, albumId: String? = nil, genre: String? = nil,
                year: Int? = nil, duration: Int? = nil, starred: Bool = false, rating: Int = 0, serverPlays: Int = 0,
                created: Date? = nil, lastPlayed: Date? = nil) {
        self.id = id
        self.title = title
        self.artist = artist ?? ""
        self.albumId = albumId
        genreNames = GenreName.split(genre)
        genres = genreNames.map(GenreName.key)
        self.year = year
        self.duration = duration
        self.starred = starred
        self.rating = rating
        self.serverPlays = serverPlays
        self.created = created
        self.lastPlayed = lastPlayed
        artistKeys = Set([artist, albumArtist].compactMap { $0.map(Self.key) }.filter { !$0.isEmpty })
    }

    static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// What started a play; plays the app chose itself (mixes, radio) say less about taste.
public enum PlaySource: String, Sendable, CaseIterable {
    case album, playlist, mix, radio, other
}

/// One listening event.
public struct PlayEvent: Sendable, Hashable {
    public let songId: String
    public let startedAt: Date
    /// Seconds actually listened (seeks do not count).
    public let played: Double
    /// Track length in seconds; 0 when unknown.
    public let duration: Double
    public let source: PlaySource

    public init(songId: String, startedAt: Date, played: Double, duration: Double, source: PlaySource = .other) {
        self.songId = songId
        self.startedAt = startedAt
        self.played = played
        self.duration = duration
        self.source = source
    }

    /// The scrobble rule of the player: half the track or 4 minutes, whichever comes first.
    public var completed: Bool { duration > 0 && played >= min(duration / 2, 240) }
    public var skipped: Bool { !completed }
}

/// Per-song numbers derived from the local history.
public struct SongStats: Sendable, Hashable {
    public var plays: Int
    public var skips: Int
    public var lastPlayed: Date?
    /// Mean share of the track listened to, 0...1.
    public var completion: Double

    public init(plays: Int = 0, skips: Int = 0, lastPlayed: Date? = nil, completion: Double = 1) {
        self.plays = plays
        self.skips = skips
        self.lastPlayed = lastPlayed
        self.completion = completion
    }

    /// Share of skipped plays; 0 until there are two events, so one accidental skip does not count.
    var skipRatio: Double { plays + skips < 2 ? 0 : Double(skips) / Double(plays + skips) }
}
