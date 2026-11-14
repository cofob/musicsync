import Foundation
import Testing
@testable import Library
import Subsonic

/// Sets up a mirror whose passes are started by the test.
private struct Fixture {
    let dir = TempDir()
    let server: StubLibraryServer
    let db: LibraryDatabase
    let mirror: LibraryMirror

    init(server: StubLibraryServer = makeServer(), settings: MirrorSettings = manualSettings()) async {
        self.server = server
        db = dir.database()
        mirror = LibraryMirror(database: db, settings: settings)
        await mirror.start(client: server.client)
    }

    func sync() async { await mirror.syncNow() }
}

@Suite struct MirrorTests {
    @Test func firstSyncPopulatesEverything() async throws {
        let server = makeServer(albums: 3, songsPerAlbum: 2)
        server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t1", songIDs: ["s-3-2", "s-1-1", "s-2-1"])]
        server.setLyrics(song: "s-1-1", synced: true, lines: [(0, "Hello"), (1200, "World")])
        let f = await Fixture(server: server)
        await f.sync()

        #expect(await f.db.artists().map(\.name) == ["Björk", "Space Echo"])
        #expect(await f.db.albums().map(\.id) == ["al-1", "al-2", "al-3"])
        #expect(await f.db.songCount() == 6)
        #expect(await f.db.album(id: "al-2")?.song?.map(\.id) == ["s-2-1", "s-2-2"])
        #expect(await f.db.playlist(id: "pl-1")?.entry?.map(\.id) == ["s-3-2", "s-1-1", "s-2-1"])
        #expect(await f.db.playlists().first?.entry == nil)
        #expect(await f.db.lyrics(songId: "s-1-1")?.line.map(\.value) == ["Hello", "World"])
        #expect(await f.db.lyrics(songId: "s-1-2") == nil)
        let cover = try #require(await f.db.smallCoverURL(coverArtId: "cov-al-1"))
        #expect(try Data(contentsOf: cover) == Data("COVER-BYTES".utf8))
        #expect(await f.db.smallCoverURLs()["cov-al-1"] == cover)
        #expect(await f.db.isPopulated)

        let status = f.mirror.currentStatus
        #expect(status.state == .disabled && status.lastSuccess != nil && status.warnings == 0)  // manual settings: schedule off
        #expect(f.dir.asideFiles.isEmpty)
    }

    @Test func secondSyncFetchesOnlyWhatChanged() async throws {
        let server = makeServer(albums: 3, songsPerAlbum: 2)
        server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t1", songIDs: ["s-1-1"])]
        server.setLyrics(song: "s-1-1", synced: false, lines: [(0, "x")])
        let f = await Fixture(server: server)
        await f.sync()
        server.clearLog()

        server.albums[1].songs.append(StubSong(id: "s-2-3", title: "New", track: 3))
        await f.sync()

        #expect(server.requests("getAlbum") == ["getAlbum:al-2"])
        #expect(server.requests("getPlaylist").isEmpty)
        #expect(server.requests("getCoverArt").isEmpty)
        #expect(server.requests("getLyricsBySongId") == ["getLyricsBySongId:s-2-3"])  // none markers are not asked again
        #expect(await f.db.album(id: "al-2")?.song?.count == 3)
        #expect(await f.db.songCount() == 7)
    }

    @Test func unchangedScanSkipsTheListing() async throws {
        var settings = manualSettings()
        settings.enabled = true
        let f = await Fixture(settings: settings)
        #expect(await eventually { f.mirror.currentStatus.lastSuccess != nil })
        let first = f.mirror.currentStatus.lastSuccess
        f.server.clearLog()

        await f.mirror.resume()  // wakes the schedule: a normal (not forced) pass
        #expect(await eventually { f.mirror.currentStatus.lastSuccess != first })
        #expect(f.server.requests("getScanStatus").count == 1)
        #expect(f.server.requests("getAlbumList2").isEmpty && f.server.requests("getArtists").isEmpty)

        f.server.lastScan = "scan-2"
        let second = f.mirror.currentStatus.lastSuccess
        await f.mirror.resume()
        #expect(await eventually { f.mirror.currentStatus.lastSuccess != second })
        #expect(f.server.requests("getAlbumList2").isEmpty == false)
        await f.mirror.stop()
    }

