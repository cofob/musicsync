import Foundation
import Testing
@testable import Subsonic

/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    @Test func artistInfoGenresAndRadio() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "demo", password: "sesame",
                               session: URLSession(configuration: config))
        let ok = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
        StubProtocol.replies = [
            "getArtistInfo2": #"{"subsonic-response":{"status":"ok","version":"1.16.1","artistInfo2":{"biography":"Bio","largeImageUrl":"https://img/l.jpg","similarArtist":[{"id":"ar-2","name":"Björk"},{"id":"","name":"Unknown"}]}}}"#,
            "getGenres": #"{"subsonic-response":{"status":"ok","version":"1.16.1","genres":{"genre":[{"value":"Rock","songCount":28,"albumCount":6}]}}}"#,
            "getSongsByGenre": #"{"subsonic-response":{"status":"ok","version":"1.16.1","songsByGenre":{"song":[{"id":"s-1","title":"Xtal"}]}}}"#,
            "getUser": #"{"subsonic-response":{"status":"ok","version":"1.16.1","user":{"username":"demo","adminRole":false}}}"#,
            "getInternetRadioStations": #"{"subsonic-response":{"status":"ok","version":"1.16.1","internetRadioStations":{"internetRadioStation":[{"id":"r-1","name":"Groove","streamUrl":"https://radio/groove","homePageUrl":"https://radio"}]}}}"#,
            "createInternetRadioStation": ok, "updateInternetRadioStation": ok, "deleteInternetRadioStation": ok,
        ]
        StubProtocol.log = []
        let info = try #require(try await c.getArtistInfo2(id: "ar-1"))
        #expect(info.largeImageUrl == "https://img/l.jpg" && info.similarArtist?.map(\.name) == ["Björk", "Unknown"])
        #expect(try await c.getGenres() == [Genre(value: "Rock", songCount: 28, albumCount: 6)])
        #expect(try await c.getSongsByGenre("Rock", count: 5).map(\.id) == ["s-1"])
        #expect(try await c.getUser(username: "demo").adminRole == false)
        #expect(try await c.getInternetRadioStations() == [RadioStation(id: "r-1", name: "Groove", streamUrl: "https://radio/groove", homePageUrl: "https://radio")])
        try await c.createInternetRadioStation(name: "New", streamUrl: "https://s", homePageUrl: nil)
        try await c.updateInternetRadioStation(id: "r-1", name: "Groove", streamUrl: "https://s2", homePageUrl: "https://h")
        try await c.deleteInternetRadioStation(id: "r-1")
        let calls = StubProtocol.log.map { url in
            (url.lastPathComponent, URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .filter { !["u", "s", "t", "v", "c", "f"].contains($0.name) }.map { "\($0.name)=\($0.value ?? "")" })
        }
        #expect(calls[2].1 == ["genre=Rock", "count=5", "offset=0"])
        #expect(calls[5].1 == ["name=New", "streamUrl=https://s"])
        #expect(calls[6].1 == ["id=r-1", "name=Groove", "streamUrl=https://s2", "homepageUrl=https://h"])
        #expect(calls[7].1 == ["id=r-1"])

        // No stations, and a server without the endpoint.
        StubProtocol.replies["getInternetRadioStations"] = #"{"subsonic-response":{"status":"ok","version":"1.16.1","internetRadioStations":{}}}"#
        #expect(try await c.getInternetRadioStations().isEmpty)
        StubProtocol.replies["getInternetRadioStations"] = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#
        await #expect(throws: SubsonicError.api(code: 70, message: "not found")) { try await c.getInternetRadioStations() }
    }
}

@Suite struct BiographyTests {
    @Test func stripsTagsLinksAndEntities() {
        let lastFM = #"Aphex Twin is <b>Richard&nbsp;D. James</b>,  a &quot;producer&quot; &amp; DJ.<br/>Born in 1971. <a href="https://www.last.fm/music/Aphex+Twin">Read more on Last.fm</a>"#
        #expect(ArtistInfo.plain(lastFM) == "Aphex Twin is Richard D. James, a \"producer\" & DJ.\n\nBorn in 1971.")
        #expect(ArtistInfo.plain("<p>One</p>\n<p>Two</p>") == "One\n\nTwo")
        let empty = ArtistInfo(biography: #" <a href="x">Read more on Last.fm</a> "#, largeImageUrl: nil, mediumImageUrl: nil, similarArtist: nil)
        #expect(empty.plainBiography == nil)
    }
}
