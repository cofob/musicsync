import AVFoundation
import ObjectiveC
import UniformTypeIdentifiers

/// Streams a song to AVFoundation through a resource loader instead of letting it fetch the URL itself: audio taps
/// (the equalizer and the visualizer) never run on assets AVFoundation streams on its own (measured: 0 frames), and run
/// on loader assets. Each loading request is one HTTP range request. For servers that send a length and serve ranges
/// (Subsonic raw streams); converted streams have neither.
public final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let prefix = "musicsync-"
    nonisolated(unsafe) private static var key: UInt8 = 0

    /// All state is used on this queue: the loader and the session call back on it.
    private let queue = DispatchQueue(label: "StreamLoader")
    private let contentType: String?
    private var session: URLSession!
    /// Per task: its loading request, bytes to drop before the requested offset, bytes still wanted (nil: to the end).
    private var requests: [Int: (loading: AVAssetResourceLoadingRequest, skip: Int64, left: Int64?)] = [:]

    /// An asset that streams `url` (http or https) through a new loader; `contentType` overrides the server's MIME type.
    public static func asset(_ url: URL, contentType: String? = nil, configuration: URLSessionConfiguration = .default) -> AVURLAsset {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = prefix + (url.scheme ?? "https")
        let asset = AVURLAsset(url: parts?.url ?? url)
        let loader = StreamLoader(contentType: contentType, configuration: configuration)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // The resource loader keeps its delegate weakly: the asset keeps it.
        objc_setAssociatedObject(asset, &key, loader, .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    private init(contentType: String?, configuration: URLSessionConfiguration) {
        self.contentType = contentType
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Resource loader

    public func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loading: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loading.request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, scheme.hasPrefix(Self.prefix) else { return false }
        parts.scheme = String(scheme.dropFirst(Self.prefix.count))
        guard let real = parts.url else { return false }
        var request = URLRequest(url: real)
        let start = loading.dataRequest?.requestedOffset ?? 0
        if let data = loading.dataRequest, !data.requestsAllDataToEndOfResource {
            request.setValue("bytes=\(start)-\(start + Int64(data.requestedLength) - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        let left = loading.dataRequest.flatMap { $0.requestsAllDataToEndOfResource ? nil : Int64($0.requestedLength) }
        requests[task.taskIdentifier] = (loading, 0, left)
        task.resume()
        return true
    }

    public func resourceLoader(_ loader: AVAssetResourceLoader, didCancel loading: AVAssetResourceLoadingRequest) {
        session.getAllTasks { [self] tasks in
            queue.async { [self] in
                for task in tasks where requests[task.taskIdentifier]?.loading === loading {
                    requests[task.taskIdentifier] = nil
                    task.cancel()
                }
            }
        }
    }

    // MARK: URLSession

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard var entry = requests[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else {
            requests[dataTask.taskIdentifier]?.loading.finishLoading(with: URLError(.badServerResponse))
            requests[dataTask.taskIdentifier] = nil
            return completionHandler(.cancel)
        }
        let ranged = http.statusCode == 206
        // A server that ignores the range sends the whole file: skip to the requested offset.
        if !ranged { entry.skip = entry.loading.dataRequest?.requestedOffset ?? 0 }
        requests[dataTask.taskIdentifier] = entry
        if let info = entry.loading.contentInformationRequest {
            let mime = contentType ?? http.mimeType
            info.contentType = mime.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.audio.identifier
            info.contentLength = Self.totalLength(http) ?? response.expectedContentLength
            // Ranges always work: without server support the loader skips to the offset itself.
            info.isByteRangeAccessSupported = true
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var entry = requests[dataTask.taskIdentifier] else { return }
        var data = data
        let dropped = min(Int64(data.count), entry.skip)
        data = data.dropFirst(Int(dropped))
        entry.skip -= dropped
        // A server that ignores the range sends more than was asked for.
        if let left = entry.left {
            data = data.prefix(Int(left))
            entry.left = left - Int64(data.count)
        }
        if !data.isEmpty { entry.loading.dataRequest?.respond(with: data) }
        if entry.left == 0 {
            requests[dataTask.taskIdentifier] = nil
            entry.loading.finishLoading()
            dataTask.cancel()
        } else {
            requests[dataTask.taskIdentifier] = entry
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = requests.removeValue(forKey: task.taskIdentifier) else { return }
        if let error { entry.loading.finishLoading(with: error) } else { entry.loading.finishLoading() }
    }

    /// The full length from `Content-Range: bytes a-b/total`, else nil.
    static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last else { return nil }
        return Int64(total)
    }
}
