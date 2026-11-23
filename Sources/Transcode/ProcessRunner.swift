import Foundation

struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String
}

/// Thread-safe accumulator that also reports complete stdout lines.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func addOut(_ data: Data) {
        lock.lock()
        out.append(data)
        var lines: [String] = []
        if onLine != nil {
            pending.append(data)
            while let nl = pending.firstIndex(of: 10) {
                lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func addErr(_ data: Data) {
        lock.lock()
        err.append(data)
        lock.unlock()
    }

    var result: (Data, String) {
        lock.lock()
        defer { lock.unlock() }
        return (out, String(decoding: err, as: UTF8.self))
    }
}

#if os(macOS)
/// Lets task cancellation terminate a process that may not have started yet.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(_ p: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run()
        process = p
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }
}

/// Runs `executable`, collecting output; `onLine` receives stdout lines as they arrive.
/// Cancelling the calling task terminates the process and throws `CancellationError`.
func runProcess(_ executable: URL, _ arguments: [String],
                onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessOutput {
    let handle = ProcessHandle()
    let output = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let collector = Collector(onLine: onLine)
            // The result waits for the end of both pipes, so a chunk still in a handler is not lost or reordered.
            let done = DispatchGroup()
            for (pipe, add) in [(outPipe, collector.addOut), (errPipe, collector.addErr)] {
                done.enter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; done.leave() } else { add(data) }
                }
            }
            done.enter()
            process.terminationHandler = { _ in done.leave() }
            done.notify(queue: .global()) {
                let (out, err) = collector.result
                cont.resume(returning: ProcessOutput(status: process.terminationStatus, stdout: out, stderr: err))
            }
            do { try handle.run(process) } catch { cont.resume(throwing: error) }
        }
    } onCancel: {
        handle.cancel()
    }
    try Task.checkCancellation()
    return output
}
#else
/// iOS runs no other programs.
func runProcess(_ executable: URL, _ arguments: [String],
                onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessOutput {
    throw TranscodeError.binaryNotFound
}
#endif
