import Foundation

/// A public link to songs, an album or a playlist. Navidrome has them only with `EnableSharing`.
public struct Share: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let description: String?
    public let username: String?
    public let created: String?
    public let expires: String?
    public let lastVisited: String?
    public let visitCount: Int?
    public let entry: [Song]?
}

struct SharesBody: Decodable, Sendable { let share: [Share]? }

public extension SubsonicClient {
    /// A server without shares answers with an error (Navidrome: HTTP 501, others: API error 30 or 70).
    func getShares() async throws -> [Share] {
        try await (fetch("getShares", "shares") as SharesBody).share ?? []
    }

    /// New share of songs, an album or a playlist. Nil when the server sends no share back.
    /// `downloadable` lets people download the files from the share page; Navidrome reads it, other servers ignore it.
    func createShare(ids: [String], description: String? = nil, expires: Date? = nil, downloadable: Bool? = nil) async throws -> Share? {
        var query = ids.map { ("id", $0) }
        if let description { query.append(("description", description)) }
        if let downloadable { query.append(("downloadable", String(downloadable))) }
        if let expires { query.append(("expires", String(Int64(expires.timeIntervalSince1970 * 1000)))) }
        let body: SharesBody? = try await request("createShare", key: "shares", query)
        return body?.share?.first
    }

    func deleteShare(id: String) async throws {
        _ = try await request("deleteShare", key: nil, [("id", id)]) as Empty?
    }

    /// One song, e.g. for a `musicsync://song/<id>` link.
    func getSong(id: String) async throws -> Song {
        try await fetch("getSong", "song", [("id", id)])
    }
}
