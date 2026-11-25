import CryptoKit
import Foundation
import Support

/// Subsonic/OpenSubsonic client with per-request token authentication.
public struct SubsonicClient: Sendable {
    public static let apiVersion = "1.16.1"
    public static let clientName = "MusicSync"

    public let baseURL: URL
    public let username: String
    private let password: String
    let session: URLSession
    /// For reads only (`RetryPolicy.isRead`); writes are sent once.
    public var retry = RetryPolicy.standard

    public init(baseURL: URL, username: String, password: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    /// Reads the password from the Keychain. Returns nil if none is stored.
    public init?(config: ServerConfig, session: URLSession = .shared) {
        guard let password = config.password else { return nil }
        self.init(baseURL: config.baseURL, username: config.username, password: password, session: session)
    }

    public var config: ServerConfig { ServerConfig(baseURL: baseURL, username: username) }

    /// Lowercase hex md5 of `password + salt`.
    public static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).hex
    }

    // MARK: URLs

    /// Builds a URL with fresh auth parameters. Never cache the result.
    public func url(_ method: String, _ query: [(String, String)] = [], json: Bool = true) -> URL {
        let salt = (0..<6).map { _ in UInt8.random(in: .min ... .max) }.hex
        var items: [(String, String)] = [
            ("u", username), ("s", salt), ("t", Self.token(password: password, salt: salt)),
            ("v", Self.apiVersion), ("c", Self.clientName),
        ]
        if json { items.append(("f", "json")) }
        items += query
        var parts = URLComponents(url: baseURL.appendingPathComponent("rest/\(method).view"), resolvingAgainstBaseURL: false)!
        parts.percentEncodedQuery = items.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        return parts.url!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    public func coverArtURL(id: String, size: Int? = nil) -> URL {
        url("getCoverArt", [("id", id), ("square", "true")] + (size.map { [("size", String($0))] } ?? []), json: false)
    }

    /// `format` "raw" streams the original file. `maxBitRate` is in kbps. `timeOffset` (seconds) starts a converted
    /// stream later; it needs the OpenSubsonic `transcodeOffset` extension.
    /// `estimateContentLength` asks the server for a length of a converted stream, which the audio tap's loader needs.
    public func streamURL(id: String, format: String? = nil, maxBitRate: Int? = nil, timeOffset: Int? = nil,
                          estimateContentLength: Bool = false) -> URL {
        url("stream", [("id", id)]
            + (estimateContentLength ? [("estimateContentLength", "true")] : [])
            + (format.map { [("format", $0)] } ?? [])
            + (maxBitRate.map { [("maxBitRate", String($0))] } ?? [])
            + (timeOffset.map { [("timeOffset", String($0))] } ?? []), json: false)
    }

    public func downloadURL(id: String) -> URL { url("download", [("id", id)], json: false) }

    // MARK: Requests

    func call<Body: Decodable>(_ method: String, key: String?, _ query: [(String, String)] = []) async throws -> (ServerInfo, Body?) {
        try await (RetryPolicy.isRead(method) ? retry : .none).run { try await callOnce(method, key: key, query) }
    }

    private func callOnce<Body: Decodable>(_ method: String, key: String?, _ query: [(String, String)]) async throws -> (ServerInfo, Body?) {
        let (data, response) = try await session.data(from: url(method, query))
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw SubsonicError.badStatus(status) }
        let decoder = JSONDecoder()
        decoder.userInfo[Reply<Body>.bodyKey] = key
        let reply: Reply<Body>
        // The short system text: the full `DecodingError` dump is not a message for an alert.
        do { reply = try decoder.decode(Reply<Body>.self, from: data) } catch {
            throw SubsonicError.badResponse("\(method): \(error.localizedDescription)")
        }
        guard reply.head.status == "ok" else {
            throw SubsonicError.api(code: reply.head.error?.code ?? 0, message: reply.head.error?.message ?? "Unknown error")
        }
        return (reply.head.info, reply.body)
    }

    func fetch<Body: Decodable>(_ method: String, _ key: String, _ query: [(String, String)] = []) async throws -> Body {
        guard let body = try await (call(method, key: key, query) as (ServerInfo, Body?)).1 else {
            throw SubsonicError.badResponse("\(method): missing \(key)")
        }
        return body
    }

    public func ping() async throws -> ServerInfo {
        try await (call("ping", key: nil) as (ServerInfo, Empty?)).0
    }

    public func getOpenSubsonicExtensions() async throws -> [OpenSubsonicExtension] {
        try await fetch("getOpenSubsonicExtensions", "openSubsonicExtensions")
    }

    public func getArtists() async throws -> [ArtistIndex] {
        try await (fetch("getArtists", "artists") as ArtistsBody).index ?? []
    }

    public func getArtist(id: String) async throws -> Artist {
        try await fetch("getArtist", "artist", [("id", id)])
    }

    /// `type` e.g. `alphabeticalByName`, `newest`, `recent`. `size` is capped at 500 by servers.
    public func getAlbumList2(type: String, size: Int = 500, offset: Int = 0) async throws -> [Album] {
        try await (fetch("getAlbumList2", "albumList2", [
            ("type", type), ("size", String(min(size, 500))), ("offset", String(offset)),
        ]) as AlbumListBody).album ?? []
    }

    public func getAlbum(id: String) async throws -> Album {
        try await fetch("getAlbum", "album", [("id", id)])
    }

    public func getPlaylists() async throws -> [Playlist] {
        try await (fetch("getPlaylists", "playlists") as PlaylistsBody).playlist ?? []
    }

    public func getPlaylist(id: String) async throws -> Playlist {
        try await fetch("getPlaylist", "playlist", [("id", id)])
    }

    public func search3(_ query: String, artistCount: Int = 20, albumCount: Int = 40, songCount: Int = 50,
                        artistOffset: Int = 0, albumOffset: Int = 0, songOffset: Int = 0) async throws -> SearchResult3 {
        try await fetch("search3", "searchResult3", [
            ("query", query), ("artistCount", String(artistCount)),
            ("albumCount", String(albumCount)), ("songCount", String(songCount)),
            ("artistOffset", String(artistOffset)), ("albumOffset", String(albumOffset)), ("songOffset", String(songOffset)),
        ])
    }

    public func getScanStatus() async throws -> ScanStatus {
        try await fetch("getScanStatus", "scanStatus")
    }

    /// `times` are play start dates, one per id; omit for "now". `submission: false` marks now-playing only.
    public func scrobble(ids: [String], times: [Date]? = nil, submission: Bool = true) async throws {
        var query = ids.map { ("id", $0) }
        query += (times ?? []).map { ("time", String(Int64($0.timeIntervalSince1970 * 1000))) }
        query.append(("submission", submission ? "true" : "false"))
        _ = try await call("scrobble", key: nil, query) as (ServerInfo, Empty?)
    }

    /// Cover art bytes (square, `size` px).
    /// An error body here means the server has no image, so only network and status errors are tried again.
    public func coverArt(id: String, size: Int) async throws -> Data {
        try await retry.run(retries: RetryPolicy.isTransientBinary) {
            let (data, response) = try await session.data(from: coverArtURL(id: id, size: size))
            try Self.check(response, body: data)
            if Self.isPlaceholderCover(response) { throw SubsonicError.badResponse("placeholder cover") }
            return data
        }
    }

    /// Navidrome answers an item without art with its own stand-in image (a vinyl record), sent as never to be
    /// stored; real covers may be cached. That image is no cover.
    static func isPlaceholderCover(_ response: URLResponse?) -> Bool {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true
    }

    /// Binary endpoints send a Subsonic error body (XML/JSON) with HTTP 200.
    static func check(_ response: URLResponse?, body: @autoclosure () -> Data?) throws {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw SubsonicError.badStatus(status) }
        if let type = response?.mimeType, errorTypes.contains(type) {
            throw SubsonicError.badResponse(String(decoding: (body() ?? Data()).prefix(500), as: UTF8.self))
        }
    }

    static let errorTypes: Set = ["text/xml", "application/xml", "application/json"]

    /// Downloads the original file to a temp file. The caller moves or deletes it.
    /// `progress` gets bytes received and expected (-1 when unknown), at most 5 times a second.
    /// A download task, not `session.download(from:delegate:)`: that one never reports progress.
    /// The original file, or with `format` the server's conversion (`stream`; no Content-Length then).
    public func download(id: String, format: String? = nil, maxBitRate: Int? = nil,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-\(UUID().uuidString)-\(id)")
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let url = format == nil ? downloadURL(id: id) : streamURL(id: id, format: format, maxBitRate: maxBitRate)
                let task = session.downloadTask(with: url) { tmp, response, error in
                    // `tmp` is deleted when this returns, so it is moved here.
                    if let error { return continuation.resume(throwing: error) }
                    do { try Self.check(response, body: tmp.flatMap { try? Data(contentsOf: $0) }) } catch {
                        return continuation.resume(throwing: error)
                    }
                    guard let tmp else { return continuation.resume(throwing: URLError(.cannotCreateFile)) }
                    continuation.resume(with: Result { try FileManager.default.moveItem(at: tmp, to: dest); return dest })
                }
                if let progress {
                    let last = TaskBox.Clock()
                    // Byte counters, not `task.progress`: without Content-Length that one counts percent (of 100).
                    // Expected is -1 when unknown.
                    box.observation = task.observe(\.countOfBytesReceived) { t, _ in
                        if last.tick() { progress(t.countOfBytesReceived, t.countOfBytesExpectedToReceive) }
                    }
                }
                box.start(task)
            }
        } onCancel: { box.cancel() }
    }
}

/// Holds a running download task and its progress observation. A cancel before `start` is kept.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    var observation: NSKeyValueObservation?

    func start(_ t: URLSessionDownloadTask) {
        lock.withLock {
            task = t
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

    /// True at most every 0.2 s.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date.distantPast
        func tick() -> Bool {
            lock.withLock {
                let now = Date()
                guard now.timeIntervalSince(last) >= 0.2 else { return false }
                last = now
                return true
            }
        }
    }
}
