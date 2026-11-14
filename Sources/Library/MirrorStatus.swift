import Foundation

public enum MirrorState: Sendable, Equatable {
    case idle, running, paused
    /// The last pass had a failing phase; the next one is already scheduled.
    case failed(String)
    /// Background sync is switched off in the settings.
    case disabled
}

public enum MirrorPhase: String, Sendable, CaseIterable {
    case scan, artists, albums, tracks, playlists, favorites, covers, lyrics
}

/// Progress snapshot for the UI.
public struct MirrorStatus: Sendable, Equatable {
    public var state: MirrorState = .idle
    public var phase: MirrorPhase?
    public var done = 0
    /// Nil while the size of the phase is not known (the album listing).
    public var total: Int?
    public var lastSuccess: Date?
    public var warnings = 0
    public var lastWarning: String?

    public init() {}

    public var fraction: Double? { total.map { $0 > 0 ? min(1, Double(done) / Double($0)) : 1 } }
}

/// Holds the current status and feeds any number of `AsyncStream`s. Safe to call from any thread.
final class StatusHub: @unchecked Sendable {
    private let lock = NSLock()
    private var current = MirrorStatus()
    private var subscribers: [UUID: AsyncStream<MirrorStatus>.Continuation] = [:]

    var latest: MirrorStatus { lock.withLock { current } }

    func update(_ change: (inout MirrorStatus) -> Void) {
        lock.withLock {
            let before = current
            change(&current)
            guard current != before else { return }
            for continuation in subscribers.values { continuation.yield(current) }
        }
    }

    /// Yields the current status first, then every change. Slow readers only see the newest value.
    func stream() -> AsyncStream<MirrorStatus> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock {
                subscribers[id] = continuation
                continuation.yield(current)
            }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) } }
        }
    }
}
