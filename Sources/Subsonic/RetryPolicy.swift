import Foundation

/// Tries a read again after a transient failure (timeout, lost connection, 5xx, broken reply), waiting a little longer
/// each time. Writes are never retried: a lost reply does not say whether the server did the change.
public struct RetryPolicy: Sendable {
    /// Tries in all, the first one included.
    public var attempts: Int
    /// Wait before the second try; it doubles up to `cap`, and each wait is cut by a random 0–50 %.
    public var base: Duration
    public var cap: Duration
    public var sleep: @Sendable (Duration) async throws -> Void
    /// A number in 0..<1 for the jitter.
    public var random: @Sendable () -> Double

    public init(attempts: Int, base: Duration = .milliseconds(500), cap: Duration = .seconds(4),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.attempts = attempts
        self.base = base
        self.cap = cap
        self.sleep = sleep
        self.random = random
    }

    public static let standard = RetryPolicy(attempts: 4)
    public static let none = RetryPolicy(attempts: 1)

    /// The wait after failed try `n` (1-based).
    public func delay(after n: Int) -> Duration {
        min(cap, base * Double(1 << min(max(0, n - 1), 20))) * (1 - random() / 2)
    }

    /// Runs `work`; while it throws an error that `retries` accepts, waits and runs it again, up to `attempts` times.
    public func run<T>(retries: (Error) -> Bool = isTransient, _ work: () async throws -> T) async throws -> T {
        var n = 1
        while true {
            do { return try await work() } catch where n < attempts && retries(error) && !Task.isCancelled {
                try await sleep(delay(after: n))
                n += 1
            }
        }
    }

    /// Worth another try. Refused passwords (40, 41), missing items (404, 70) and cancellations are not.
    public static func isTransient(_ error: Error) -> Bool {
        switch error {
        case let error as SubsonicError:
            switch error {
            case .badStatus(let status): status >= 500 || status == 408 || status == 429
            case .badResponse(let what): !what.contains("cancelled")
            case .api: false
            }
        case let error as URLError:
            [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .badServerResponse,
             .cannotParseResponse, .resourceUnavailable].contains(error.code)
        default: false
        }
    }

    /// For binary endpoints, whose error replies arrive as a body that is not the file: that body is final.
    public static func isTransientBinary(_ error: Error) -> Bool {
        if case .badResponse? = error as? SubsonicError { return false }
        return isTransient(error)
    }

    /// Only GET-style Subsonic calls (`ping`, `get…`, `search…`) are safe to send twice.
    public static func isRead(_ method: String) -> Bool {
        method == "ping" || method.hasPrefix("get") || method.hasPrefix("search")
    }
}
