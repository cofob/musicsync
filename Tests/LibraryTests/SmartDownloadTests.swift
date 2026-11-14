import Foundation
import Recommend
import Subsonic
import Testing
@testable import Library

/// A 1000-byte song.
private func track(_ id: String) -> Song {
    decode(["id": id, "title": "Song \(id)", "album": "Album", "albumId": "al-1", "artist": "Artist", "duration": 200,
            "suffix": "flac", "size": 1000])
}

private func entry(_ id: String, _ reasons: Set<DownloadReason>, state: DownloadState = .done, size: Int64 = 1000) -> DownloadEntry {
    DownloadEntry(song: track(id), state: state, fileName: state == .done ? "\(id).flac" : nil, size: size, format: "flac",
                  bitRate: nil, error: nil, reasons: reasons)
}

/// Rules on with budgets in bytes (the settings take GB).
private func settings(_ rules: [SmartRule: Int64], total: Int64 = 1_000_000) -> SmartSettings {
    var s = SmartSettings()
    for (rule, bytes) in rules {
        s[rule].isOn = true
        s[rule].budgetGB = Double(bytes) / 1e9
    }
    s.budgetGB = Double(total) / 1e9
    return s
}

private func plan(_ candidates: [SmartRule: [String]], _ s: SmartSettings, entries: [DownloadEntry] = [],
                  played: [String: Double] = [:], freeDisk: Int64? = nil) -> SmartPlan {
    SmartPlanner.plan(candidates.mapValues { $0.map(track) }, settings: s, entries: entries,
                      lastPlayed: played.mapValues { Date(timeIntervalSince1970: $0) }, freeDisk: freeDisk) { Int64($0.size ?? 0) }
}

private func ids(_ plan: SmartPlan, _ rule: SmartRule) -> [String] { plan.songs[rule]?.map(\.id) ?? [] }

@Suite struct SmartPlannerTests {
    @Test func eachRuleTakesItsBestSongsWithinItsBudget() {
        let p = plan([.favorites: ["a", "b", "c"], .mostPlayed: ["d", "e"]], settings([.favorites: 2500, .mostPlayed: 5000]))
        #expect(ids(p, .favorites) == ["a", "b"])
        #expect(ids(p, .mostPlayed) == ["d", "e"])
        #expect(p.added == ["a", "b", "d", "e"])
        #expect(p.bytes == 4000)
    }

    @Test func disabledRulesKeepNothing() {
        let p = plan([.favorites: ["a"], .mixes: ["b"]], settings([.favorites: 5000]))
        #expect(p.songs[.mixes] == nil)
        #expect(p.added == ["a"])
    }

    @Test func userDownloadsCostNothingAndAreNeverRemoved() {
        let entries = [entry("a", [.album("al-1")]), entry("x", [.song, .smart(.favorites)])]
        let p = plan([.favorites: ["a", "b"]], settings([.favorites: 1000]), entries: entries)
        #expect(ids(p, .favorites) == ["a", "b"])
        #expect(p.added == ["b"])
        #expect(p.removed.isEmpty)  // "x" loses the rule but stays: the user keeps it
        #expect(p.bytes == 1000)
    }

    @Test func overTheGlobalBudgetTheLeastRecentlyPlayedGoFirst() {
        let entries = [entry("a", [.smart(.favorites)]), entry("b", [.smart(.favorites)]), entry("c", [.smart(.mostPlayed)])]
        let p = plan([.favorites: ["a", "b"], .mostPlayed: ["c"]], settings([.favorites: 5000, .mostPlayed: 5000], total: 2000),
                     entries: entries, played: ["a": 300, "b": 100, "c": 200])
        #expect(ids(p, .favorites) == ["a"])
        #expect(ids(p, .mostPlayed) == ["c"])
        #expect(p.removed == ["b"])
        #expect(p.added.isEmpty)
    }

    @Test func unplayedSongsGoByRuleRankThenID() {
        let p = plan([.favorites: ["b", "a"], .mixes: ["c"]], settings([.favorites: 5000, .mixes: 5000], total: 2000))
        // "b" and "c" rank 0, "a" rank 1: "a" goes; "b" < "c" by id is irrelevant as both fit.
        #expect(ids(p, .favorites) == ["b"])
        #expect(ids(p, .mixes) == ["c"])
    }

