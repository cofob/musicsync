import Foundation

/// When to write the queue: soon after an event, at most once per `minimumGap`, and every `interval` while playing.
/// Pure: the caller passes the time, so tests use their own clock.
public struct SaveThrottle: Sendable {
    public let minimumGap: TimeInterval
    public let interval: TimeInterval
    public private(set) var lastSave: Date?
    /// When the next save should run; nil when none is waiting.
    public private(set) var due: Date?

    public init(minimumGap: TimeInterval, interval: TimeInterval) {
        self.minimumGap = minimumGap
        self.interval = interval
    }

    /// An event worth saving (pause, song change): due now, or when the gap since the last save ends.
    public mutating func request(now: Date) {
        let at = max(now, lastSave.map { $0.addingTimeInterval(minimumGap) } ?? now)
        due = min(due ?? at, at)
    }

    /// Called while playing: requests a save when `interval` passed since the last one.
    public mutating func playing(now: Date) {
        if lastSave.map({ now.timeIntervalSince($0) >= interval }) ?? true { request(now: now) }
    }

    /// True when a save should run now; it then counts as done.
    public mutating func fire(now: Date) -> Bool {
        guard let due, now >= due else { return false }
        self.due = nil
        lastSave = now
        return true
    }
}

/// The play queue the server keeps for the user (`getPlayQueue`), reduced to what the hand-off needs.
public struct RemoteQueueState: Sendable, Equatable {
    public var current: String?
    public var position: TimeInterval
    public var changed: Date?
    public var changedBy: String?

    public init(current: String?, position: TimeInterval, changed: Date?, changedBy: String?) {
        self.current = current
        self.position = position
        self.changed = changed
        self.changedBy = changedBy
    }
}

public enum QueueHandoff {
    /// True when the server queue was saved somewhere else after the last one handled here, so "Continue from…" is
    /// offered. Not for this app's own save (`saved`: what this client wrote last), nor when this Mac is already
    /// at that song and position.
    public static func offers(_ remote: RemoteQueueState, client: String, saved: RemoteQueueState?, handled: Date?,
                              local: (current: String?, position: TimeInterval)) -> Bool {
        guard let current = remote.current, let changed = remote.changed else { return false }
        if let handled, changed <= handled { return false }
        if remote.changedBy == client, let saved, saved.current == current, abs(saved.position - remote.position) < 2 { return false }
        return !(local.current == current && abs(local.position - remote.position) < 15)
    }
}
