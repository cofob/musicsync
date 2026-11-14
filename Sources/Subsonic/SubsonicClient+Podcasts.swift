import Foundation

/// A podcast the server follows. Navidrome has no podcasts; Airsonic, Gonic and others do.
public struct PodcastChannel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let url: String?
    public let title: String?
    public let description: String?
    public let coverArt: String?
    public let originalImageUrl: String?
    /// "new", "downloading", "completed", "error", "deleted" or "skipped".
    public let status: String?
    public let errorMessage: String?
    /// Present when asked for with `includeEpisodes`.
    public let episode: [PodcastEpisode]?

    public var name: String { title ?? url ?? "Podcast" }
    public var episodes: [PodcastEpisode] { episode ?? [] }
}

public struct PodcastEpisode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// Id to stream; only set once the server downloaded the episode.
    public let streamId: String?
    public let channelId: String?
    public let title: String?
    public let description: String?
    public let publishDate: String?
    /// "new" (not on the server yet), "downloading", "completed", "error", "deleted" or "skipped".
    public let status: String?
    public let duration: Int?
    public let coverArt: String?
    public let album: String?
    public let artist: String?
    public let year: Int?
    public let genre: String?
    public let size: Int?
    public let suffix: String?
    public let contentType: String?
    public let bitRate: Int?
    public let playCount: Int?

    public var name: String { title ?? "Episode" }

    public var date: Date? { publishDate.flatMap(isoDate) }

    /// The episode as a song for the player; nil while the server has no file for it.
    public var song: Song? {
        guard let streamId, !streamId.isEmpty else { return nil }
        return Song(id: streamId, parent: channelId, title: name, album: album, albumId: nil, artist: artist, artistId: nil,
                    albumArtist: nil, displayArtist: nil, displayAlbumArtist: nil, track: nil, discNumber: nil, year: year,
                    genre: genre, size: size, suffix: suffix, contentType: contentType, duration: duration, bitRate: bitRate,
                    bitDepth: nil, samplingRate: nil, channelCount: nil, coverArt: coverArt, playCount: playCount, userRating: nil,
                    starred: nil, replayGain: nil, created: publishDate, musicBrainzId: nil, path: nil)
    }
}

/// A saved play position of the user.
public struct Bookmark: Codable, Hashable, Sendable {
    /// Milliseconds into `entry`.
    public let position: Int
    public let username: String?
    public let comment: String?
    public let created: String?
    public let changed: String?
    public let entry: Song
}

/// Servers send fractions of a second (Navidrome: nanoseconds) or none.
func isoDate(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

struct PodcastsBody: Decodable, Sendable { let channel: [PodcastChannel]? }
struct NewestPodcastsBody: Decodable, Sendable { let episode: [PodcastEpisode]? }
struct BookmarksBody: Decodable, Sendable { let bookmark: [Bookmark]? }

public extension SubsonicClient {
    /// A server without podcasts answers with an error (Navidrome: HTTP 501, others: API error 50 or 70).
    func getPodcasts(includeEpisodes: Bool = true, id: String? = nil) async throws -> [PodcastChannel] {
        var query = [("includeEpisodes", includeEpisodes ? "true" : "false")]
        if let id { query.append(("id", id)) }
        let body: PodcastsBody? = try await request("getPodcasts", key: "podcasts", query)
        return body?.channel ?? []
    }

    func getNewestPodcasts(count: Int = 20) async throws -> [PodcastEpisode] {
        let body: NewestPodcastsBody? = try await request("getNewestPodcasts", key: "newestPodcasts", [("count", String(count))])
        return body?.episode ?? []
    }

    /// Needs the podcast role.
    func createPodcastChannel(url: String) async throws {
        _ = try await request("createPodcastChannel", key: nil, [("url", url)]) as Empty?
    }

    func deletePodcastChannel(id: String) async throws {
        _ = try await request("deletePodcastChannel", key: nil, [("id", id)]) as Empty?
    }

    /// Makes the server look for new episodes of all channels.
    func refreshPodcasts() async throws {
        _ = try await request("refreshPodcasts", key: nil) as Empty?
    }

    /// Makes the server download the episode; it can stream it afterwards.
    func downloadPodcastEpisode(id: String) async throws {
        _ = try await request("downloadPodcastEpisode", key: nil, [("id", id)]) as Empty?
    }

    func deletePodcastEpisode(id: String) async throws {
        _ = try await request("deletePodcastEpisode", key: nil, [("id", id)]) as Empty?
    }

    func getBookmarks() async throws -> [Bookmark] {
        let body: BookmarksBody? = try await request("getBookmarks", key: "bookmarks")
        return body?.bookmark ?? []
    }

    /// `position` is in milliseconds. One bookmark per item: a new one replaces the old.
    func createBookmark(id: String, position: Int, comment: String? = nil) async throws {
        var query = [("id", id), ("position", String(position))]
        if let comment { query.append(("comment", comment)) }
        _ = try await request("createBookmark", key: nil, query) as Empty?
    }

    func deleteBookmark(id: String) async throws {
        _ = try await request("deleteBookmark", key: nil, [("id", id)]) as Empty?
    }
}
