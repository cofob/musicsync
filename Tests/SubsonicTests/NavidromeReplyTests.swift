import Foundation
import Testing
@testable import Subsonic

/// Replies captured from Navidrome 0.64.2 (`scripts/navidrome-dev.sh`), cut to one or two entries. Newer Navidrome
/// sends many more fields (`works`, `movements`, `releaseDate`, empty `replayGain`) that must not break decoding.
enum Navidrome064 {
    static let song = #"""
    {"id":"3COyM5HIAboVy52WMS3b1Y","parent":"2DIRakGs2WIbJJO2JyVapR","isDir":false,"title":"Song 1","album":"Album 6","artist":"Борис Гребенщиков","track":1,"year":1995,"genre":"Ambient","coverArt":"dc-2DIRakGs2WIbJJO2JyVapR:1","size":34348,"contentType":"audio/mp4","suffix":"m4a","duration":23,"bitRate":10,"path":"Various Artists/Album 6/01-01 - Song 1.m4a","discNumber":1,"created":"2026-11-15T00:49:17.728078077Z","albumId":"2DIRakGs2WIbJJO2JyVapR","artistId":"5pGSfvFjVF8wafeepxVwYV","type":"music","bpm":0,"comment":"","sortName":"song 1","mediaType":"song","musicBrainzId":"","isrc":[],"genres":[{"name":"Ambient"}],"replayGain":{},"channelCount":1,"samplingRate":44100,"bitDepth":16,"moods":[],"artists":[{"id":"5pGSfvFjVF8wafeepxVwYV","name":"Борис Гребенщиков"}],"displayArtist":"Борис Гребенщиков","albumArtists":[{"id":"63sqASlAfjbGMuLP4JhnZU","name":"Various Artists"}],"displayAlbumArtist":"Various Artists","contributors":[],"displayComposer":"","explicitStatus":"","groupings":[],"works":[],"movements":[]}
    """#

    static let album = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"album":{"id":"2DIRakGs2WIbJJO2JyVapR","name":"Album 6","artist":"Various Artists","artistId":"63sqASlAfjbGMuLP4JhnZU","coverArt":"al-2DIRakGs2WIbJJO2JyVapR_87bec740a662150f","songCount":8,"duration":268,"created":"2026-11-15T00:49:17.679182272Z","year":1995,"genre":"Ambient","userRating":0,"genres":[{"name":"Ambient"}],"musicBrainzId":"","isCompilation":true,"sortName":"album 6","discTitles":[],"originalReleaseDate":{},"releaseDate":{"year":1995},"releaseTypes":[],"recordLabels":[],"moods":[],"artists":[{"id":"63sqASlAfjbGMuLP4JhnZU","name":"Various Artists"}],"displayArtist":"Various Artists","explicitStatus":"","version":"","song":[\#(song)]}}}
    """#

    static let lyrics = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"lyricsList":{"structuredLyrics":[{"displayArtist":"Aurora Fields","displayTitle":"Song 1","lang":"xxx","line":[{"start":500,"value":"First line of song 1"},{"start":4000,"value":"Second line"},{"start":8000,"value":"Third line"},{"start":12000,"value":"Last line"}],"synced":true}]}}}
    """#

    /// A song without lyrics: an empty `lyricsList`.
    static let noLyrics = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"lyricsList":{}}}
    """#

    static let shares = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"shares":{"share":[{"entry":[\#(song)],"id":"22rh1wRhnI","url":"http://127.0.0.1:14533/share/22rh1wRhnI","description":"fixture","username":"admin","created":"2026-11-15T00:52:52.128390163Z","expires":"2027-11-15T00:52:52.126016914Z","visitCount":0}]}}}
    """#

    static let playQueue = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"playQueue":{"entry":[\#(song)],"current":"3COyM5HIAboVy52WMS3b1Y","position":67000,"username":"admin","changed":"2026-11-15T00:49:40.667938516Z","changedBy":"MusicSync"}}}
    """#

    static let extensions = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"openSubsonicExtensions":[{"name":"transcodeOffset","versions":[1]},{"name":"formPost","versions":[1]},{"name":"songLyrics","versions":[1,2]},{"name":"indexBasedQueue","versions":[1]},{"name":"transcoding","versions":[1]},{"name":"playbackReport","versions":[1]},{"name":"topSongsByArtistId","versions":[1]}]}}
    """#

    static let jukebox = #"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true,"jukeboxPlaylist":{"currentIndex":0,"playing":false,"gain":0.7,"position":6,"entry":[\#(song)]}}}
    """#
}

/// In `ClientTests`, which runs serialized, because `StubProtocol` is shared.
extension ClientTests {
    private func navidrome(_ replies: [String: String]) -> SubsonicClient {
        StubProtocol.replies = replies
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SubsonicClient(baseURL: URL(string: "http://127.0.0.1:14533")!, username: "admin", password: "p",
                              session: URLSession(configuration: config))
    }

    @Test func compilationAlbum() async throws {
        let album = try await navidrome(["getAlbum": Navidrome064.album]).getAlbum(id: "2DIRakGs2WIbJJO2JyVapR")
        #expect(album.isCompilation == true && album.artist == "Various Artists")
        let song = try #require(album.song?.first)
        #expect(song.artist == "Борис Гребенщиков" && song.displayAlbumArtist == "Various Artists")
        #expect(song.coverArt == "dc-2DIRakGs2WIbJJO2JyVapR:1" && song.replayGain?.trackGain == nil)
    }

    @Test func lyricsFromLRC() async throws {
        let c = navidrome(["getLyricsBySongId": Navidrome064.lyrics])
        let lyrics = try await c.getLyricsBySongId(id: "s")
        #expect(lyrics.count == 1 && lyrics[0].synced && lyrics[0].offset == nil)
        #expect(lyrics[0].line.map(\.start) == [500, 4000, 8000, 12000])
        StubProtocol.replies = ["getLyricsBySongId": Navidrome064.noLyrics]
        #expect(try await c.getLyricsBySongId(id: "s").isEmpty)
    }

    @Test func sharesQueueAndJukebox() async throws {
        let c = navidrome(["getShares": Navidrome064.shares, "getPlayQueue": Navidrome064.playQueue,
                         "getOpenSubsonicExtensions": Navidrome064.extensions, "jukeboxControl": Navidrome064.jukebox])
        let share = try #require(try await c.getShares().first)
        #expect(share.url.hasSuffix("/share/22rh1wRhnI") && share.entry?.count == 1 && share.visitCount == 0)
        let queue = try #require(try await c.getPlayQueue())
        #expect(queue.current == queue.songs.first?.id && queue.position == 67000 && queue.changedDate != nil)
        #expect(try await c.getOpenSubsonicExtensions().contains { $0.name == "transcodeOffset" })
        let jukebox = try await c.jukeboxPlaylist()
        #expect(jukebox.songs.count == 1 && jukebox.status.gain == 0.7 && jukebox.status.position == 6)
    }

    /// `getCoverArt` headers as Navidrome 0.64.2 sends them for a real cover and for an item without art.
    @Test func navidromeStandInIsNoCover() {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://127.0.0.1/rest/getCoverArt")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        #expect(!SubsonicClient.isPlaceholderCover(response(["Cache-Control": "public, max-age=31536000, immutable",
                                                              "Etag": "\"dc47516a8a17bf4c.300.false.q75\"", "Content-Type": "image/jpeg"])))
        #expect(SubsonicClient.isPlaceholderCover(response(["Cache-Control": "no-store", "Content-Type": "image/webp"])))
        #expect(!SubsonicClient.isPlaceholderCover(response(["Content-Type": "image/png"])))
    }
}
