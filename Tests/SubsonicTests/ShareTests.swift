import Foundation
import Testing
@testable import Subsonic

/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    @Test func sharesAndSong() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "demo", password: "sesame",
                               session: URLSession(configuration: config))
        c.retry = .instant
        let share = #"{"id":"sh-1","url":"https://music.example.com/share/sh-1","description":"Xtal — Aphex Twin","username":"demo","created":"2026-11-13T16:10:37Z","expires":"2027-11-13T16:10:37Z","visitCount":6,"entry":[{"id":"s-1","title":"Xtal"}]}"#
        StubProtocol.replies = [
            "getShares": #"{"subsonic-response":{"status":"ok","version":"1.16.1","shares":{"share":[\#(share)]}}}"#,
            "createShare": #"{"subsonic-response":{"status":"ok","version":"1.16.1","shares":{"share":[\#(share)]}}}"#,
            "deleteShare": #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#,
            "getSong": #"{"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"s-1","title":"Xtal","albumId":"al-1"}}}"#,
        ]
        StubProtocol.log = []
        let list = try await c.getShares()
        #expect(list.map(\.id) == ["sh-1"] && list[0].visitCount == 6 && list[0].entry?.first?.title == "Xtal")
        let created = try await c.createShare(ids: ["al-1"], description: "SAW — Aphex Twin", expires: Date(timeIntervalSince1970: 2))
        #expect(created?.url == "https://music.example.com/share/sh-1")
        try await c.deleteShare(id: "sh-1")
        #expect(try await c.getSong(id: "s-1").albumId == "al-1")
        let calls = StubProtocol.log.map { url in
            (url.lastPathComponent, URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .filter { ["id", "description", "expires"].contains($0.name) }.map { "\($0.name)=\($0.value ?? "")" })
        }
        #expect(calls.map(\.0) == ["getShares.view", "createShare.view", "deleteShare.view", "getSong.view"])
        #expect(calls[1].1 == ["id=al-1", "description=SAW — Aphex Twin", "expires=2000"])
        #expect(calls[2].1 == ["id=sh-1"])

        // Navidrome without EnableSharing, and servers without the endpoint.
        StubProtocol.replies = ["getShares": #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#,
                                "createShare": #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#]
        await #expect(throws: SubsonicError.api(code: 70, message: "not found")) { try await c.getShares() }
        #expect(try await c.createShare(ids: ["s-1"]) == nil)
    }
}
