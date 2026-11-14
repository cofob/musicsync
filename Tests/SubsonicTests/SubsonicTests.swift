import Foundation
import Testing
@testable import Subsonic

private func client(_ base: String = "https://music.example.com", session: URLSession = .shared) -> SubsonicClient {
    SubsonicClient(baseURL: URL(string: base)!, username: "demo", password: "sesame", session: session)
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }) { a, _ in a }
}

private func decode<T: Decodable>(_ json: String, key: String?, as: T.Type = T.self) throws -> (Head, T?) {
    let decoder = JSONDecoder()
    decoder.userInfo[Reply<T>.bodyKey] = key
    let reply = try decoder.decode(Reply<T>.self, from: Data(json.utf8))
    return (reply.head, reply.body)
}

@Suite struct DecodingTests {
    @Test func artists() throws {
        let (head, body) = try decode(Fixtures.artists, key: "artists", as: ArtistsBody.self)
        #expect(head.info.type == "navidrome")
        #expect(head.info.openSubsonic == true)
        let artists = try #require(body?.index).flatMap { $0.artist ?? [] }
        #expect(artists.map(\.name) == ["Aphex Twin", "Björk"])
        #expect(artists[0].musicBrainzId == "f22942a1-6f70-4f48-866e-238cb2308fbd")
        #expect(artists[1].coverArt == nil)
    }

    @Test func albumWithSongs() throws {
        let album = try #require(decode(Fixtures.album, key: "album", as: Album.self).1)
        #expect(album.year == 1992)
        #expect(album.isCompilation == false)
        #expect(album.created == "2024-02-01T10:00:00.123456789Z")
        let songs = try #require(album.song)
        #expect(songs.count == 2)
        #expect(songs[0].replayGain?.albumGain == -7.25)
        #expect(songs[0].bitDepth == 24)
        #expect(songs[0].sourceFormat == "FLAC 24/96")
        #expect(songs[1].sourceFormat == "MP3 320")
        #expect(songs[1].replayGain == nil)
    }

    @Test func formatWithFractionalRate() {
        let song = try? decode(#"{"subsonic-response":{"status":"ok","version":"1","song":{"id":"1","title":"t","suffix":"flac","bitDepth":16,"samplingRate":44100}}}"#, key: "song", as: Song.self).1
        #expect(song?.sourceFormat == "FLAC 16/44.1")
    }

    @Test func albumListAndEmptyList() throws {
        #expect(try decode(Fixtures.albumList, key: "albumList2", as: AlbumListBody.self).1?.album?.count == 1)
        #expect(try decode(Fixtures.emptyAlbumList, key: "albumList2", as: AlbumListBody.self).1?.album == nil)
    }

    @Test func playlists() throws {
        let list = try #require(decode(Fixtures.playlists, key: "playlists", as: PlaylistsBody.self).1?.playlist)
        #expect(list.first?.isPublic == true)
        #expect(list.first?.songCount == 12)
    }

    @Test func searchMissingSectionsAreEmpty() throws {
        let result = try #require(decode(Fixtures.search, key: "searchResult3", as: SearchResult3.self).1)
        #expect(result.artist.count == 1)
        #expect(result.album.isEmpty)
        #expect(result.song.first?.title == "Xtal")
    }

    @Test func scanStatusAndExtensions() throws {
        let scan = try #require(decode(Fixtures.scanStatus, key: "scanStatus", as: ScanStatus.self).1)
        #expect(scan.lastScan == "2024-05-01T12:00:00Z")
        #expect(scan.scanning == false)
        let ext = try #require(decode(Fixtures.extensions, key: "openSubsonicExtensions", as: [OpenSubsonicExtension].self).1)
        #expect(ext.map(\.name) == ["transcodeOffset", "formPost"])
    }

    @Test func failedResponse() throws {
        let (head, body) = try decode(Fixtures.failed, key: "album", as: Album.self)
        #expect(head.status == "failed")
        #expect(head.error?.code == 40)
        #expect(body == nil)
    }
}

@Suite struct URLTests {
    @Test func tokenKnownVector() {
        #expect(SubsonicClient.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
    }

    @Test func authParametersAreValid() throws {
        let q = query(client().url("ping"))
        #expect(q["u"] == "demo")
        #expect(q["v"] == "1.16.1")
        #expect(q["c"] == "MusicSync")
        #expect(q["f"] == "json")
        let salt = try #require(q["s"])
        #expect(q["t"] == SubsonicClient.token(password: "sesame", salt: salt))
    }

    @Test func saltIsFreshPerURL() {
        let c = client()
        #expect(query(c.url("ping"))["s"] != query(c.url("ping"))["s"])
    }

    @Test func coverArtURL() {
        let url = client().coverArtURL(id: "al-1", size: 320)
        #expect(url.path == "/rest/getCoverArt.view")
        let q = query(url)
        #expect(q["id"] == "al-1")
        #expect(q["size"] == "320")
        #expect(q["square"] == "true")
        #expect(q["f"] == nil)
    }

    @Test func streamURL() {
        let q = query(client().streamURL(id: "s-1", format: "mp3", maxBitRate: 320))
        #expect(q["id"] == "s-1")
        #expect(q["format"] == "mp3")
        #expect(q["maxBitRate"] == "320")
        #expect(query(client().streamURL(id: "s-1"))["format"] == nil)
    }