    @Test func songsThatNoLongerMatchAreRemoved() {
        let entries = [entry("a", [.smart(.favorites)]), entry("b", [.smart(.favorites), .smart(.mixes)])]
        let p = plan([.favorites: ["b"]], settings([.favorites: 5000]), entries: entries)
        #expect(p.removed == ["a"])
        #expect(ids(p, .favorites) == ["b"])
    }

    @Test func freeDiskSpaceLessTheReserveLimitsThePlan() {
        let entries = [entry("a", [.smart(.favorites)])]
        let p = plan([.favorites: ["a", "b", "c"]], settings([.favorites: 5000]), entries: entries,
                     freeDisk: SmartPlanner.reserveBytes + 1000)
        // 1000 bytes on disk (freed if dropped) + 1000 free above the reserve: room for two songs.
        #expect(ids(p, .favorites) == ["a", "b"])
        #expect(plan([.favorites: ["b"]], settings([.favorites: 5000]), freeDisk: 100).songs[.favorites] == [])
    }

    @Test func repeatsCountOnceAndThePlanIsDeterministic() {
        let s = settings([.favorites: 5000, .playlists: 5000], total: 3000)
        let candidates: [SmartRule: [String]] = [.favorites: ["a", "a", "b"], .playlists: ["b", "c", "d"]]
        let first = plan(candidates, s)
        #expect(ids(first, .favorites) == ["a", "b"])
        #expect(Set(first.added).count == 3)
        for _ in 0..<5 { #expect(plan(candidates, s) == first) }
    }

    @Test func queuedSongsUseTheEstimate() {
        let entries = [entry("a", [.smart(.favorites)], state: .queued, size: 0)]
        let p = plan([.favorites: ["a", "b"]], settings([.favorites: 1500]), entries: entries)
        #expect(ids(p, .favorites) == ["a"])
    }
}

@Suite struct SmartConditionTests {
    @Test func networkPowerAndStreaming() {
        var s = SmartSettings()
        #expect(SmartConditions().wait(for: s) == nil)
        #expect(SmartConditions(network: .metered).wait(for: s) == .network)
        #expect(SmartConditions(network: .none).wait(for: s) == .network)
        s.unmeteredOnly = false
        #expect(SmartConditions(network: .metered).wait(for: s) == nil)
        #expect(SmartConditions(network: .none).wait(for: s) == .network)
        #expect(SmartConditions(onPower: false).wait(for: s) == nil)
        s.powerOnly = true
        #expect(SmartConditions(onPower: false).wait(for: s) == .power)
        #expect(SmartConditions(streaming: true).wait(for: s) == .streaming)
        s.pauseWhileStreaming = false
        #expect(SmartConditions(streaming: true).wait(for: s) == nil)
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let old = try JSONDecoder().decode(DownloadSettings.self, from: Data(#"{"quality":"mp3","smart":{"favorites":1}}"#.utf8))
        #expect(old.quality == .mp3)
        #expect(old.smart == SmartSettings())
        #expect(old.cacheGB == 1)
        var s = DownloadSettings()
        s.smart.favorites.isOn = true
        s.smart.playlistIDs = ["pl-1"]
        s.cacheGB = 5
        #expect(try JSONDecoder().decode(DownloadSettings.self, from: JSONEncoder().encode(s)) == s)
    }
}

@Suite struct SmartSourceTests {
    @Test func mostPlayedUsesTheHigherCountThenTheLastPlay() {
        let tracks = [Track(id: "a", title: "A", artist: nil, serverPlays: 5), Track(id: "b", title: "B", artist: nil, serverPlays: 1),
                      Track(id: "c", title: "C", artist: nil), Track(id: "d", title: "D", artist: nil, serverPlays: 5)]
        let stats = ["b": SongStats(plays: 9), "d": SongStats(plays: 2, lastPlayed: Date())]
        #expect(Library.mostPlayed(tracks, stats, count: 10) == ["b", "d", "a"])
        #expect(Library.mostPlayed(tracks, stats, count: 2) == ["b", "d"])
    }

    @Test func mixesInterleave() {
        #expect(Library.interleave([["a", "b", "c"], ["x"], ["y", "z"]]) == ["a", "x", "y", "b", "z", "c"])
        #expect(Library.interleave([]).isEmpty)
    }
}

@Suite struct SmartStoreTests {
    @Test func rulesNeverTouchUserReasons() async throws {
        let dir = TempDir()
        let store = DownloadStore(fileURL: dir.url.appendingPathComponent("d.sqlite"))
        try await store.add([track("a")], reason: .song)
        #expect(try await store.setSmart([.favorites: [track("a"), track("b")], .mixes: [track("b")]]).isEmpty)
        #expect(await store.entry("b")?.reasons == [.smart(.favorites), .smart(.mixes)])
        #expect(await store.entry("b")?.smartRules == [.favorites, .mixes])

        let released = try await store.setSmart([:])
        #expect(released.map(\.id) == ["b"])
        #expect(await store.entry("a")?.reasons == [.song])
    }

    @Test func smartSongsWaitAndComeAfterTheUsersOwn() async throws {
        let dir = TempDir()
        let store = DownloadStore(fileURL: dir.url.appendingPathComponent("d.sqlite"))
        _ = try await store.setSmart([.favorites: [track("s")]])
        try await store.add([track("u")], reason: .song)
        #expect(await store.nextQueued(excluding: [])?.id == "u")
        #expect(await store.nextQueued(excluding: ["u"])?.id == "s")
        #expect(await store.nextQueued(excluding: ["u"], smart: false) == nil)
        #expect(await store.pendingCount(smart: false) == 1)
        #expect(await store.pendingCount() == 2)
    }

    @Test func storageLimitCountsOnlyUserDownloads() async throws {
        let dir = TempDir()
        let store = DownloadStore(fileURL: dir.url.appendingPathComponent("d.sqlite"))
        try await store.add([track("u")], reason: .song)
        _ = try await store.setSmart([.favorites: [track("s")]])
        for id in ["u", "s"] {
            #expect(try await store.markDownloading(id))
            #expect(try await store.markDone(id, fileName: id, size: 1000, format: "flac", bitRate: nil))
        }
        #expect(await store.userBytes() == 1000)
        #expect(await store.usedBytes() == 2000)
    }
}

/// A mirrored stub library: three albums of two songs, `s-1-1` and album `al-2` starred.
private struct SmartFixture {
    let dir = TempDir()
    let server = makeServer()
    let library: Library
    let downloads: DownloadManager

    init(_ smart: SmartSettings) async {
        server.starred = ["s-1-1": "2026-01-01T00:00:00Z", "al-2": "2026-01-02T00:00:00Z"]
        library = Library(server: ServerConfig(baseURL: URL(string: "http://stub")!, username: "demo"), settings: manualSettings(),
                          directory: dir.url, coversDirectory: dir.url.appendingPathComponent("covers"))
        var settings = DownloadSettings()
        settings.smart = smart
        downloads = DownloadManager(serverKey: "demo@http://stub", directory: dir.url.appendingPathComponent("downloads"),
                                    settings: settings, backoff: { _ in .milliseconds(20) })
    }

    func mirror() async {
        await library.mirror.start(client: server.client)
        await library.mirror.syncNow()
    }

    func states() async -> [String: DownloadState] {
        Dictionary(uniqueKeysWithValues: await downloads.store.entries().map { ($0.id, $0.state) })
    }
}

@Suite struct SmartDownloadManagerTests {
    @Test func favoritesDownloadWhenAllowedAndFollowTheStars() async throws {
        var smart = SmartSettings()
        smart.favorites.isOn = true
        let f = await SmartFixture(smart)
        await f.downloads.start(client: f.server.client)
        #expect(try await f.downloads.updateSmart(from: f.library, day: "2026-11-14") == nil)  // mirror not ready

        await f.mirror()
        let plan = try #require(try await f.downloads.updateSmart(from: f.library, day: "2026-11-14"))
        #expect(plan.added == ["s-1-1", "s-2-1", "s-2-2"])
        #expect(await f.states() == ["s-1-1": .queued, "s-2-1": .queued, "s-2-2": .queued])
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.server.requests("download").isEmpty)  // waits for the conditions

        await f.downloads.setSmartAllowed(true)
        #expect(await eventually { await f.states().values.allSatisfy { $0 == .done } })
        #expect(await f.downloads.store.entry("s-2-1")?.reasons == [.smart(.favorites)])

        // A user download of a starred song stays when the star goes.
        try await f.downloads.download([try #require(await f.library.database.songs(ids: ["s-1-1"]).first)])
        try await f.library.database.setStarred(nil, songIds: ["s-1-1"], albumIds: ["al-2"])
        let after = try #require(try await f.downloads.updateSmart(from: f.library, day: "2026-11-14"))
        #expect(after.removed == ["s-2-1", "s-2-2"])
        #expect(await f.states() == ["s-1-1": .done])
        #expect(await f.downloads.store.entry("s-1-1")?.reasons == [.song])
    }

    @Test func playlistsRecentAlbumsAndTheBudget() async throws {
        var smart = SmartSettings()
        smart.playlists.isOn = true
        smart.playlistIDs = ["pl-1"]
        smart.recentAlbums.isOn = true
        smart.recentDays = 10
        smart.budgetGB = 20e-3  // two estimated songs (8 MB each)
        let f = await SmartFixture(smart)
        f.server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t1", songIDs: ["s-3-2"])]
        var albums = f.server.albums
        albums[0].created = "2026-11-10T00:00:00Z"
        f.server.albums = albums
        await f.mirror()
        await f.downloads.start(client: f.server.client)

        let now = try #require(parseDate("2026-11-14T00:00:00Z"))
        let plan = try #require(try await f.downloads.updateSmart(from: f.library, day: "2026-11-14", now: now))
        // The global budget holds two: the best of each rule stay.
        #expect(plan.songs[.recentAlbums]?.map(\.id) == ["s-1-1"])
        #expect(plan.songs[.playlists]?.map(\.id) == ["s-3-2"])
        #expect(plan.added == ["s-1-1", "s-3-2"])
    }

    /// The app calls `refreshPins` after each mirror pass, reading the mirrored playlist.
    @Test func pinnedPlaylistFollowsServerEdits() async throws {
        let f = await SmartFixture(SmartSettings())
        f.server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t1", songIDs: ["s-1-1", "s-2-1"])]
        await f.mirror()
        await f.downloads.start(client: f.server.client)
        let playlist = try #require(await f.library.database.playlist(id: "pl-1"))
        try await f.downloads.pin(.playlist(playlist), songs: playlist.entry ?? [])
        #expect(await eventually { await f.states() == ["s-1-1": .done, "s-2-1": .done] })

        f.server.playlists = [StubPlaylist(id: "pl-1", name: "Mix", changed: "t2", songIDs: ["s-2-1", "s-3-1"])]
        f.server.lastScan = "scan-2"
        await f.library.mirror.syncNow()
        let db = f.library.database
        await f.downloads.refreshPins { await db.playlist(id: $0.reason == .playlist("pl-1") ? "pl-1" : "")?.entry }
        #expect(await eventually { await f.states() == ["s-2-1": .done, "s-3-1": .done] })
    }

    @Test func storageLimitDoesNotBlockSmartSongs() async throws {
        var smart = SmartSettings()
        smart.favorites.isOn = true
        let f = await SmartFixture(smart)
        var settings = DownloadSettings()
        settings.smart = smart
        settings.storageLimitGB = 1e-9  // nothing of the user's fits
        await f.downloads.update(settings: settings)
        await f.mirror()
        await f.downloads.start(client: f.server.client)
        await f.downloads.setSmartAllowed(true)
        try await f.downloads.updateSmart(from: f.library, day: "2026-11-14")
        #expect(await eventually { await f.states().count == 3 && f.server.requests("download").count == 3 })
        #expect(await eventually { await f.states().values.allSatisfy { $0 == .done } })
    }
}
