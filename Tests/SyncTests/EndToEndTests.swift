import CoreGraphics
import Foundation
import Testing
@testable import Artwork
@testable import Device
@testable import ITunesDB
@testable import Subsonic
@testable import Sync
@testable import Transcode

/// Whole syncs against a fake iPod folder and an in-process server. Needs ffmpeg.
@Suite(.enabled(if: ffmpegTools != nil, "ffmpeg not installed"), .serialized)
struct EndToEndTests {
    /// Album al-1 with two real FLAC files and the playlist "Mix".
    struct Fixture {
        let pod: FakeIPod
        let server = StubServer()
        let dir: URL

        init(foreignTracks: Int = 1) throws {
            pod = try FakeIPod.make(foreignTracks: foreignTracks)
            dir = try tempDirectory("sync-audio")
            let a = try makeFLAC(in: dir, name: "a.flac", seconds: 2, frequency: 440)
            let b = try makeFLAC(in: dir, name: "b.flac", seconds: 3, frequency: 880)
            server.serve(songID: "s-1", file: a)
            server.serve(songID: "s-2", file: b)
            server.serveCover(makeCoverPNG())
            server.reply("getAlbum:al-1", StubServer.albumReply(albumJSON(id: "al-1", name: "Album One", songs: [
                songJSON("s-1", title: "First", track: 1, file: a, seconds: 2, extra: ["playCount": 3, "userRating": 4]),
                songJSON("s-2", title: "Second", track: 2, file: b, seconds: 3),
            ])))
            server.reply("getPlaylist:pl-1", StubServer.reply(["playlist": [
                "id": "pl-1", "name": "Mix", "songCount": 2, "entry": [
                    songJSON("s-2", title: "Second", track: 2, file: b, seconds: 3),
                    songJSON("s-1", title: "First", track: 1, file: a, seconds: 2),
                ],
            ]]))
        }

        func cleanup() { pod.cleanup(); try? FileManager.default.removeItem(at: dir) }
    }

    static func selection(albums: [String] = ["al-1"], playlists: [String] = ["pl-1"]) -> Selection {
        var s = Selection()
        s.albums = Set(albums)
        s.playlists = Set(playlists)
        return s
    }

    @Test func syncAddsTracksCoversAndPlaylistsThenRemovesThem() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let pod = f.pod

        // --- First sync
        let plan = try await makePlan(selection: Self.selection(), server: f.server, pod: pod)
        #expect(plan.add.count == 2 && plan.remove.isEmpty && plan.playlistsToCreate.count == 1)
        let run = await runSync(plan, pod: pod, server: f.server)
        #expect(run.error == nil)
        let summary = try #require(run.summary)
        #expect(summary.added == 2 && summary.failures.isEmpty && !summary.cancelled)

        let guidBytes = pod.guid
        let data = try Data(contentsOf: pod.device.iTunesDBURL)
        #expect(Hash58.verify(data, guid: guidBytes))
        let db = try ITunesDB.parse(data)
        #expect(db.tracks.count == 3)

        let foreign = try #require(db.tracks.first { $0.title == "Foreign 1" })
        #expect(pod.exists(ITunesDB.relativePath(ipodLocation: foreign.location)))
        let first = try #require(db.tracks.first { $0.title == "First" })
        let second = try #require(db.tracks.first { $0.title == "Second" })

        for (track, seconds) in [(first, 2.0), (second, 3.0)] {
            let path = ITunesDB.relativePath(ipodLocation: track.location)
            #expect(path.hasPrefix("iPod_Control/Music/F") && path.hasSuffix(".m4a"))
            #expect(Int(track.size) == pod.fileSize(path) && track.size > 0)
            #expect(abs(Double(track.lengthMs) - seconds * 1000) < 100)
            #expect(track.filetype == "M4A " && track.sampleRate == 44100)
            #expect(track.artist == "Test Artist" && track.album == "Album One" && track.albumArtist == "Test Artist")
            #expect(track.genre == "Rock" && track.year == 2020)
            #expect(track.trackCount == 2 && track.discNumber == 1 && track.discCount == 1)
            #expect(track.soundcheck == soundcheck(fromReplayGainDB: -7.25))
            #expect(track.gaplessTrackFlag && track.gaplessAlbumFlag)
            #expect(track.sampleCount == UInt64(seconds * 44100))  // exact, not rounded up to a frame
            #expect(track.pregap > 0 && track.timeAdded != nil)
            #expect(track.hasArtwork && track.artworkCount == 1 && track.mhiiLink >= ArtworkDB.minimumImageId)
        }
        #expect(first.trackNumber == 1 && second.trackNumber == 2)
        #expect(first.playCount == 3 && first.rating == 80)
        #expect(first.mhiiLink == second.mhiiLink)

