import Foundation

/// Server-side recommendations. Navidrome answers them only with an external agent (Last.fm) set up;
/// without one the lists are empty, so callers treat them as a bonus signal.
public extension SubsonicClient {
    func getSimilarSongs2(id: String, count: Int = 50) async throws -> [Song] {
        let body: SongsBody? = try await request("getSimilarSongs2", key: "similarSongs2", [("id", id), ("count", String(count))])
        return body?.song ?? []
    }

    func getTopSongs(artist: String, count: Int = 50) async throws -> [Song] {
        let body: SongsBody? = try await request("getTopSongs", key: "topSongs", [("artist", artist), ("count", String(count))])
        return body?.song ?? []
    }
}

struct SongsBody: Decodable, Sendable { let song: [Song]? }
