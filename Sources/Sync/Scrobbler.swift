import CryptoKit
import Foundation
import Subsonic
import Support

public struct ScrobbleRequest: Codable, Sendable, Equatable {
    public var songID: String
    public var time: Date
}

public struct FlushResult: Sendable, Equatable {
    public var sent: Int
    public var pending: Int
}

/// Plays made on the iPod, waiting to reach the server. Persisted so a failed or offline sync loses nothing.
public actor Scrobbler {
    private struct State: Codable {
        var queue: [ScrobbleRequest] = []
        /// Digests of Play Counts files already queued (guards against queueing one file twice after a crash).
        var seen: [String] = []
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

    public var pendingCount: Int { state.queue.count }

    /// N plays of a track ending at `lastPlayed` become N times, one track length apart.
    public static func timestamps(plays: Int, lastPlayed: Date?, duration: TimeInterval) -> [Date] {
        let last = lastPlayed ?? Date()
        let step = max(duration, 1)
        return (0..<min(plays, 1000)).map { last.addingTimeInterval(-Double($0) * step) }
    }

    /// Queues requests; `source` identifies the Play Counts file they came from.
    public func enqueue(_ requests: [ScrobbleRequest], source: Data? = nil) {
        if let source {
            let digest = SHA256.hash(data: source).hex
            guard !state.seen.contains(digest) else { return }
            state.seen = Array((state.seen + [digest]).suffix(20))
        }
        state.queue += requests
        save()
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
        return FlushResult(sent: sent, pending: state.queue.count)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(state) { try? FileManager.default.atomicWrite(data, to: url) }
    }
}