        let manifest = pod.manifest()
        #expect(Set(manifest.entries.keys) == ["s-1", "s-2"])
        #expect(manifest.entries["s-1"]?.dbid == first.dbid && manifest.entries["s-1"]?.trackID == first.id)
        #expect(manifest.entries["s-2"]?.relativePath == ITunesDB.relativePath(ipodLocation: second.location))
        #expect(manifest.entries["s-1"]?.presetID == "stock-aac" && manifest.serverKey == f.server.client.serverKey)
        #expect(manifest.artwork["al-1"] == first.mhiiLink)

        let artwork = try ArtworkDB.load(artworkDirectory: pod.device.artworkDir)
        #expect(artwork.images.map(\.id) == [first.mhiiLink])
        #expect(pod.exists("iPod_Control/Artwork/F1060_1.ithmb") && pod.exists("iPod_Control/Artwork/ArtworkDB"))

        let mix = try #require(db.playlists.first { $0.name == "Mix" })
        #expect(mix.trackIDs == [second.id, first.id])
        #expect(manifest.playlists["pl-1"] == mix.persistentId)
        #expect(db.playlists[0].trackIDs.count == 3)

        #expect(pod.exists("iPod_Control/iTunes/iTunesDB.musicsync-orig"))
        #expect(pod.exists("iPod_Control/MusicSync/manifest.json"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: pod.locations.backupsDirectory(key: testGuid).path)
        #expect(backups.count == 1)
        #expect(!FileManager.default.fileExists(atPath: pod.locations.workDirectory.path + "/leftover"))

        // --- Nothing changed: empty plan
        let again = try await makePlan(selection: Self.selection(), server: f.server, pod: pod)
        #expect(again.isEmpty, "\(again.add.count) \(again.reencode.count) \(again.retag.count) \(again.remove.count)")

        // --- Unselect everything
        let removal = try await makePlan(selection: Selection(), server: f.server, pod: pod)
        #expect(removal.remove.count == 2 && removal.playlistsToDelete.count == 1)
        let run2 = await runSync(removal, pod: pod, server: f.server)
        #expect(run2.error == nil && run2.summary?.removed == 2)

        let db2 = try pod.database()
        #expect(db2.tracks.map(\.title) == ["Foreign 1"])
        #expect(db2.playlists.map(\.name) == ["Test iPod"])
        #expect(Hash58.verify(try Data(contentsOf: pod.device.iTunesDBURL), guid: guidBytes))
        #expect(pod.exists(ITunesDB.relativePath(ipodLocation: foreign.location)))
        for track in [first, second] { #expect(!pod.exists(ITunesDB.relativePath(ipodLocation: track.location))) }
        let manifest2 = pod.manifest()
        #expect(manifest2.entries.isEmpty && manifest2.playlists.isEmpty && manifest2.artwork.isEmpty)
        #expect(try ArtworkDB.load(artworkDirectory: pod.device.artworkDir).images.isEmpty)
        let engine = SyncEngine(locations: pod.locations)
        #expect(try await engine.orphans(device: pod.device).isEmpty)
    }

    @Test func retagAndReencodeKeepTheTrack() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let selection = Self.selection(playlists: [])
        let first = await runSync(try await makePlan(selection: selection, server: f.server, pod: f.pod), pod: f.pod, server: f.server)
        #expect(first.summary?.added == 2)
        let before = try f.pod.database()
        let oldTrack = try #require(before.tracks.first { $0.title == "First" })
        let oldPath = ITunesDB.relativePath(ipodLocation: oldTrack.location)

