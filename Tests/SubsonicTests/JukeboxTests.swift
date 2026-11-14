import Foundation
import Testing
@testable import Subsonic

/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    private static func ok(_ body: String) -> String { #"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"# }

    private func jukeboxClient() -> SubsonicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "demo", password: "sesame",
                              session: URLSession(configuration: config))
    }

    @Test func jukeboxActions() async throws {
        let c = jukeboxClient()
        StubProtocol.replies = ["jukeboxControl": Self.ok(#""jukeboxStatus":{"currentIndex":1,"playing":true,"gain":0.75,"position":42}"#)]
        StubProtocol.log = []
        let status = try await c.jukebox(.status)
        #expect(status == JukeboxStatus(currentIndex: 1, playing: true, gain: 0.75, position: 42))
        let actions: [JukeboxAction] = [.start, .stop, .clear, .shuffle, .skip(index: 2, offset: -5), .set(["a", "b"]), .add(["c"]),
                                        .remove(3), .setGain(0.3), .setGain(7), .setGain(.nan)]
        for action in actions { _ = try await c.jukebox(action) }
        let queries = StubProtocol.log.dropFirst().map { url in
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .filter { ["action", "index", "offset", "id", "gain"].contains($0.name) }.map { "\($0.name)=\($0.value ?? "")" }
        }
        #expect(queries == [["action=start"], ["action=stop"], ["action=clear"], ["action=shuffle"],
                            ["action=skip", "index=2", "offset=0"], ["action=set", "id=a", "id=b"], ["action=add", "id=c"],
                            ["action=remove", "index=3"], ["action=setGain", "gain=0.30"], ["action=setGain", "gain=1.00"],
                            ["action=setGain", "gain=0.00"]])
        #expect(StubProtocol.log.allSatisfy { $0.lastPathComponent == "jukeboxControl.view" })
    }

    @Test func jukeboxPlaylist() async throws {
        let c = jukeboxClient()
        StubProtocol.replies = ["jukeboxControl": Self.ok(#""jukeboxPlaylist":{"currentIndex":0,"playing":false,"gain":0.5,"position":0,"entry":[{"id":"s-1","title":"Xtal"},{"id":"s-2","title":"Tha"}]}"#)]
        StubProtocol.log = []
        let list = try await c.jukeboxPlaylist()
        #expect(list.songs.map(\.id) == ["s-1", "s-2"] && list.status == JukeboxStatus(currentIndex: 0, playing: false, gain: 0.5, position: 0))
        #expect(StubProtocol.log.first?.query?.contains("action=get") == true)
        // Empty: Navidrome sends no `entry` for an empty playlist.
        StubProtocol.replies["jukeboxControl"] = Self.ok(#""jukeboxPlaylist":{"currentIndex":-1,"playing":false,"gain":0.5,"position":0}"#)
        #expect(try await c.jukeboxPlaylist().songs.isEmpty)
    }

    @Test func jukeboxErrors() async {
        let c = jukeboxClient()
        // Navidrome with the jukebox off, a user without the role, a server without the endpoint.
        StubProtocol.replies = ["jukeboxControl": #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"Jukebox is disabled"}}}"#]
        await #expect(throws: SubsonicError.api(code: 50, message: "Jukebox is disabled")) { try await c.jukebox(.status) }
        StubProtocol.replies = ["jukeboxControl": #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Not found"}}}"#]
        await #expect(throws: SubsonicError.self) { try await c.jukeboxPlaylist() }
        StubProtocol.replies = ["jukeboxControl": Self.ok("")]
        await #expect(throws: SubsonicError.self) { try await c.jukebox(.start) }
    }

    @Test func jukeboxJunkNeverTraps() async throws {
        let c = jukeboxClient()
        let bodies = ["", "{}", "null", "garbage", #"{"subsonic-response":{"status":"failed"}}"#,
                      Self.ok(#""jukeboxStatus":null"#), Self.ok(#""jukeboxStatus":[]"#), Self.ok(#""jukeboxStatus":{}"#),
                      Self.ok(#""jukeboxStatus":{"currentIndex":"1","playing":"yes","gain":"loud","position":1e300}"#),
                      Self.ok(#""jukeboxStatus":{"currentIndex":-9223372036854775808,"gain":-1e300,"position":-1}"#),
                      Self.ok(#""jukeboxPlaylist":{"entry":[null]}"#), Self.ok(#""jukeboxPlaylist":{"entry":{"id":"s"}}"#),
                      Self.ok(#""jukeboxPlaylist":{"entry":[{"title":"no id"}]}"#)]
        for body in bodies + bodies.map({ String($0.prefix($0.count / 2)) }) {
            StubProtocol.replies = ["jukeboxControl": body]
            _ = try? await c.jukebox(.status)
            _ = try? await c.jukeboxPlaylist()
        }
        StubProtocol.replies = ["jukeboxControl": Self.ok(#""jukeboxStatus":{"currentIndex":-9223372036854775808,"position":-1}"#)]
        #expect(try await c.jukebox(.status) == JukeboxStatus(currentIndex: .min, playing: nil, gain: nil, position: -1))
    }
}

@Suite struct JukeboxTargetTests {
    @Test func mapsQueueEntries() {
        let queue: [String?] = ["a", nil, "b", "c"]
        #expect(JukeboxTarget(queue: queue, current: 2, playing: true) == JukeboxTarget(ids: ["a", "b", "c"], index: 1, playing: true))
        #expect(JukeboxTarget(queue: queue, current: 1, playing: true).index == nil)  // a local file
        #expect(JukeboxTarget(queue: queue, current: 9, playing: true).index == nil)
        #expect(JukeboxTarget(queue: [], current: nil, playing: false).ids.isEmpty)
        #expect([0, 1, 2, 3, -1, .min, .max].map { JukeboxTarget.queueIndex(of: $0, in: queue) } == [0, 2, 3, nil, nil, nil, nil])
    }

    @Test func plansActions() {
        let playing = JukeboxTarget(ids: ["a", "b"], index: 0, playing: true)
        // Nothing sent yet: the whole state.
        #expect(playing.actions(from: nil, position: 30, restart: false) == [.set(["a", "b"]), .skip(index: 0, offset: 30), .start])
        #expect(playing.actions(from: playing, position: 30, restart: false).isEmpty)
        var paused = playing
        paused.playing = false
        #expect(paused.actions(from: playing, position: 30, restart: false) == [.stop])
        #expect(playing.actions(from: paused, position: 30, restart: false) == [.start])
        #expect(playing.actions(from: playing, position: 12, restart: true) == [.skip(index: 0, offset: 12), .start])
        var next = playing
        next.index = 1
        #expect(next.actions(from: playing, position: 0, restart: false) == [.skip(index: 1, offset: 0), .start])
        // A queue edit keeps the song and its position.
        var longer = playing
        longer.ids.append("c")
        #expect(longer.actions(from: playing, position: 61, restart: false) == [.set(["a", "b", "c"]), .skip(index: 0, offset: 61), .start])
        // Nothing current: a new list only, or a stop.
        let none = JukeboxTarget(ids: ["a"], index: nil, playing: true)
        #expect(none.actions(from: JukeboxTarget(ids: ["a"], index: 0, playing: true), position: 0, restart: true) == [.stop])
        #expect(none.actions(from: nil, position: 0, restart: true) == [.set(["a"])])
        #expect(JukeboxTarget(ids: ["a"], index: 5, playing: true).actions(from: nil, position: 0, restart: true) == [.set(["a"])])
    }
}