    @Test func albumRemovedOnServerIsDeleted() async {
        let server = makeServer(albums: 3)
        let f = await Fixture(server: server)
        await f.sync()
        server.albums.removeAll { $0.id == "al-2" }
        await f.sync()
        #expect(await f.db.albums().map(\.id) == ["al-1", "al-3"])
        #expect(await f.db.songCount() == 4)
        #expect(await f.db.search("Album 02").song.isEmpty)
        #expect(await f.db.smallCoverURL(coverArtId: "cov-al-2") == nil)
    }

    @Test func failingListingDeletesNothing() async {
        let server = makeServer(albums: 3)
        let f = await Fixture(server: server)
        await f.sync()
        server.albums.removeAll { $0.id == "al-2" }

        server.failAlbumListAfter = 1  // first page arrives, the next request fails
        await f.sync()
        #expect(await f.db.albumCount() == 3)
        #expect(await f.db.songCount() == 6)
        if case .failed = f.mirror.currentStatus.state {} else { Issue.record("expected failed state") }
        #expect(f.mirror.currentStatus.warnings > 0)
        #expect(await f.db.albums().count == 3)  // reads keep working

        server.failAlbumListAfter = nil
        await f.sync()
        #expect(await f.db.albums().map(\.id) == ["al-1", "al-3"])
        #expect(f.mirror.currentStatus.state == .disabled)
    }

    @Test func emptyListingOrEmptyAlbumReplyDeletesNothing() async {
        let server = makeServer(albums: 2)
        let f = await Fixture(server: server)
        await f.sync()

        server.emptyAlbumList = true
        await f.sync()
        #expect(await f.db.albumCount() == 2)
        #expect(await f.db.songCount() == 4)
        server.emptyAlbumList = false

        server.emptyAlbumReply = true
        server.albums[0].songs.append(StubSong(id: "s-1-3", title: "Extra", track: 3))  // makes the album dirty
        await f.sync()
        #expect(await f.db.songCount() == 4)  // glitchy empty reply refused, old songs stay
        #expect(f.mirror.currentStatus.warnings > 0)

        server.emptyAlbumReply = false
        await f.sync()
        #expect(await f.db.songCount() == 5)
    }

    @Test func changedPlaylistRefreshesEntries() async {
        let server = makeServer(albums: 2)
        server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t1", songIDs: ["s-1-1", "s-1-2"]),
                            StubPlaylist(id: "pl-2", name: "Other", changed: "t1", songIDs: ["s-2-1"])]
        let f = await Fixture(server: server)
        await f.sync()
        #expect(await f.db.playlist(id: "pl-1")?.entry?.map(\.id) == ["s-1-1", "s-1-2"])
        server.clearLog()

        server.playlists[0] = StubPlaylist(id: "pl-1", name: "Mix", changed: "t2", songIDs: ["s-2-2", "s-1-1"])
        await f.sync()
        #expect(server.requests("getPlaylist") == ["getPlaylist:pl-1"])
        #expect(await f.db.playlist(id: "pl-1")?.entry?.map(\.id) == ["s-2-2", "s-1-1"])

