import Foundation

extension SubsonicClient {
    /// Like `download`, but into `part`, and resumable: when `part` already holds the start of the file, only the rest
    /// is asked for (HTTP Range); a server that ignores the range sends the whole file again. After a failure `part`
    /// keeps what arrived, so the next call goes on from there. The caller moves or deletes `part`.
    /// `progress` gets bytes received (with those already in `part`) and expected (-1 when unknown).
    public func download(id: String, format: String? = nil, maxBitRate: Int? = nil, resuming part: URL,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let url = format == nil ? downloadURL(id: id) : streamURL(id: id, format: format, maxBitRate: maxBitRate)
        let have = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let writer = PartWriter(part: part, have: have, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.finish = { continuation.resume(with: $0) }
                writer.start(session.dataTask(with: request))
            }
        } onCancel: { writer.cancel() }
    }
}

/// Appends the reply body of one data task to the part file.
private final class PartWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let part: URL
    private var have: Int64
    private var expected: Int64 = -1
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let clock = TaskBox.Clock()
    private var file: FileHandle?
    private var response: URLResponse?
    /// Set for a Subsonic error body (XML/JSON), which is kept in memory instead of the file.
    private var errorBody: Data?
    private var failure: Error?
    private var task: URLSessionDataTask?
    private var cancelled = false
    var finish: ((Result<Void, Error>) -> Void)?

    init(part: URL, have: Int64, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.part = part
        self.have = have
        self.progress = progress
    }

    func start(_ t: URLSessionDataTask) {
        lock.withLock {
            task = t
            t.delegate = self
            t.resume()
            if cancelled { t.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 200
        if let type = response.mimeType, SubsonicClient.errorTypes.contains(type) {
            errorBody = Data()
            return completionHandler(.allow)
        }
        do {
            let resumed = status == 206 && http?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(have)-") == true
            if !resumed {
                // A range past the end: the part is wrong, so the next try starts over.
                if status == 416 { try? FileManager.default.removeItem(at: part) }
                guard status == 200 else { throw SubsonicError.badStatus(status) }
                have = 0
            }
            if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
            let file = try FileHandle(forWritingTo: part)
            try file.truncate(atOffset: UInt64(have))
            self.file = file
            expected = response.expectedContentLength >= 0 ? have + response.expectedContentLength : -1
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if errorBody != nil { return errorBody?.append(data.prefix(500)) ?? () }
        do {
            try file?.write(contentsOf: data)
            have += Int64(data.count)
            if let progress, clock.tick() { progress(have, expected) }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        let result = Result<Void, Error> {
            if let error = failure ?? error { throw error }
            if let errorBody { try SubsonicClient.check(response, body: errorBody) }
            // URLSession does not always notice a range reply that ends early.
            if expected >= 0, have < expected { throw URLError(.networkConnectionLost) }
        }
        lock.withLock { self.task = nil }
        finish?(result)
        finish = nil
    }
}
