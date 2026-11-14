import Foundation

/// Artist biography, images and similar artists (`getArtistInfo2`). Navidrome fills them from its agents (Last.fm, Spotify).
public struct ArtistInfo: Codable, Hashable, Sendable {
    public let biography: String?
    public let largeImageUrl: String?
    public let mediumImageUrl: String?
    public let similarArtist: [Artist]?
}

/// One genre with the server's counts (`getGenres`).
public struct Genre: Codable, Hashable, Sendable {
    public let value: String
    public let songCount: Int?
    public let albumCount: Int?
}

/// An internet radio station (`getInternetRadioStations`).
public struct RadioStation: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let streamUrl: String
    public let homePageUrl: String?

    public init(id: String, name: String, streamUrl: String, homePageUrl: String? = nil) {
        self.id = id
        self.name = name
        self.streamUrl = streamUrl
        self.homePageUrl = homePageUrl
    }
}

/// The roles of a user that change what the app offers.
public struct User: Codable, Hashable, Sendable {
    public let username: String
    public let adminRole: Bool?
    public let podcastRole: Bool?
}

struct GenresBody: Decodable, Sendable { let genre: [Genre]? }
struct RadioBody: Decodable, Sendable { let internetRadioStation: [RadioStation]? }

public extension SubsonicClient {
    func getArtistInfo2(id: String, count: Int = 20) async throws -> ArtistInfo? {
        try await request("getArtistInfo2", key: "artistInfo2", [("id", id), ("count", String(count))])
    }

    func getGenres() async throws -> [Genre] {
        let body: GenresBody? = try await request("getGenres", key: "genres")
        return body?.genre ?? []
    }

    func getSongsByGenre(_ genre: String, count: Int = 50, offset: Int = 0) async throws -> [Song] {
        let body: SongsBody? = try await request("getSongsByGenre", key: "songsByGenre",
                                                 [("genre", genre), ("count", String(count)), ("offset", String(offset))])
        return body?.song ?? []
    }

    func getUser(username: String) async throws -> User {
        try await fetch("getUser", "user", [("username", username)])
    }

    func getInternetRadioStations() async throws -> [RadioStation] {
        let body: RadioBody? = try await request("getInternetRadioStations", key: "internetRadioStations")
        return body?.internetRadioStation ?? []
    }

    /// Admins only.
    func createInternetRadioStation(name: String, streamUrl: String, homePageUrl: String?) async throws {
        _ = try await request("createInternetRadioStation", key: nil, radioQuery(name, streamUrl, homePageUrl)) as Empty?
    }

    func updateInternetRadioStation(id: String, name: String, streamUrl: String, homePageUrl: String?) async throws {
        _ = try await request("updateInternetRadioStation", key: nil, [("id", id)] + radioQuery(name, streamUrl, homePageUrl)) as Empty?
    }

    func deleteInternetRadioStation(id: String) async throws {
        _ = try await request("deleteInternetRadioStation", key: nil, [("id", id)]) as Empty?
    }

    private func radioQuery(_ name: String, _ streamUrl: String, _ homePageUrl: String?) -> [(String, String)] {
        [("name", name), ("streamUrl", streamUrl)] + (homePageUrl.map { [("homepageUrl", $0)] } ?? [])
    }
}

public extension ArtistInfo {
    /// The biography as plain text: no HTML tags, no "Read more on Last.fm" link, entities decoded, one space between words.
    var plainBiography: String? {
        guard let biography else { return nil }
        let text = Self.plain(biography)
        return text.isEmpty ? nil : text
    }

    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<a\b[^>]*>.*?</a>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<br\s*/?>|</p>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&amp;": "&"]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        let paragraphs = text.components(separatedBy: "\n").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
