import Foundation
import Testing
@testable import Subsonic

extension RetryPolicy {
    /// The standard tries without the waits, so tests stay fast.
    static let instant = RetryPolicy(attempts: RetryPolicy.standard.attempts, sleep: { _ in })
}

/// Answers each request with the next scripted reply; the last one repeats.
final class ScriptProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case ok(String), status(Int), drop, timeout }
    nonisolated(unsafe) static var script: [Reply] = []
    nonisolated(unsafe) static var methods: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.methods.append(url.lastPathComponent.replacingOccurrences(of: ".view", with: ""))
        let reply = Self.script.count > 1 ? Self.script.removeFirst() : Self.script.first ?? .status(500)
        var status = 200, body = Data()
        switch reply {
        case .drop: return client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) ?? ()
        case .timeout: return client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) ?? ()
        case .status(let code): status = code
        case .ok(let text): body = Data(text.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The waits the policy asked for, in order.
final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Duration] = []
    var all: [Duration] { lock.withLock { list } }
    func add(_ d: Duration) { lock.withLock { list.append(d) } }
}

@Suite(.serialized) struct RetryTests {
    static let ping = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
    static let album = #"{"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"a","name":"A"}}}"#

    private func client(_ script: [ScriptProtocol.Reply], waits: Waits = Waits()) -> SubsonicClient {
        ScriptProtocol.script = script
        ScriptProtocol.methods = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptProtocol.self]
        var c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "u", password: "p",
                               session: URLSession(configuration: config))
        c.retry = RetryPolicy(attempts: 4, sleep: { waits.add($0) }, random: { 0 })
        return c
    }

    @Test func transientErrorsAreTriedAgainWithGrowingWaits() async throws {
        let waits = Waits()
        let c = client([.drop, .status(500), .ok("{broken"), .ok(Self.album)], waits: waits)
        #expect(try await c.getAlbum(id: "a").name == "A")
        #expect(ScriptProtocol.methods == ["getAlbum", "getAlbum", "getAlbum", "getAlbum"])
        #expect(waits.all == [.milliseconds(500), .seconds(1), .seconds(2)])
    }

    @Test func givesUpAfterTheLastTry() async {
        let waits = Waits()
        let c = client([.timeout], waits: waits)
        await #expect(throws: URLError.self) { try await c.ping() }
        #expect(ScriptProtocol.methods.count == 4)
        #expect(waits.all.count == 3)
    }

    @Test func finalErrorsAreNotTriedAgain() async {
        let refused = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong"}}}"#
        let missing = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Not found"}}}"#
        for reply in [ScriptProtocol.Reply.ok(refused), .ok(missing), .status(404), .status(401)] {
            let c = client([reply])
            await #expect(throws: SubsonicError.self) { try await c.getAlbum(id: "a") }
            #expect(ScriptProtocol.methods.count == 1)
        }
    }

    @Test func writesAreSentOnce() async {
        let c = client([.drop, .drop, .ok(Self.ping)])
        await #expect(throws: URLError.self) { try await c.star(ids: ["s"]) }
        await #expect(throws: URLError.self) { try await c.scrobble(ids: ["s"]) }
        #expect(ScriptProtocol.methods == ["star", "scrobble"])
    }

    @Test func cancellationStopsTheRetries() async {
        let c = client([.drop])
        let task = Task { try await c.ping() }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(ScriptProtocol.methods.count <= 1)
    }

    @Test func waitsAreCappedAndJittered() {
        let policy = RetryPolicy(attempts: 9, base: .seconds(1), cap: .seconds(4), random: { 0.5 })
        #expect((1...5).map(policy.delay(after:)) == [.milliseconds(750), .milliseconds(1500), .seconds(3), .seconds(3), .seconds(3)])
    }

    @Test func classification() {
        #expect(RetryPolicy.isRead("getAlbumList2") && RetryPolicy.isRead("search3") && RetryPolicy.isRead("ping"))
        #expect(!RetryPolicy.isRead("star") && !RetryPolicy.isRead("createShare") && !RetryPolicy.isRead("updatePlaylist"))
        #expect(RetryPolicy.isTransient(SubsonicError.badStatus(503)) && !RetryPolicy.isTransient(SubsonicError.badStatus(404)))
        #expect(!RetryPolicy.isTransient(CancellationError()) && !RetryPolicy.isTransient(URLError(.cancelled)))
        #expect(!RetryPolicy.isTransientBinary(SubsonicError.badResponse("<error code=70>")))
    }
}
