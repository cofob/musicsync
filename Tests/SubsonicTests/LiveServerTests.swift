import Foundation
import Testing
import Subsonic

/// The API calls against a real Navidrome, e.g. `scripts/navidrome-dev.sh up`. Runs only with MUSICSYNC_LIVE_URL,
/// MUSICSYNC_LIVE_USER and MUSICSYNC_LIVE_PASSFILE set. Everything it adds it removes again.
private let env = ProcessInfo.processInfo.environment

@Suite(.enabled(if: env["MUSICSYNC_LIVE_URL"] != nil), .serialized)
struct LiveServerTests {
    let client: SubsonicClient

    init() throws {
        let password = try String(contentsOfFile: env["MUSICSYNC_LIVE_PASSFILE"] ?? "", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        client = SubsonicClient(baseURL: try #require(URL(string: env["MUSICSYNC_LIVE_URL"] ?? "")),
                                username: env["MUSICSYNC_LIVE_USER"] ?? "", password: password)
    }

    private func song(_ query: String) async throws -> Song {
        try #require(try await client.search3(query, artistCount: 0, albumCount: 0, songCount: 5).song.first)
    }

    @Test func browse() async throws {
        let info = try await client.ping()
        #expect(info.openSubsonic == true)
        let extensions = try await client.getOpenSubsonicExtensions().map(\.name)
        #expect(extensions.contains("songLyrics") && extensions.contains("transcodeOffset"))
        let artists = try await client.getArtists().flatMap { $0.artist ?? [] }
        #expect(artists.contains { $0.name == "坂本 龍一" })
        let albums = try await client.getAlbumList2(type: "alphabeticalByName", size: 500)
        #expect(albums.count >= 30)
        let album = try #require(albums.first { $0.name == "Песни о главном" })
        let songs = try await client.getAlbum(id: album.id).song ?? []
        #expect(songs.count == 8 && songs.first?.replayGain?.trackGain != nil)
        #expect(try await client.search3("песня").song.count >= 8)
        #expect(try await client.search3("Ete a Paris").album.count == 1)
        #expect(!(try await client.getGenres()).isEmpty)
        let cover = try await client.coverArt(id: try #require(album.coverArt), size: 300)
        #expect(cover.count > 100)
        // Album 12 has no art: Navidrome's stand-in image is no cover.
        let bare = try #require(albums.first { $0.name == "Album 12" })
        let bareSong = try #require(try await client.getAlbum(id: bare.id).song?.first?.coverArt)
        await #expect(throws: SubsonicError.badResponse("placeholder cover")) { try await client.coverArt(id: bareSong, size: 300) }
    }

    @Test func lyrics() async throws {
        let album = try #require(try await client.getAlbumList2(type: "alphabeticalByName", size: 500).first { $0.name == "Album 1" })
        let first = try #require(try await client.getAlbum(id: album.id).song?.first { $0.track == 1 })
        let lyrics = try await client.getLyricsBySongId(id: first.id)
        #expect(lyrics.first?.synced == true && lyrics.first?.line.first?.start == 500)
    }

    @Test func starsAndRatings() async throws {
        let song = try await song("Night Drive 3")
        try await client.star(ids: [song.id])
        #expect(try await client.getSong(id: song.id).starred != nil)
        try await client.unstar(ids: [song.id])
        #expect(try await client.getSong(id: song.id).starred == nil)
        try await client.setRating(id: song.id, rating: 4)
        #expect(try await client.getSong(id: song.id).userRating == 4)
        try await client.setRating(id: song.id, rating: 0)
        #expect(try await client.getSong(id: song.id).userRating ?? 0 == 0)
    }

    @Test func playlists() async throws {
        let a = try await song("Night Drive 1"), b = try await song("Night Drive 2")
        let created = try #require(try await client.createPlaylist(name: "Live Тест", songIds: [a.id]))
        try await client.updatePlaylist(id: created.id, name: "Live Тест 2", comment: "c", isPublic: true, songIdsToAdd: [b.id])
        var list = try await client.getPlaylist(id: created.id)
        #expect(list.name == "Live Тест 2" && list.entry?.map(\.id) == [a.id, b.id] && list.isPublic == true)
        try await client.updatePlaylist(id: created.id, songIndexesToRemove: [0])
        try await client.replacePlaylistSongs(id: created.id, songIds: [b.id, a.id])
        list = try await client.getPlaylist(id: created.id)
        #expect(list.entry?.map(\.id) == [b.id, a.id])
        try await client.deletePlaylist(id: created.id)
        #expect(try await client.getPlaylists().allSatisfy { $0.id != created.id })
    }

    @Test func shares() async throws {
        let song = try await song("Night Drive 4")
        let share = try #require(try await client.createShare(ids: [song.id], description: "live", expires: Date().addingTimeInterval(3600)))
        #expect(share.entry?.first?.id == song.id && !share.url.isEmpty)
        #expect(try await client.getShares().contains { $0.id == share.id })
        try await client.deleteShare(id: share.id)
        #expect(try await client.getShares().allSatisfy { $0.id != share.id })
    }

    @Test func queueBookmarksAndScrobbles() async throws {
        let a = try await song("Night Drive 5"), b = try await song("Night Drive 6")
        try await client.savePlayQueue(ids: [a.id, b.id], current: b.id, position: 12_345)
        let queue = try #require(try await client.getPlayQueue())
        #expect(queue.songs.map(\.id) == [a.id, b.id] && queue.current == b.id && queue.position == 12_345 && queue.changedDate != nil)
        try await client.createBookmark(id: a.id, position: 7000, comment: "live")
        #expect(try await client.getBookmarks().first { $0.entry.id == a.id }?.position == 7000)
        try await client.deleteBookmark(id: a.id)
        #expect(try await client.getBookmarks().allSatisfy { $0.entry.id != a.id })
        try await client.scrobble(ids: [a.id], submission: false)
        try await client.scrobble(ids: [a.id], times: [Date()])
        #expect((try await client.getSong(id: a.id).playCount ?? 0) >= 1)
    }

    @Test func radio() async throws {
        try await client.createInternetRadioStation(name: "Live Radio", streamUrl: "http://127.0.0.1:9/live", homePageUrl: nil)
        let station = try #require(try await client.getInternetRadioStations().first { $0.name == "Live Radio" })
        try await client.updateInternetRadioStation(id: station.id, name: "Live Radio 2", streamUrl: station.streamUrl, homePageUrl: "http://127.0.0.1:9/")
        #expect(try await client.getInternetRadioStations().first { $0.id == station.id }?.name == "Live Radio 2")
        try await client.deleteInternetRadioStation(id: station.id)
        #expect(try await client.getInternetRadioStations().allSatisfy { $0.id != station.id })
    }

    @Test func transcoding() async throws {
        let flac = try #require(try await client.search3("Song 8", artistCount: 0, albumCount: 0, songCount: 100).song.first { $0.duration == 660 })
        #expect(await client.convertibleFormats(songID: flac.id) == ["aac", "mp3"])
        let (data, response) = try await URLSession.shared.data(from: client.streamURL(id: flac.id, format: "mp3", maxBitRate: 128, timeOffset: 600))
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && TranscodeProbe.matches(format: "mp3", contentType: response.mimeType))
        // 60 s left of 128 kbps: about 1 MB, not the 10 MB of the whole song.
        #expect(data.count > 500_000 && data.count < 2_000_000)
    }

    @Test func serverWithoutPodcasts() async throws {
        await #expect(throws: (any Error).self) { try await client.getPodcasts() }
        let user = try await client.getUser(username: client.config.username)
        #expect(user.jukeboxRole == true)
    }
}
