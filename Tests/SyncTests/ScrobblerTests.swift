import Foundation
import Testing
@testable import Subsonic
@testable import Sync

@Suite struct ScrobblerTests {
    @Test func timestampsAreSpacedByTrackLength() {
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        let times = Scrobbler.timestamps(plays: 3, lastPlayed: last, duration: 200)
        #expect(times == [last, last.addingTimeInterval(-200), last.addingTimeInterval(-400)])
        #expect(Scrobbler.timestamps(plays: 2, lastPlayed: last, duration: 0).last == last.addingTimeInterval(-1))
        #expect(Scrobbler.timestamps(plays: 0, lastPlayed: last, duration: 200).isEmpty)
        #expect(Scrobbler.timestamps(plays: 5000, lastPlayed: nil, duration: 1).count == 1000)
    }

    @Test func queueSurvivesRestartAndIgnoresRepeatedSource() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("q.json")
        let request = ScrobbleRequest(songID: "s", time: Date(timeIntervalSince1970: 1_700_000_000))
        let first = Scrobbler(queueURL: url)
        await first.enqueue([request], source: Data("play counts".utf8))
        await first.enqueue([request], source: Data("play counts".utf8))
        await first.enqueue([request])
        #expect(await first.pendingCount == 2)
        #expect(await Scrobbler(queueURL: url).pendingCount == 2)
    }

    @Test func playsQueuedDuringAFlushAreKeptAndFlushesDoNotOverlap() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        SlowScrobbleProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowScrobbleProtocol.self]
        let client = SubsonicClient(baseURL: URL(string: "http://slow.test")!, username: "u", password: "p", session: URLSession(configuration: config))
        let scrobbler = Scrobbler(queueURL: dir.appendingPathComponent("q.json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await scrobbler.enqueue([ScrobbleRequest(songID: "old", time: base)])

        async let first = scrobbler.flush(client: client)
        try await Task.sleep(for: .milliseconds(100))
        await scrobbler.enqueue([ScrobbleRequest(songID: "new", time: base.addingTimeInterval(1))])
        async let second = scrobbler.flush(client: client)
        let results = await [first, second]

        #expect(results == [FlushResult(sent: 1, pending: 1), FlushResult(sent: 1, pending: 1)])
        #expect(SlowScrobbleProtocol.calls == 1)
        #expect(await scrobbler.pendingCount == 1)
        #expect(await scrobbler.flush(client: client) == FlushResult(sent: 1, pending: 0))
    }

    @Test func flushSendsBatchesOfFiftyAndKeepsFailures() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = StubServer()
        let scrobbler = Scrobbler(queueURL: dir.appendingPathComponent("q.json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await scrobbler.enqueue((0..<120).map { ScrobbleRequest(songID: "s\($0)", time: base.addingTimeInterval(Double($0))) })

        server.failScrobblesAfter = 1
        let partial = await scrobbler.flush(client: server.client)
        #expect(partial == FlushResult(sent: 50, pending: 70))

        server.failScrobblesAfter = nil
        let rest = await scrobbler.flush(client: server.client)
        #expect(rest == FlushResult(sent: 70, pending: 0))
        let calls = server.scrobbles
        #expect(calls.map(\.ids.count) == [50, 50, 20])
        #expect(calls[0].ids.first == "s0" && calls[0].times.count == 50)
        #expect(calls.allSatisfy { $0.submission })
    }
}

/// Answers every scrobble after a short delay, so tests can act while a flush is in flight.
final class SlowScrobbleProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var calls: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(StubServer.ok.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