        // Server renames a song.
        let a = f.dir.appendingPathComponent("a.flac"), b = f.dir.appendingPathComponent("b.flac")
        f.server.reply("getAlbum:al-1", StubServer.albumReply(albumJSON(id: "al-1", name: "Album One", songs: [
            songJSON("s-1", title: "First (Remaster)", track: 1, file: a, seconds: 2),
            songJSON("s-2", title: "Second", track: 2, file: b, seconds: 3),
        ])))
        let retagPlan = try await makePlan(selection: selection, server: f.server, pod: f.pod)
        #expect(retagPlan.retag.count == 1 && retagPlan.add.isEmpty && retagPlan.reencode.isEmpty)
        let retagRun = await runSync(retagPlan, pod: f.pod, server: f.server)
        #expect(retagRun.summary?.retagged == 1)
        let renamed = try #require(try f.pod.database().tracks.first { $0.dbid == oldTrack.dbid })
        #expect(renamed.title == "First (Remaster)" && renamed.location == oldTrack.location && renamed.id == oldTrack.id)
        #expect(f.pod.exists(oldPath))

        // Preset version bump: new file, same track.
        var preset = Preset.stockAAC
        preset.version = 2
        let client = f.server.client
        let expansion = try await SelectionExpander(client: client)
            .expand(selection, defaultPresetID: "stock-aac", soundCheck: .album, presets: [preset])
        let manifest = ManifestStore.load(for: f.pod.device, serverKey: client.serverKey).manifest
        let library = try DeviceLibrary.load(device: f.pod.device, manifest: manifest, cacheDirectory: nil)
        let plan = SyncPlanner.plan(PlannerInput(desired: expansion.songs, manifest: manifest, library: library, freeBytes: 10_000_000_000))
        #expect(plan.reencode.count == 2 && plan.add.isEmpty && plan.remove.isEmpty)
        let run = await runSync(plan, pod: f.pod, server: f.server)
        #expect(run.summary?.reencoded == 2 && run.summary?.failures.isEmpty == true)
        let after = try f.pod.database()
        let same = try #require(after.tracks.first { $0.dbid == oldTrack.dbid })
        #expect(after.tracks.count == 3 && same.id == oldTrack.id && same.playCount == oldTrack.playCount)
        #expect(same.location != oldTrack.location && f.pod.exists(ITunesDB.relativePath(ipodLocation: same.location)))
        #expect(!f.pod.exists(oldPath) && same.hasArtwork)
        #expect(f.pod.manifest().entries["s-1"]?.presetVersion == 2)
        #expect(try await SyncEngine(locations: f.pod.locations).orphans(device: f.pod.device).isEmpty)
    }

    @Test func playCountsAreMergedScrobbledAndConsumed() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let selection = Self.selection(playlists: [])
        _ = await runSync(try await makePlan(selection: selection, server: f.server, pod: f.pod), pod: f.pod, server: f.server)
        let db = try f.pod.database()
        let playedAt = Date(timeIntervalSince1970: 1_750_000_000)
        // Record i belongs to track i: foreign, First (2 plays), Second (none).
        let order = db.tracks.map(\.title)
        let entries = order.map { title in
            PlayCountEntry(playCount: title == "First" ? 2 : 0, lastPlayed: title == "First" ? playedAt : nil, rating: 100)
        }
        try Self.writePlayCounts(entries, to: f.pod.device.playCountsURL)

        let plan = try await makePlan(selection: selection, server: f.server, pod: f.pod)
        #expect(plan.isEmpty)
        let run = await runSync(plan, pod: f.pod, server: f.server)
        #expect(run.error == nil && run.summary?.scrobblesSent == 2 && run.summary?.scrobblesPending == 0)
        let calls = f.server.scrobbles
        #expect(calls.count == 1 && calls[0].ids == ["s-1", "s-1"])
        #expect(Set(calls[0].times).count == 2 && calls[0].times.max().map { abs($0.timeIntervalSince(playedAt)) < 1 } == true)
        #expect(calls[0].times.max()!.timeIntervalSince(calls[0].times.min()!) > 1.5)  // one track length (2 s) apart

        let merged = try f.pod.database().tracks.first { $0.title == "First" }
        #expect(merged?.playCount == 5 && merged?.rating == 100)
        #expect(!f.pod.exists("iPod_Control/iTunes/Play Counts"))
        #expect(Hash58.verify(try Data(contentsOf: f.pod.device.iTunesDBURL), guid: f.pod.guid))
    }

    @Test func missingGuidFailsBeforeTouchingTheDevice() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try #require(FirewireGuid.resolve(for: f.pod.device, manualOverride: nil) == nil, "this machine reports a GUID for the temp volume")
        let before = try Data(contentsOf: f.pod.device.iTunesDBURL)
        let plan = try await makePlan(selection: Self.selection(), server: f.server, pod: f.pod)
        let run = await runSync(plan, pod: f.pod, server: f.server, settings: f.pod.settings(guid: false))
        #expect(run.error as? SyncError == .noFirewireGuid)
        #expect(try Data(contentsOf: f.pod.device.iTunesDBURL) == before)
        #expect(!f.pod.exists("iPod_Control/MusicSync"))
        #expect(!FileManager.default.fileExists(atPath: f.pod.locations.appSupport.appendingPathComponent("backups").path))
    }

    @Test func notEnoughSpaceFailsEarly() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let plan = try await makePlan(selection: Self.selection(), server: f.server, pod: f.pod, freeBytes: 100_000_000)
        #expect(!plan.fits)
        #expect((await runSync(plan, pod: f.pod, server: f.server)).error as? SyncError == .notEnoughSpace)
    }

    @Test func failedItemDoesNotStopTheRun() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.server.serve(songID: "s-1", file: f.dir.appendingPathComponent("missing.flac"))  // download answers 404
        let plan = try await makePlan(selection: Self.selection(playlists: ["pl-1"]), server: f.server, pod: f.pod)
        let run = await runSync(plan, pod: f.pod, server: f.server)
        let summary = try #require(run.summary)
        #expect(summary.added == 1 && summary.failures.map(\.songID) == ["s-1"])
        let db = try f.pod.database()
        #expect(db.tracks.map(\.title).sorted() == ["Foreign 1", "Second"])
        // The playlist holds only what reached the device.
        #expect(db.playlists.first { $0.name == "Mix" }?.trackIDs.count == 1)
        #expect(Set(f.pod.manifest().entries.keys) == ["s-2"])
    }

    @Test func cancellationLeavesAConsistentDatabase() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let songs = try (1...6).map { i -> [String: Any] in
            let file = try makeFLAC(in: f.dir, name: "c\(i).flac", seconds: 1, frequency: 300 + i * 50)
            f.server.serve(songID: "c-\(i)", file: file)
            return songJSON("c-\(i)", title: "Cancel \(i)", track: i, album: "Many", albumId: "al-9", file: file, seconds: 1)
        }
        f.server.reply("getAlbum:al-9", StubServer.albumReply(albumJSON(id: "al-9", name: "Many", songs: songs)))
        f.server.downloadDelay = 0.4
        var settings = f.pod.settings()
        settings.workers = 1
        let plan = try await makePlan(selection: Self.selection(albums: ["al-9"], playlists: []), server: f.server, pod: f.pod)
        let run = await runSync(plan, pod: f.pod, server: f.server, settings: settings, cancelAfterFirstItem: true)

        #expect(run.error is CancellationError)
        let summary = try #require(run.summary)
        #expect(summary.cancelled && summary.added >= 1 && summary.added < 6)

        let data = try Data(contentsOf: f.pod.device.iTunesDBURL)
        #expect(Hash58.verify(data, guid: f.pod.guid))
        let db = try ITunesDB.parse(data)
        let manifest = f.pod.manifest()
        #expect(db.tracks.count == 1 + summary.added && manifest.entries.count == summary.added)
        for entry in manifest.entries.values {
            #expect(f.pod.exists(entry.relativePath) && db.tracks.contains { $0.dbid == entry.dbid })
        }
        #expect(db.tracks.contains { $0.title == "Foreign 1" })
        #expect(try await SyncEngine(locations: f.pod.locations).orphans(device: f.pod.device).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.pod.locations.workDirectory.path)) ?? []).isEmpty)

        // The next sync finishes the job.
        f.server.downloadDelay = 0
        let rest = try await makePlan(selection: Self.selection(albums: ["al-9"], playlists: []), server: f.server, pod: f.pod)
        #expect(rest.add.count == 6 - summary.added)
        let finish = await runSync(rest, pod: f.pod, server: f.server)
        #expect(finish.error == nil)
        #expect(try f.pod.database().tracks.count == 7)
    }

    @Test func lyricsGoIntoTheFileAndTheDatabase() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.server.reply("getLyricsBySongId:s-1", StubServer.reply(["lyricsList": ["structuredLyrics": [
            ["synced": true, "line": [["start": 0, "value": "First line"], ["start": 1000, "value": "Second line"]]],
        ]]]))
        let plan = try await makePlan(selection: Self.selection(playlists: []), server: f.server, pod: f.pod)
        let run = await runSync(plan, pod: f.pod, server: f.server)
        #expect(run.error == nil && run.summary?.added == 2)
        let db = try ITunesDB.parse(Data(contentsOf: f.pod.device.iTunesDBURL))
        let first = try #require(db.tracks.first { $0.title == "First" })
        let second = try #require(db.tracks.first { $0.title == "Second" })
        #expect(first.lyricsFlag && !second.lyricsFlag)

        let tools = try #require(ffmpegTools)
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = tools.ffprobe
        probe.arguments = ["-v", "error", "-show_entries", "format_tags=lyrics", "-of", "default=nw=1:nk=1",
                           f.pod.device.mountURL.appendingPathComponent(ITunesDB.relativePath(ipodLocation: first.location)).path]
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "First line\nSecond line")
    }

    @Test func deletedForeignTrackLeavesDatabaseAndDisk() async throws {
        let f = try Fixture(foreignTracks: 2)
        defer { f.cleanup() }
        let before = try ITunesDB.parse(Data(contentsOf: f.pod.device.iTunesDBURL))
        let foreign = try #require(before.tracks.first)
        var plan = SyncPlan()
        plan.deleteTracks = [foreign.dbid]
        plan.reserveBytes = 0
        let run = await runSync(plan, pod: f.pod, server: f.server)
        #expect(run.error == nil && run.summary?.removed == 1)
        let data = try Data(contentsOf: f.pod.device.iTunesDBURL)
        #expect(Hash58.verify(data, guid: f.pod.guid))
        let after = try ITunesDB.parse(data)
        #expect(after.tracks.map(\.dbid) == before.tracks.dropFirst().map(\.dbid))
        #expect(!f.pod.exists(ITunesDB.relativePath(ipodLocation: foreign.location)))
    }

    @Test func orphansAreFoundAndCleaned() async throws {
        let pod = try FakeIPod.make()
        defer { pod.cleanup() }
        try Data(count: 123).write(to: pod.device.musicDir.appendingPathComponent("F03/ORPH.m4a"))
        let engine = SyncEngine(locations: pod.locations)
        let found = try await engine.orphans(device: pod.device)
        #expect(found == [Orphan(path: "iPod_Control/Music/F03/ORPH.m4a", size: 123)])
        try await engine.cleanOrphans(device: pod.device)
        #expect(!pod.exists("iPod_Control/Music/F03/ORPH.m4a") && pod.exists("iPod_Control/Music/F09/FRG1.m4a"))

        let broken = try FakeIPod.make(withDatabase: false)
        defer { broken.cleanup() }
        try Data(count: 5).write(to: broken.device.musicDir.appendingPathComponent("F01/KEEP.m4a"))
        await #expect(throws: SyncError.self) { try await engine.cleanOrphans(device: broken.device) }
        #expect(broken.exists("iPod_Control/Music/F01/KEEP.m4a"))
    }

    // MARK: Helpers

    /// Writes a `Play Counts` file (24-byte records).
    static func writePlayCounts(_ entries: [PlayCountEntry], to url: URL) throws {
        var d = Data("mhdp".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(0x60); u32(0x14); u32(UInt32(entries.count))
        d.append(Data(count: 0x60 - 16))
        for e in entries {
            u32(e.playCount)
            u32(e.lastPlayed.map { UInt32(Int64($0.timeIntervalSince1970) + 2_082_844_800 + Int64(TimeZone.current.secondsFromGMT(for: $0))) } ?? 0)
            u32(e.bookmark); u32(e.rating ?? 0); u32(e.skipCount)
        }
        try d.write(to: url)
    }
}
