import Foundation
import Testing
@testable import Subsonic

@Suite struct LRCTests {
    @Test func parsesTimesTagsAndRepeatedLines() throws {
        let lyrics = try #require(LRC.parse("""
            [ar:Artist]
            [ti:Title]
            [offset:+250]
            [00:01.5]First
            [00:10.25][01:02.345]Chorus
            [00:05:07] <00:05.10>Word <00:05.50>timed
            [00:20.00]
            no time here
            """))
        #expect(lyrics.synced)
        #expect(lyrics.offset == -250)
        #expect(lyrics.line.map(\.start) == [1500, 5070, 10250, 20000, 62345])
        #expect(lyrics.line.map(\.value) == ["First", "Word timed", "Chorus", "", "Chorus"])
    }

    @Test func plainTextHasNoSyncedLines() throws {
        #expect(LRC.parse("just words\nno times") == nil)
        let plain = try #require(LRC.plain("\n one\ntwo \n"))
        #expect(!plain.synced && plain.line.map(\.value) == ["one", "two"] && plain.line.allSatisfy { $0.start == nil })
        #expect(LRC.plain("  \n") == nil)
    }
}

/// Serves one canned LRCLIB reply and records the requests; never touches the network.
final class LRCLIBStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LRCLIBClientTests {
    private func client(_ status: Int, _ body: String) -> LRCLIBClient {
        LRCLIBStub.status = status
        LRCLIBStub.body = body
        LRCLIBStub.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStub.self]
        return LRCLIBClient(session: URLSession(configuration: config), base: URL(string: "https://lrclib.test")!)
    }

    private func get(_ c: LRCLIBClient, album: String? = "Album", duration: Int? = 200) async throws -> StructuredLyrics? {
        try await c.lyrics(artist: "A & B", title: "Song", album: album, duration: duration)
    }

    @Test func prefersSyncedLyricsAndSendsOnlyTheSong() async throws {
        let c = client(200, #"{"id":1,"trackName":"Song","plainLyrics":"Line","syncedLyrics":"[00:01.00]Line"}"#)
        let lyrics = try await get(c)
        #expect(lyrics?.synced == true && lyrics?.line.first?.start == 1000)
        let request = try #require(LRCLIBStub.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MusicSync (https://github.com/cofob/musicsync)")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let url = try #require(request.url)
        #expect(url.host == "lrclib.test" && url.path == "/api/get")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["artist_name", "track_name", "album_name", "duration"])
        #expect(items.map(\.value) == ["A & B", "Song", "Album", "200"])
    }

    @Test func fallsBackToPlainLyrics() async throws {
        let lyrics = try await get(client(200, #"{"plainLyrics":"One\nTwo","syncedLyrics":null}"#), album: nil, duration: nil)
        #expect(lyrics?.synced == false && lyrics?.line.map(\.value) == ["One", "Two"])
        let items = LRCLIBStub.requests.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        #expect(items.map(\.name) == ["artist_name", "track_name"])
    }

    @Test func noneForMissingOrInstrumental() async throws {
        #expect(try await get(client(404, #"{"code":404,"name":"TrackNotFound"}"#)) == nil)
        #expect(try await get(client(200, #"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#)) == nil)
        #expect(try await get(client(200, #"{"plainLyrics":"","syncedLyrics":""}"#)) == nil)
    }

    @Test func serverErrorsThrow() async throws {
        await #expect(throws: SubsonicError.badStatus(500)) { try await get(client(500, "oops")) }
        await #expect(throws: DecodingError.self) { try await get(client(200, "not json")) }
    }
}
