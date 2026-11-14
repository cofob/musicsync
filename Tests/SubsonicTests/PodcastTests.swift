import Foundation
import Testing
@testable import Subsonic

/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    private static let ok = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
    private static let episode = #"{"id":"ep-1","streamId":"st-1","channelId":"ch-1","title":"Pilot","description":"The first one","publishDate":"2026-11-01T08:30:00.000Z","status":"completed","duration":3600,"coverArt":"pod-ch-1","album":"Night Talks","artist":"Ann","size":5000,"suffix":"mp3","bitRate":128,"playCount":1}"#

    @Test func podcasts() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "demo", password: "sesame",
                               session: URLSession(configuration: config))
        c.retry = .instant
        StubProtocol.replies = [
            "getPodcasts": #"{"subsonic-response":{"status":"ok","version":"1.16.1","podcasts":{"channel":[{"id":"ch-1","url":"https://example.com/feed","title":"Night Talks","description":"Talks","coverArt":"pod-ch-1","status":"completed","episode":[\#(Self.episode),{"id":"ep-2","channelId":"ch-1","title":"Next","status":"new"}]}]}}}"#,
            "getNewestPodcasts": #"{"subsonic-response":{"status":"ok","version":"1.16.1","newestPodcasts":{"episode":[\#(Self.episode)]}}}"#,
            "getBookmarks": #"{"subsonic-response":{"status":"ok","version":"1.16.1","bookmarks":{"bookmark":[{"position":61500,"username":"demo","comment":"","created":"2026-11-14T07:00:00Z","changed":"2026-11-14T07:00:00Z","entry":{"id":"st-1","title":"Pilot","duration":3600}}]}}}"#,
        ]
        for method in ["createPodcastChannel", "deletePodcastChannel", "refreshPodcasts", "downloadPodcastEpisode",
                       "deletePodcastEpisode", "createBookmark", "deleteBookmark"] { StubProtocol.replies[method] = Self.ok }
        StubProtocol.log = []

        let channels = try await c.getPodcasts()
        #expect(channels.map(\.id) == ["ch-1"] && channels[0].name == "Night Talks" && channels[0].episodes.count == 2)
        let first = channels[0].episodes[0], second = channels[0].episodes[1]
        #expect(first.date == Date(timeIntervalSince1970: 1_793_521_800))
        let song = try #require(first.song)
        #expect(song.id == "st-1" && song.title == "Pilot" && song.duration == 3600 && song.coverArt == "pod-ch-1" && song.album == "Night Talks")
        #expect(second.song == nil && second.date == nil)  // not on the server yet
        #expect(try await c.getNewestPodcasts(count: 5).map(\.id) == ["ep-1"])
        try await c.createPodcastChannel(url: "https://example.com/feed?x=1&y")
        try await c.deletePodcastChannel(id: "ch-1")
        try await c.refreshPodcasts()
        try await c.downloadPodcastEpisode(id: "ep-2")
        try await c.deletePodcastEpisode(id: "ep-1")
        let marks = try await c.getBookmarks()
        #expect(marks.count == 1 && marks[0].position == 61500 && marks[0].entry.id == "st-1")
        try await c.createBookmark(id: "st-1", position: 1234)
        try await c.deleteBookmark(id: "st-1")

        let calls = StubProtocol.log.map { url in
            (url.lastPathComponent, URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .filter { ["id", "url", "count", "position", "includeEpisodes"].contains($0.name) }.map { "\($0.name)=\($0.value ?? "")" })
        }
        #expect(calls.map(\.0) == ["getPodcasts.view", "getNewestPodcasts.view", "createPodcastChannel.view", "deletePodcastChannel.view",
                                   "refreshPodcasts.view", "downloadPodcastEpisode.view", "deletePodcastEpisode.view", "getBookmarks.view",
                                   "createBookmark.view", "deleteBookmark.view"])
        #expect(calls[0].1 == ["includeEpisodes=true"] && calls[1].1 == ["count=5"])
        #expect(calls[2].1 == ["url=https://example.com/feed?x=1&y"] && calls[3].1 == ["id=ch-1"] && calls[4].1.isEmpty)
        #expect(calls[5].1 == ["id=ep-2"] && calls[6].1 == ["id=ep-1"])
        #expect(calls[8].1 == ["id=st-1", "position=1234"] && calls[9].1 == ["id=st-1"])

        // Empty lists: some servers send an empty object, others nothing.
        StubProtocol.replies["getPodcasts"] = #"{"subsonic-response":{"status":"ok","version":"1.16.1","podcasts":{}}}"#
        StubProtocol.replies["getBookmarks"] = Self.ok
        StubProtocol.replies["getNewestPodcasts"] = #"{"subsonic-response":{"status":"ok","version":"1.16.1","newestPodcasts":{}}}"#
        #expect(try await c.getPodcasts(includeEpisodes: false, id: "ch-1").isEmpty)
        #expect(try await c.getBookmarks().isEmpty)
        #expect(try await c.getNewestPodcasts().isEmpty)
        #expect(StubProtocol.log.last.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "count" && $0.value == "20" } } == true)

        // Servers without podcasts.
        StubProtocol.replies["getPodcasts"] = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"Not authorized"}}}"#
        await #expect(throws: SubsonicError.api(code: 50, message: "Not authorized")) { try await c.getPodcasts() }
        StubProtocol.replies["getPodcasts"] = "This endpoint is not implemented, but may be in future releases"
        await #expect(throws: SubsonicError.self) { try await c.getPodcasts() }
    }
}