        server.playlists.removeAll { $0.id == "pl-2" }
        await f.sync()
        #expect(await f.db.playlists().map(\.id) == ["pl-1"])
    }

    @Test func lyricsAreSkippedWithoutServerSupportOrSetting() async {
        let server = makeServer(albums: 1)
        server.extensions = []
        let f = await Fixture(server: server)
        await f.sync()
        #expect(server.requests("getLyricsBySongId").isEmpty)

        var settings = manualSettings()
        settings.includeLyrics = false
        settings.includeCovers = false
        let g = await Fixture(server: makeServer(albums: 1), settings: settings)
        await g.sync()
        #expect(g.server.requests("getLyricsBySongId").isEmpty && g.server.requests("getCoverArt").isEmpty)
        #expect(await g.db.songCount() == 2)
    }

    @Test func missingCoverFileIsFetchedAgain() async throws {
        let f = await Fixture(server: makeServer(albums: 1))
        await f.sync()
        let url = try #require(await f.db.smallCoverURL(coverArtId: "cov-al-1"))
        try FileManager.default.removeItem(at: url)
        #expect(await f.db.smallCoverURL(coverArtId: "cov-al-1") == nil)
        f.server.clearLog()
        await f.sync()
        #expect(f.server.requests("getCoverArt").count == 1)
        #expect(await f.db.smallCoverURL(coverArtId: "cov-al-1") != nil)
    }

    @Test func onlyMissingCoversAreRemembered() async {
        let f = await Fixture(server: makeServer(albums: 1))
        f.server.coverStatus = 503
        await f.sync()
        #expect(await f.db.coversToFetch() == ["cov-al-1"])  // transient: retried next pass
        f.server.coverStatus = 404
        await f.sync()
        #expect(await f.db.coversToFetch().isEmpty)
    }

    @Test func cancelledSyncResumesWithoutDuplicates() async {
        let server = makeServer(albums: 12, songsPerAlbum: 3)
        let f = await Fixture(server: server)
        server.delayMs = 60
        let run = Task { await f.sync() }
        #expect(await eventually { f.mirror.currentStatus.phase == .tracks && f.mirror.currentStatus.done >= 4 })
        run.cancel()
        await run.value
        #expect(f.mirror.currentStatus.state == .disabled)
        #expect(f.mirror.currentStatus.lastSuccess == nil)  // a cancelled pass is not a success
        let partial = await f.db.songCount()
        #expect(partial >= 12 && partial < 36)
        let finished = Set(await f.db.songs(limit: 100).compactMap(\.albumId))

        server.delayMs = 0
        server.clearLog()
        await f.sync()
        #expect(await f.db.albumCount() == 12)
        #expect(await f.db.songCount() == 36)
        #expect(await f.db.songs(limit: 100).count == 36)
        #expect(Set(await f.db.songs(limit: 100).map(\.id)).count == 36)
        // Finished albums are not fetched again. A request of the cancelled pass can still reach the stub late, so compare ids, not counts.
        #expect(Set(server.requests("getAlbum").map { String($0.dropFirst(9)) }).isDisjoint(with: finished))
        #expect(Set(server.requests("getAlbum")).count >= 12 - finished.count)
        #expect(f.mirror.currentStatus.lastSuccess != nil)
    }

    @Test func unreachableServerGivesFailedStatusAndKeepsData() async {
        let server = makeServer(albums: 2)
        let f = await Fixture(server: server)
        await f.sync()
        server.failAlbumListAfter = 0
        server.albums = []
        await f.sync()
        #expect(await f.db.albumCount() == 2)
        if case .failed(let message) = f.mirror.currentStatus.state { #expect(message.contains("albums")) } else { Issue.record("not failed") }
    }

    @Test func disabledMirrorRunsNothingUntilSyncNow() async throws {
        let f = await Fixture()  // manualSettings: disabled
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.server.log.isEmpty)
        #expect(f.mirror.currentStatus.state == .disabled)
        await f.sync()
        #expect(await f.db.albumCount() == 3)
        #expect(f.mirror.currentStatus.state == .disabled)
    }

    @Test func pauseStopsBackgroundPasses() async throws {
        var settings = manualSettings()
        settings.enabled = true
        let f = await Fixture(settings: settings)
        #expect(await eventually { f.mirror.currentStatus.lastSuccess != nil })
        await f.mirror.pause()
        #expect(f.mirror.currentStatus.state == .paused)
        f.server.clearLog()
        await f.mirror.update(settings: settings)  // wakes the loop; paused, so nothing runs
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.server.log.isEmpty)
        await f.mirror.stop()
    }

    @Test func statusStreamReportsProgress() async {
        let f = await Fixture(server: makeServer(albums: 4))
        let collector = Task { () -> [MirrorStatus] in
            var seen: [MirrorStatus] = []
            for await status in f.mirror.status {
                seen.append(status)
                if status.lastSuccess != nil { break }
            }
            return seen
        }
        await f.sync()
        let seen = await collector.value
        #expect(seen.contains { $0.state == .running })
        #expect(seen.contains { $0.phase == .tracks && $0.total == 4 })
        #expect(seen.last?.lastSuccess != nil)
    }
}