    @Test func baseURLWithPathAndEscaping() {
        let url = client("https://example.com/navidrome").url("search3", [("query", "a&b c+d")])
        #expect(url.path == "/navidrome/rest/search3.view")
        #expect(url.absoluteString.contains("query=a%26b%20c%2Bd"))
        #expect(query(url)["query"] == "a&b c+d")
    }
}

/// Serves canned replies per request path.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.lastPathComponent.replacingOccurrences(of: ".view", with: "")
        let body = Self.replies[name] ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ClientTests {
    private func stubbed() -> SubsonicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return client(session: URLSession(configuration: config))
    }

    @Test func fetchesAlbum() async throws {
        StubProtocol.replies = ["getAlbum": Fixtures.album, "ping": Fixtures.extensions]
        let c = stubbed()
        let album = try await c.getAlbum(id: "al-1")
        #expect(album.song?.count == 2)
        #expect(try await c.ping().openSubsonic == true)
    }

    @Test func fetchesCoverArtBytes() async throws {
        let c = stubbed()
        StubProtocol.replies = ["getCoverArt": "PNGDATA"]
        #expect(try await c.coverArt(id: "al-1", size: 320) == Data("PNGDATA".utf8))
    }

    @Test func fetchesLyricsAndStarred() async throws {
        StubProtocol.replies = [
            "getLyricsBySongId": #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"lang":"eng","synced":true,"offset":-100,"line":[{"start":0,"value":"Hi"},{"start":1500,"value":"There"}]}]}}}"#,
            "getLyrics": #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyrics":{"artist":"A","title":"T","value":"plain"}}}"#,
            "getStarred2": #"{"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{"song":[{"id":"s-1","title":"Xtal"}]}}}"#,
        ]
        let c = stubbed()
        let lyrics = try await c.getLyricsBySongId(id: "s-1")
        #expect(lyrics.first?.synced == true)
        #expect(lyrics.first?.line.map(\.start) == [0, 1500])
        #expect(try await c.getLyrics(artist: "A", title: "T").value == "plain")
        let starred = try await c.getStarred2()
        #expect(starred.song.map(\.id) == ["s-1"] && starred.album.isEmpty)
        StubProtocol.replies["getLyricsBySongId"] = #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{}}}"#
        #expect(try await c.getLyricsBySongId(id: "s-2").isEmpty)
    }

    @Test func genericRequestAndMutations() async throws {
        let ok = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
        StubProtocol.replies = ["star": ok, "unstar": ok, "updatePlaylist": ok, "getAlbum": Fixtures.album, "search3": Fixtures.search]
        let c = stubbed()
        let album: Album? = try await c.request("getAlbum", key: "album", [("id", "al-1")])
        #expect(album?.song?.count == 2)
        let none: Empty? = try await c.request("star", key: nil, [("id", "s-1")])
        #expect(none == nil)
        try await c.star(ids: ["s-1"], albumIds: ["al-1"], artistIds: ["ar-1"])
        try await c.unstar(ids: ["s-1"])
        try await c.updatePlaylist(id: "pl-1", songIdsToAdd: ["s-1"], songIndexesToRemove: [0, 2])
        #expect(try await c.search3("x", songOffset: 50).song.count == 1)
        StubProtocol.replies["star"] = Fixtures.failed
        await #expect(throws: SubsonicError.api(code: 40, message: "Wrong username or password")) { try await c.star(ids: ["s-1"]) }
    }

    @Test func publicURLCarriesParameters() {
        let q = query(client().url("star", [("id", "s-1"), ("albumId", "al-1")]))
        #expect(q["id"] == "s-1" && q["albumId"] == "al-1" && q["f"] == "json" && q["t"] != nil)
    }

    @Test func copiesWithReplacedLists() throws {
        let album = try #require(decode(Fixtures.album, key: "album", as: Album.self).1)
        let bare = album.withSongs(nil)
        #expect(bare.song == nil && bare.id == album.id && bare.year == 1992)
        #expect(bare.withSongs(album.song).song?.count == 2)
        let playlist = try #require(decode(Fixtures.playlists, key: "playlists", as: PlaylistsBody.self).1?.playlist?.first)
        #expect(playlist.withEntries(album.song).entry?.count == 2 && playlist.isPublic == true)
    }

    @Test func failedReplyThrowsTypedError() async {
        StubProtocol.replies = ["ping": Fixtures.failed]
        await #expect(throws: SubsonicError.api(code: 40, message: "Wrong username or password")) {
            try await stubbed().ping()
        }
    }

    @Test func libraryStoreRefreshSkipsUnchangedScan() async throws {
        StubProtocol.replies = [
            "getScanStatus": Fixtures.scanStatus, "getArtists": Fixtures.artists,
            "getAlbumList2": Fixtures.albumList, "getPlaylists": Fixtures.playlists,
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(client: stubbed(), directory: dir)
        let first = try await store.refresh()
        #expect(first.artists.count == 2)
        #expect(first.albums.count == 1)
        #expect(first.playlists.count == 1)

        // Same lastScan: albums come from the cache even if the server now returns none.
        StubProtocol.replies["getAlbumList2"] = Fixtures.emptyAlbumList
        let reloaded = LibraryStore(client: stubbed(), directory: dir)
        #expect(await reloaded.load().albums.count == 1)
        #expect(try await reloaded.refresh().albums.count == 1)
        #expect(try await reloaded.refresh(force: true).albums.isEmpty)
    }
}
