import Foundation

public extension SubsonicClient {
    /// Calls any endpoint. Decodes `subsonic-response[key]` (nil `key`: no payload, result is nil).
    /// Throws `SubsonicError` for failed replies and bad statuses.
    func request<Body: Decodable & Sendable>(_ method: String, key: String?, _ query: [(String, String)] = []) async throws -> Body? {
        try await call(method, key: key, query).1
    }

    /// Marks items as starred. Any mix of songs, albums and artists.
    func star(ids: [String] = [], albumIds: [String] = [], artistIds: [String] = []) async throws {
        try await setStar("star", ids, albumIds, artistIds)
    }

    func unstar(ids: [String] = [], albumIds: [String] = [], artistIds: [String] = []) async throws {
        try await setStar("unstar", ids, albumIds, artistIds)
    }

    private func setStar(_ method: String, _ ids: [String], _ albumIds: [String], _ artistIds: [String]) async throws {
        let query = ids.map { ("id", $0) } + albumIds.map { ("albumId", $0) } + artistIds.map { ("artistId", $0) }
        _ = try await request(method, key: nil, query) as Empty?
    }

    /// Changes a playlist. `songIndexesToRemove` are positions (0-based) in the current order.
    func updatePlaylist(id: String, name: String? = nil, comment: String? = nil, isPublic: Bool? = nil,
                        songIdsToAdd: [String] = [], songIndexesToRemove: [Int] = []) async throws {
        var query = [("playlistId", id)]
        if let name { query.append(("name", name)) }
        if let comment { query.append(("comment", comment)) }
        if let isPublic { query.append(("public", isPublic ? "true" : "false")) }
        query += songIdsToAdd.map { ("songIdToAdd", $0) }
        query += songIndexesToRemove.map { ("songIndexToRemove", String($0)) }
        _ = try await request("updatePlaylist", key: nil, query) as Empty?
    }
}
