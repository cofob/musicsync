import Foundation
import Subsonic

struct StubSong {
    var id: String
    var title: String
    var track = 1
    var disc = 1
}

struct StubAlbum {
    var id: String
    var name: String
    var artistId = "ar-1"
    var year = 2000
    var songs: [StubSong]
    var created = "2024-01-01T00:00:00Z"
}

struct StubPlaylist {
    var id: String
    var name: String
    var changed: String
    var songIDs: [String]
}

/// An in-process Subsonic server behind a `URLProtocol`; never touches the network.
final class StubLibraryServer: @unchecked Sendable {
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()

    private var _albums: [StubAlbum] = []
    private var _playlists: [StubPlaylist] = []
    private var _log: [String] = []
    private var _albumListCalls = 0
    private var _failAlbumListAfter: Int?
    private var _emptyAlbumList = false
    private var _emptyAlbumReply = false
    private var _delayMs = 0
    private var _coverStatus = 200
    private var _lyricsStatus = 200
    private var _lastScan = "scan-1"
    private var _lyrics: [String: [String: Any]] = [:]
    private var _extensions = ["songLyrics"]
    private var _starred: [String: String] = [:]
    private var _failDownloads = 0
    private let cover = Data("COVER-BYTES".utf8)
    /// Body of download and stream replies.
    let audio = Data(repeating: 7, count: 1000)
    let artists: [(id: String, name: String)] = [("ar-1", "Space Echo"), ("ar-2", "Björk")]

    var albums: [StubAlbum] { get { locked { _albums } } set { locked { _albums = newValue } } }
    var playlists: [StubPlaylist] { get { locked { _playlists } } set { locked { _playlists = newValue } } }
    var lastScan: String { get { locked { _lastScan } } set { locked { _lastScan = newValue } } }
    var extensions: [String] { get { locked { _extensions } } set { locked { _extensions = newValue } } }
    /// Starred song, album or artist ids -> star date, for getStarred2.
    var starred: [String: String] { get { locked { _starred } } set { locked { _starred = newValue } } }
    /// HTTP status of getCoverArt replies.
    var coverStatus: Int { get { locked { _coverStatus } } set { locked { _coverStatus = newValue } } }
    /// 200 answers; 0 sends a Subsonic error; other values are HTTP statuses.
    var lyricsStatus: Int { get { locked { _lyricsStatus } } set { locked { _lyricsStatus = newValue } } }
    var delayMs: Int { get { locked { _delayMs } } set { locked { _delayMs = newValue } } }
    /// getAlbumList2 answers this many calls, then fails with HTTP 500.
    var failAlbumListAfter: Int? { get { locked { _failAlbumListAfter } } set { locked { _failAlbumListAfter = newValue; _albumListCalls = 0 } } }
    /// getAlbumList2 answers with no albums at all.
    var emptyAlbumList: Bool { get { locked { _emptyAlbumList } } set { locked { _emptyAlbumList = newValue } } }
    /// getAlbum answers with no songs.
    var emptyAlbumReply: Bool { get { locked { _emptyAlbumReply } } set { locked { _emptyAlbumReply = newValue } } }
    /// The next this many download and stream calls fail with HTTP 500.
    var failDownloads: Int { get { locked { _failDownloads } } set { locked { _failDownloads = newValue } } }
    var log: [String] { locked { _log } }
    func clearLog() { locked { _log = [] } }
    func requests(_ method: String) -> [String] { log.filter { $0 == method || $0.hasPrefix(method + ":") } }
    func setLyrics(song: String, synced: Bool, lines: [(Int, String)]) {
        locked {
            _lyrics[song] = ["synced": synced, "lang": "eng", "line": lines.map { ["start": $0.0, "value": $0.1] as [String: Any] }]
        }
    }

