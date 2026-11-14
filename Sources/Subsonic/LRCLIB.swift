import Foundation

/// Lookup on lrclib.net, a public lyrics database. Sends only the artist, title, album and length of one song.
public struct LRCLIBClient: Sendable {
    /// Generic, so the request says nothing about the user.
    public static let userAgent = "MusicSync (https://github.com/cofob/musicsync)"
    /// The source name stored with the lyrics and shown under them.
    public static let source = "LRCLIB"

    let session: URLSession
    let base: URL

    /// Without cookies or a cache.
    public init(session: URLSession = URLSession(configuration: .ephemeral), base: URL = URL(string: "https://lrclib.net")!) {
        self.session = session
        self.base = base
    }

    /// Synced lyrics if LRCLIB has them, else plain ones; nil when it has none.
    public func lyrics(artist: String, title: String, album: String?, duration: Int?) async throws -> StructuredLyrics? {
        var parts = URLComponents(url: base.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title)]
            + (album.map { [URLQueryItem(name: "album_name", value: $0)] } ?? [])
            + (duration.map { [URLQueryItem(name: "duration", value: String($0))] } ?? [])
        guard let url = parts?.url else { throw SubsonicError.badResponse("bad LRCLIB address") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw SubsonicError.badStatus(status) }
        return try Self.decode(data)
    }

    struct Record: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Lyrics in a `/api/get` reply; nil for an instrumental or an empty record.
    public static func decode(_ data: Data) throws -> StructuredLyrics? {
        let record = try JSONDecoder().decode(Record.self, from: data)
        if record.instrumental == true { return nil }
        return record.syncedLyrics.flatMap(LRC.parse) ?? record.plainLyrics.flatMap(LRC.plain)
    }
}
