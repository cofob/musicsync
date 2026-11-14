import Foundation
import Testing
@testable import Subsonic

/// Junk replies: each call either decodes or throws `SubsonicError`, and never traps.
/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    private static func ok(_ body: String) -> String { #"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"# }

    /// Valid JSON with odd values: nulls, wrong types, huge and negative numbers, empty lists, unicode.
    static let oddBodies = [
        "", "{}", "[]", "null", "garbage", #"{"subsonic-response":null}"#, #"{"subsonic-response":[]}"#,
        #"{"subsonic-response":{"status":"failed"}}"#, #"{"subsonic-response":{"status":"failed","error":{"code":"x"}}}"#,
        ok(#""album":null"#), ok(#""album":[]"#), ok(#""album":{"id":1,"name":"x"}"#), ok(#""album":{"name":"no id"}"#),
        ok(#""album":{"id":"a","name":"x","song":[{"id":"s","title":"t","duration":1e300}]}"#),
        ok(#""album":{"id":"a","name":"x","song":[{"id":"s","title":"t","duration":9223372036854775807,"track":-5}]}"#),
        ok(#""album":{"id":"a","name":"x","song":[{"id":"s","title":"t","duration":"200"}]}"#),
        ok(#""album":{"id":"a","name":"x","song":null}"#),
        ok(#""album":{"id":"\u0000😀","name":"‮é𝄞","year":-1,"songCount":-9223372036854775808}"#),
        ok(#""albumList2":{"album":{"id":"a","name":"x"}}"#), ok(#""albumList2":[]"#),
        ok(#""artists":{"index":[{"name":"A","artist":null},{"name":"B","artist":[]}]}"#),
        ok(#""searchResult3":{"song":[null]}"#), ok(#""searchResult3":{}"#), ok(#""searchResult3":7"#),
        ok(#""playlist":{"id":"p","name":"x","entry":[{"id":"s"}]}"#),
        ok(#""scanStatus":{"scanning":"yes"}"#), ok(#""scanStatus":{"scanning":false,"count":1e40}"#),
        ok(#""lyricsList":{"structuredLyrics":[{"synced":true,"line":[{"start":-1e3,"value":""}]}]}"#),
        ok(#""playQueue":{"entry":[{"id":"s","title":"t"}],"position":-9223372036854775808,"changed":"never"}"#),
        ok(#""genres":{"genre":[{"value":null}]}"#), ok(#""openSubsonicExtensions":[{"name":"x","versions":["1"]}]"#),
        ok(#""podcasts":{"channel":[{"id":"c","episode":[{"id":"e","streamId":"","duration":-1,"publishDate":"soon"}]}]}"#),
        ok(#""podcasts":{"channel":{"id":"c"}}"#), ok(#""podcasts":{"channel":[{"title":"no id"}]}"#),
        ok(#""newestPodcasts":{"episode":[null]}"#), ok(#""newestPodcasts":[]"#),
        ok(#""bookmarks":{"bookmark":[{"position":1e300,"entry":{"id":"s","title":"t"}}]}"#),
        ok(#""bookmarks":{"bookmark":[{"position":5,"entry":null}]}"#), ok(#""bookmarks":{"bookmark":[{"position":"5","entry":{"id":"s","title":"t"}}]}"#),
    ]

    private func everyCall(_ c: SubsonicClient) async {
        _ = try? await c.ping()
        _ = try? await c.getAlbum(id: "a")
        _ = try? await c.getAlbumList2(type: "newest")
        _ = try? await c.getArtists()
        _ = try? await c.getArtist(id: "ar")
        _ = try? await c.search3("x")
        _ = try? await c.getPlaylist(id: "p")
        _ = try? await c.getPlaylists()
        _ = try? await c.getScanStatus()
        _ = try? await c.getLyricsBySongId(id: "s")
        _ = try? await c.getStarred2()
        _ = try? await c.getPlayQueue()
        _ = try? await c.getGenres()
        _ = try? await c.getOpenSubsonicExtensions()
        if let channels = try? await c.getPodcasts() { _ = channels.flatMap(\.episodes).map { ($0.song, $0.date) } }
        _ = try? await c.getNewestPodcasts()
        _ = try? await c.getBookmarks()
        if let song = try? JSONDecoder().decode(Song.self, from: Data(#"{"id":"s","title":"t","artist":"a"}"#.utf8)) {
            _ = await c.plainLyrics(for: song)
        }
    }

    @Test func junkRepliesNeverTrap() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "u", password: "p",
                               session: URLSession(configuration: config))
        c.retry = .instant
        var random = SystemRandomNumberGenerator()
        let mangled = Self.oddBodies.map { body in
            // The same replies cut short at a random byte.
            String(body.prefix(body.isEmpty ? 0 : Int.random(in: 0..<body.count, using: &random)))
        }
        for body in Self.oddBodies + mangled {
            StubProtocol.replies = Dictionary(uniqueKeysWithValues: ["ping", "getAlbum", "getAlbumList2", "getArtists", "getArtist", "search3",
                                                                    "getPlaylist", "getPlaylists", "getScanStatus", "getLyricsBySongId",
                                                                    "getLyrics", "getStarred2", "getPlayQueue", "getGenres",
                                                                    "getOpenSubsonicExtensions", "getPodcasts", "getNewestPodcasts",
                                                                    "getBookmarks"].map { ($0, body) })
            await everyCall(c)
        }
    }

    @Test func oddValuesDecodeOrFail() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "u", password: "p",
                               session: URLSession(configuration: config))
        c.retry = .instant
        StubProtocol.replies = ["getAlbum": Self.ok(#""album":{"id":"a","name":"x","song":[{"id":"s","title":"t","duration":9223372036854775807}]}"#)]
        #expect(try await c.getAlbum(id: "a").song?.first?.duration == .max)
        StubProtocol.replies = ["getAlbum": Self.ok(#""album":{"id":"a","name":"x","song":[{"id":"s","title":"t","duration":1e300}]}"#)]
        await #expect(throws: SubsonicError.self) { try await c.getAlbum(id: "a") }
        StubProtocol.replies = ["getArtists": Self.ok(#""artists":{"index":[{"name":"A","artist":null},{"name":"B","artist":[]}]}"#)]
        #expect(try await c.getArtists().flatMap { $0.artist ?? [] }.isEmpty)
    }
}