    var client: SubsonicClient {
        Registry.shared.register(self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SubsonicClient(baseURL: URL(string: "http://\(host)")!, username: "demo", password: "pw", session: URLSession(configuration: config))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Serving

    fileprivate func respond(to url: URL) -> (status: Int, body: Data, delayMs: Int) {
        let method = url.lastPathComponent.replacingOccurrences(of: ".view", with: "")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return locked {
            _log.append(method + (param("id").map { ":" + $0 } ?? (method == "getAlbumList2" ? ":" + (param("offset") ?? "0") : "")))
            let ok: ([String: Any]) -> (Int, Data, Int) = { (200, Self.envelope($0), self._delayMs) }
            switch method {
            case "getScanStatus": return ok(["scanStatus": ["scanning": false, "count": 1, "lastScan": _lastScan]])
            case "getOpenSubsonicExtensions": return ok(["openSubsonicExtensions": _extensions.map { ["name": $0, "versions": [1]] }])
            case "getArtists":
                return ok(["artists": ["index": [["name": "A", "artist": artists.map { ["id": $0.id, "name": $0.name] }]]]])
            case "getAlbumList2":
                _albumListCalls += 1
                if let limit = _failAlbumListAfter, _albumListCalls > limit { return (500, Data(), 0) }
                let offset = Int(param("offset") ?? "0") ?? 0
                let size = Int(param("size") ?? "500") ?? 500
                let sorted = _emptyAlbumList ? [] : _albums.sorted { $0.name < $1.name }
                let page = sorted.dropFirst(offset).prefix(size).map(Self.albumJSON)
                return ok(["albumList2": page.isEmpty ? [:] : ["album": Array(page)]])
            case "getAlbum":
                guard let album = _albums.first(where: { $0.id == param("id") }) else { return (200, Self.failed, 0) }
                var json = Self.albumJSON(album)
                json["song"] = _emptyAlbumReply ? [] : album.songs.map { Self.songJSON($0, album: album) }
                return ok(["album": json])
            case "getPlaylists":
                return ok(["playlists": ["playlist": _playlists.map {
                    ["id": $0.id, "name": $0.name, "songCount": $0.songIDs.count, "duration": $0.songIDs.count * 100, "changed": $0.changed, "created": "2024-01-01T00:00:00Z"]
                }]])
            case "getPlaylist":
                guard let p = _playlists.first(where: { $0.id == param("id") }) else { return (200, Self.failed, 0) }
                let all = _albums.flatMap { a in a.songs.map { Self.songJSON($0, album: a) } }
                let entries = p.songIDs.compactMap { id in all.first { $0["id"] as? String == id } }
                return ok(["playlist": ["id": p.id, "name": p.name, "songCount": entries.count, "duration": entries.count * 100, "changed": p.changed, "entry": entries]])
            case "getLyricsBySongId":
                if _lyricsStatus == 0 { return (200, Self.failed, 0) }
                if _lyricsStatus != 200 { return (_lyricsStatus, Data(), 0) }
                let lyrics = param("id").flatMap { _lyrics[$0] }
                return ok(["lyricsList": lyrics.map { ["structuredLyrics": [$0]] } ?? [:]])
            case "getCoverArt": return (_coverStatus, cover, _delayMs)
            case "getStarred2":
                func star(_ item: [String: Any]) -> [String: Any]? {
                    (item["id"] as? String).flatMap { _starred[$0] }.map { item.merging(["starred": $0]) { $1 } }
                }
                return ok(["starred2": [
                    "artist": artists.compactMap { star(["id": $0.id, "name": $0.name]) },
                    "album": _albums.compactMap { star(Self.albumJSON($0)) },
                    "song": _albums.flatMap { a in a.songs.compactMap { star(Self.songJSON($0, album: a)) } },
                ]])
            case "download", "stream":
                if _failDownloads > 0 { _failDownloads -= 1; return (500, Data(), 0) }
                return (200, audio, _delayMs)
            default: return (404, Data(), 0)
            }
        }
    }

    static func albumJSON(_ a: StubAlbum) -> [String: Any] {
        ["id": a.id, "name": a.name, "artist": a.artistId == "ar-1" ? "Space Echo" : "Björk", "artistId": a.artistId, "year": a.year,
         "songCount": a.songs.count, "duration": a.songs.count * 200, "created": a.created, "coverArt": "cov-\(a.id)"]
    }

    static func songJSON(_ s: StubSong, album a: StubAlbum) -> [String: Any] {
        ["id": s.id, "title": s.title, "album": a.name, "albumId": a.id, "artist": a.artistId == "ar-1" ? "Space Echo" : "Björk",
         "track": s.track, "discNumber": s.disc, "duration": 200, "suffix": "flac", "created": a.created, "playCount": 0]
    }

    static let failed = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8)

    static func envelope(_ body: [String: Any]) -> Data {
        var inner: [String: Any] = ["status": "ok", "version": "1.16.1"]
        inner.merge(body) { $1 }
        return try! JSONSerialization.data(withJSONObject: ["subsonic-response": inner])
    }
}

final class Registry: @unchecked Sendable {
    static let shared = Registry()
    private let lock = NSLock()
    private var servers: [String: StubLibraryServer] = [:]

    func register(_ server: StubLibraryServer) { lock.lock(); servers[server.host] = server; lock.unlock() }
    func server(for host: String?) -> StubLibraryServer? { lock.lock(); defer { lock.unlock() }; return host.flatMap { servers[$0] } }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, body, delay) = Registry.shared.server(for: url.host)?.respond(to: url) ?? (503, Data(), 0)
        nonisolated(unsafe) let deliver = { [self] in
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) { deliver() } } else { deliver() }
    }

    override func stopLoading() {}
}
