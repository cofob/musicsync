import Foundation

/// Playlist and rating changes. Pair with `updatePlaylist`, `star` and `unstar`.
public extension SubsonicClient {
    /// New playlist with these songs. Nil when the server does not send the playlist back (Subsonic before 1.14).
    func createPlaylist(name: String, songIds: [String] = []) async throws -> Playlist? {
        try await request("createPlaylist", key: "playlist", [("name", name)] + songIds.map { ("songId", $0) })
    }

    /// Replaces all songs of a playlist, e.g. to change their order.
    func replacePlaylistSongs(id: String, songIds: [String]) async throws {
        _ = try await request("createPlaylist", key: nil, [("playlistId", id)] + songIds.map { ("songId", $0) }) as Empty?
    }

    func deletePlaylist(id: String) async throws {
        _ = try await request("deletePlaylist", key: nil, [("id", id)]) as Empty?
    }

    /// `rating` 1...5; 0 removes the rating.
    func setRating(id: String, rating: Int) async throws {
        _ = try await request("setRating", key: nil, [("id", id), ("rating", String(min(max(rating, 0), 5)))]) as Empty?
    }
}
