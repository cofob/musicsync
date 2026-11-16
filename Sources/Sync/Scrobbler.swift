import CryptoKit
import Foundation
import Subsonic
import Support

public struct ScrobbleRequest: Codable, Sendable, Equatable {
    public var songID: String
    public var time: Date
}

/// An On-The-Go list waiting to become a server playlist.
public struct PendingPlaylist: Codable, Sendable, Equatable {
    public var name: String
    public var songIDs: [String]
}

public struct FlushResult: Sendable, Equatable {
    public var sent: Int
    public var pending: Int
}

/// Plays, ratings, stars and On-The-Go lists made on the iPod, waiting to reach the server.
/// Persisted so a failed or offline sync loses nothing.
public actor Scrobbler {
    private struct State: Codable {
        var queue: [ScrobbleRequest] = []
        /// Digests of Play Counts files already queued (guards against queueing one file twice after a crash).
        var seen: [String] = []
        /// Song id -> rating (0-5); the last one wins.
        var ratings: [String: Int] = [:]
        /// Song id -> starred.
        var stars: [String: Bool] = [:]
        var playlists: [PendingPlaylist] = []

        init() {}

        /// Queues saved by an older version still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            queue = try c.decodeIfPresent([ScrobbleRequest].self, forKey: .queue) ?? []
            seen = try c.decodeIfPresent([String].self, forKey: .seen) ?? []
            ratings = try c.decodeIfPresent([String: Int].self, forKey: .ratings) ?? [:]
            stars = try c.decodeIfPresent([String: Bool].self, forKey: .stars) ?? [:]
            playlists = try c.decodeIfPresent([PendingPlaylist].self, forKey: .playlists) ?? []
        }
    }

    public static let batchSize = 50
    public static let shared = Scrobbler(queueURL: SyncLocations.standard.scrobbleQueue)

    private let url: URL
    private var state: State
    private var flushing: Task<FlushResult, Never>?

    public init(queueURL: URL) {
        url = queueURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = (try? Data(contentsOf: queueURL)).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
    }

    /// Queued plays.
    public var pendingCount: Int { state.queue.count }
    /// Queued ratings, stars and playlists.
    public var pendingUpdateCount: Int { state.ratings.count + state.stars.count + state.playlists.count }

    /// N plays of a track ending at `lastPlayed` become N times, one track length apart.
    public static func timestamps(plays: Int, lastPlayed: Date?, duration: TimeInterval) -> [Date] {
        let last = lastPlayed ?? Date()
        let step = max(duration, 1)
        return (0..<min(plays, 1000)).map { last.addingTimeInterval(-Double($0) * step) }
    }

    /// Queues requests; `source` identifies the Play Counts file they came from.
    public func enqueue(_ requests: [ScrobbleRequest], source: Data? = nil) {
        guard isNew(source) else { return }
        state.queue += requests
        save()
    }

    /// Queues server updates; `source` identifies the On-The-Go files the playlists came from.
    public func enqueue(ratings: [String: Int] = [:], stars: [String: Bool] = [:], playlists: [PendingPlaylist] = [],
                        source: Data? = nil) {
        state.ratings.merge(ratings) { _, new in new }
        state.stars.merge(stars) { _, new in new }
        if !playlists.isEmpty, isNew(source) { state.playlists += playlists }
        save()
    }

    /// False when `source` was queued before; remembers it.
    private func isNew(_ source: Data?) -> Bool {
        guard let source else { return true }
        let digest = SHA256.hash(data: source).hex
        guard !state.seen.contains(digest) else { return false }
        state.seen = Array((state.seen + [digest]).suffix(20))
        return true
    }

    /// Sends the queue in batches of 50, oldest first. A failed batch and everything after it stays queued.
    /// A flush that starts while another runs waits for it and returns its result.
    @discardableResult
    public func flush(client: SubsonicClient) async -> FlushResult {
        if let flushing { return await flushing.value }
        let task = Task {
            let result = await send(client: client)
            flushing = nil
            return result
        }
        flushing = task
        return await task.value
    }

    private func send(client: SubsonicClient) async -> FlushResult {
        var sent = 0
        let sorted = state.queue.sorted { $0.time < $1.time }
        for start in stride(from: 0, to: sorted.count, by: Self.batchSize) {
            let batch = Array(sorted[start..<min(start + Self.batchSize, sorted.count)])
            do {
                try await client.scrobble(ids: batch.map(\.songID), times: batch.map(\.time), submission: true)
            } catch { break }
            sent += batch.count
            for request in batch { if let i = state.queue.firstIndex(of: request) { state.queue.remove(at: i) } }
            save()
        }
        await sendUpdates(client: client)
        return FlushResult(sent: sent, pending: state.queue.count)
    }

    /// Ratings, stars, then playlists. A failed update stays queued; the rest still go.
    private func sendUpdates(client: SubsonicClient) async {
        for (id, rating) in state.ratings {
            guard (try? await client.setRating(id: id, rating: rating)) != nil else { continue }
            if state.ratings[id] == rating { state.ratings[id] = nil }
        }
        for starred in [true, false] {
            let ids = state.stars.filter { $0.value == starred }.map(\.key)
            guard !ids.isEmpty else { continue }
            do { try await (starred ? client.star(ids: ids) : client.unstar(ids: ids)) } catch { continue }
            for id in ids where state.stars[id] == starred { state.stars[id] = nil }
        }
        while let list = state.playlists.first {
            do { _ = try await client.createPlaylist(name: list.name, songIds: list.songIDs) } catch { break }
            state.playlists.removeFirst()
        }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(state) { try? FileManager.default.atomicWrite(data, to: url) }
    }
}
