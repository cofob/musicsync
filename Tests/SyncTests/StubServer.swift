import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Subsonic

/// An in-process Subsonic server behind a `URLProtocol`; never touches the network.
final class StubServer: @unchecked Sendable {
    struct Scrobble { var ids: [String]; var times: [Date]; var submission: Bool }

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var replies: [String: String] = [:]
    private var files: [String: URL] = [:]
    private var coverData: Data?
    private var _scrobbles: [Scrobble] = []
    private var scrobbleCalls = 0
    private var _failScrobblesAfter: Int?
    private(set) var requests: [String] = []
    /// Makes every download slow, so tests can cancel mid-run.
    var downloadDelay: TimeInterval = 0

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    var client: SubsonicClient {
        Registry.shared.register(self)
        return SubsonicClient(baseURL: URL(string: "http://\(host)")!, username: "demo", password: "pw", session: session)
    }

    // MARK: Setup

    /// `key` is the method, or `method:id` for per-object replies.
    func reply(_ key: String, _ json: String) { locked { replies[key] = json } }
    func serve(songID: String, file: URL) { locked { files[songID] = file } }
    func serveCover(_ data: Data) { locked { coverData = data } }
    var scrobbles: [Scrobble] { locked { _scrobbles } }
    var failScrobblesAfter: Int? {
        get { locked { _failScrobblesAfter } }
        set { locked { _failScrobblesAfter = newValue; scrobbleCalls = 0 } }
    }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Serving

    fileprivate func respond(to url: URL) -> (status: Int, body: Data) {
        let method = url.lastPathComponent.replacingOccurrences(of: ".view", with: "")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = items.first { $0.name == "id" }?.value
        return locked {
            requests.append(method)
            switch method {
            case "download":
                if downloadDelay > 0 { Thread.sleep(forTimeInterval: downloadDelay) }
                guard let id, let file = files[id], let data = try? Data(contentsOf: file) else { return (404, Data()) }
                return (200, data)
            case "getCoverArt":
                return coverData.map { (200, $0) } ?? (404, Data())
            case "scrobble":
                scrobbleCalls += 1
                if let limit = _failScrobblesAfter, scrobbleCalls > limit { return (200, Data(Self.failed.utf8)) }
                let times = items.filter { $0.name == "time" }.compactMap { Double($0.value ?? "") }.map { Date(timeIntervalSince1970: $0 / 1000) }
                _scrobbles.append(Scrobble(ids: items.filter { $0.name == "id" }.compactMap(\.value), times: times,
                                           submission: items.first { $0.name == "submission" }?.value == "true"))
                return (200, Data(Self.ok.utf8))
            default:
                let body = id.flatMap { replies["\(method):\($0)"] } ?? replies[method]
                return (200, Data((body ?? Self.failed).utf8))
            }
        }
    }

    static let ok = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
    static let failed = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#

    static func albumReply(_ album: [String: Any]) -> String {
        reply(["album": album])
    }

    static func reply(_ body: [String: Any]) -> String {
        var inner: [String: Any] = ["status": "ok", "version": "1.16.1"]
        inner.merge(body) { $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["subsonic-response": inner]), as: UTF8.self)
    }
}

final class Registry: @unchecked Sendable {
    static let shared = Registry()
    private let lock = NSLock()
    private var servers: [String: StubServer] = [:]

    func register(_ server: StubServer) { lock.lock(); servers[server.host] = server; lock.unlock() }
    func server(for host: String?) -> StubServer? { lock.lock(); defer { lock.unlock() }; return host.flatMap { servers[$0] } }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, body) = Registry.shared.server(for: url.host)?.respond(to: url) ?? (503, Data())
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A square PNG with a gradient, for cover art.
func makeCoverPNG(size: Int = 600) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setFillColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}
