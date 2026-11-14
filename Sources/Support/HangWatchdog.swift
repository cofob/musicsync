import Foundation
import Synchronization

/// Development only: a thread that pings a queue (the main queue in the app) every 50 ms and appends
/// each stall longer than `threshold` to a log file, as "<time> <ms> ms <context>". Nothing runs until `start`.
public enum HangWatchdog {
    /// `MUSICSYNC_HANG_LOG=<file>`, else `hangs.log` in the demo folder in demo mode, else nil (off).
    public static var logFile: URL? {
        if let path = ProcessInfo.processInfo.environment["MUSICSYNC_HANG_LOG"] { return URL(fileURLWithPath: path) }
        return Paths.isDemo ? Paths.demoDirectory.appendingPathComponent("hangs.log") : nil
    }

    /// Returns the thread; `cancel()` stops it. `context` runs on `queue` with each ping, so it must be cheap.
    @discardableResult
    public static func start(file: URL, queue: DispatchQueue = .main, threshold: TimeInterval = 0.1,
                             context: @escaping @Sendable () -> String = { "" }) -> Thread {
        let thread = Thread {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
            let answered = DispatchSemaphore(value: 0)
            let place = Mutex("")
            let time = ISO8601DateFormatter()
            time.formatOptions.insert(.withFractionalSeconds)
            while !Thread.current.isCancelled {
                let sent = DispatchTime.now()
                queue.async { place.withLock { $0 = context() }; answered.signal() }
                answered.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
                if ms > threshold * 1000 {
                    let line = "\(time.string(from: Date())) \(Int(ms)) ms \(place.withLock { $0 })\n"
                    try? handle?.write(contentsOf: Data(line.utf8))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? handle?.close()
        }
        thread.name = "HangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
        return thread
    }
}
