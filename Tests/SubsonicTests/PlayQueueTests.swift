import Foundation
import Testing
@testable import Subsonic

/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    @Test func playQueue() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "demo", password: "sesame",
                               session: URLSession(configuration: config))
        c.retry = .instant
        StubProtocol.replies = [
            "getPlayQueue": #"{"subsonic-response":{"status":"ok","version":"1.16.1","playQueue":{"entry":[{"id":"s-1","title":"Xtal"},{"id":"s-2","title":"Tha"}],"current":"s-2","position":61500,"username":"demo","changed":"2026-11-14T07:47:28.669536271Z","changedBy":"feishin"}}}"#,
            "savePlayQueue": #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#,
        ]
        StubProtocol.log = []
        let queue = try #require(try await c.getPlayQueue())
        #expect(queue.songs.map(\.id) == ["s-1", "s-2"] && queue.current == "s-2" && queue.position == 61500)
        #expect(queue.changedBy == "feishin" && queue.changedDate == Date(timeIntervalSince1970: 1_794_642_448))
        try await c.savePlayQueue(ids: ["s-1", "s-2"], current: "s-2", position: 1234)
        let save = try #require(URLComponents(url: StubProtocol.log[1], resolvingAgainstBaseURL: false)?.queryItems)
        #expect(StubProtocol.log.map(\.lastPathComponent) == ["getPlayQueue.view", "savePlayQueue.view"])
        #expect(save.filter { ["id", "current", "position"].contains($0.name) }.map { "\($0.name)=\($0.value ?? "")" }
            == ["id=s-1", "id=s-2", "current=s-2", "position=1234"])
        #expect(save.first { $0.name == "c" }?.value == SubsonicClient.clientName)

        // No queue yet: Navidrome sends an empty object, others nothing.
        StubProtocol.replies["getPlayQueue"] = #"{"subsonic-response":{"status":"ok","version":"1.16.1","playQueue":{}}}"#
        #expect(try await c.getPlayQueue()?.current == nil)
        StubProtocol.replies["getPlayQueue"] = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
        #expect(try await c.getPlayQueue() == nil)
    }
}
