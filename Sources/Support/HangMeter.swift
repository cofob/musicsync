import Foundation
import Synchronization

/// Development only: a thread that pings a queue (the main queue in the app) every few milliseconds and keeps
/// the longest wait for an answer since the last `lap`, so a check can time how long an action blocks the queue.
public final class HangMeter: Sendable {
    private struct State { var longest: TimeInterval = 0; var since = DispatchTime.now() }
    private final class Shared: Sendable { let state = Mutex(State()) }
    private let shared = Shared()
    private nonisolated(unsafe) let thread: Thread

    public init(queue: DispatchQueue = .main, interval: TimeInterval = 0.005) {
        let shared = shared
        thread = Thread {
            let answered = DispatchSemaphore(value: 0)
            while !Thread.current.isCancelled {
                let sent = DispatchTime.now()
                queue.async { answered.signal() }
                answered.wait()
                let now = DispatchTime.now().uptimeNanoseconds
                shared.state.withLock { s in
                    // A ping sent before the lap counts only from the lap on.
                    let start = max(sent.uptimeNanoseconds, s.since.uptimeNanoseconds)
                    let wait = Double(now > start ? now - start : 0) / 1e9
                    s.longest = max(s.longest, wait)
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        thread.name = "HangMeter"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The longest wait in seconds since the last lap; starts the next lap.
    public func lap() -> TimeInterval {
        shared.state.withLock { s in
            defer { s = State() }
            return s.longest
        }
    }

    public func stop() { thread.cancel() }
}
