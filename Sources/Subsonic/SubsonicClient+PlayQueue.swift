import Foundation

/// The queue the server keeps for the user, so another device can go on with it.
public struct PlayQueueInfo: Decodable, Sendable {
    public let entry: [Song]?
    /// Id of the current song.
    public let current: String?
    /// Milliseconds into the current song.
    public let position: Int?
    public let username: String?
    public let changed: String?
    /// Client name (`c`) of the app that saved it.
    public let changedBy: String?

    public var songs: [Song] { entry ?? [] }

    /// `changed` as a date; servers send fractions of a second (Navidrome: nanoseconds) or none.
    public var changedDate: Date? {
        guard let changed else { return nil }
        let trimmed = changed.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

public extension SubsonicClient {
    /// Nil when the server has no queue for the user.
    func getPlayQueue() async throws -> PlayQueueInfo? {
        try await request("getPlayQueue", key: "playQueue")
    }

    /// `position` is in milliseconds into `current`. An empty `ids` clears the server queue.
    func savePlayQueue(ids: [String], current: String?, position: Int) async throws {
        var query = ids.map { ("id", $0) }
        if let current { query.append(("current", current)) }
        query.append(("position", String(position)))
        _ = try await request("savePlayQueue", key: nil, query) as Empty?
    }
}
