import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Device
@testable import ITunesDB
@testable import Subsonic
@testable import Sync
@testable import Transcode

@Suite(.enabled(if: ffmpegTools != nil, "ffmpeg not installed"), .serialized)
struct RockboxEndToEndTests {
    /// al-1 (stock) and al-2 (Rockbox Opus) plus a playlist that mixes both.
    struct Fixture {
        let base: EndToEndTests.Fixture
        var pod: FakeIPod { base.pod }
        var server: StubServer { base.server }

        init(withDatabase: Bool = true) throws {
            base = try EndToEndTests.Fixture()
            let c = try makeFLAC(in: base.dir, name: "r1.flac", seconds: 2, frequency: 500)
            let d = try makeFLAC(in: base.dir, name: "r2.flac", seconds: 2, frequency: 600)
            server.serve(songID: "r-1", file: c)
            server.serve(songID: "r-2", file: d)
            server.reply("getAlbum:al-2", StubServer.albumReply(albumJSON(id: "al-2", name: "Album/Two: Live?", songs: [
                songJSON("r-1", title: "Rock: One", track: 1, album: "Album/Two: Live?", albumId: "al-2", file: c, seconds: 2),
                songJSON("r-2", title: "Rock Two", track: 2, album: "Album/Two: Live?", albumId: "al-2", file: d, seconds: 2),
            ])))
            server.reply("getPlaylist:pl-1", StubServer.reply(["playlist": [
                "id": "pl-1", "name": "Mix", "songCount": 3, "entry": [
                    songJSON("s-1", title: "First", track: 1, file: base.dir.appendingPathComponent("a.flac"), seconds: 2),
                    songJSON("r-2", title: "Rock Two", track: 2, album: "Album/Two: Live?", albumId: "al-2", file: d, seconds: 2),
                    songJSON("r-1", title: "Rock: One", track: 1, album: "Album/Two: Live?", albumId: "al-2", file: c, seconds: 2),
                ],
            ]]))
        }

        func selection(rockbox: Bool = true, playlist: Bool = true) -> Selection {
            var s = Selection()
            s.albums = rockbox ? ["al-1", "al-2"] : ["al-1"]
            s.playlists = playlist ? ["pl-1"] : []
            s.albumPresets = rockbox ? ["al-2": "rockbox-opus"] : [:]
            return s
        }
    }

    @Test func rockboxAlbumsLandInFoldersNextToStockTracks() async throws {
        let f = try Fixture()
        defer { f.base.cleanup() }
        let pod = f.pod
        let plan = try await makePlan(selection: f.selection(), server: f.server, pod: pod)
        let run = await runSync(plan, pod: pod, server: f.server)
        #expect(run.error == nil)
        let summary = try #require(run.summary)
        #expect(summary.added == 4 && summary.failures.isEmpty)

        // Rockbox files, named by the layout rules.
        let manifest = pod.manifest()
        #expect(Set(manifest.rockboxEntries.keys) == ["r-1", "r-2"] && Set(manifest.entries.keys) == ["s-1", "s-2"])
        let one = try #require(manifest.rockboxEntries["r-1"])
        #expect(one.relativePath == "Music/Test Artist/2020 - Album_Two_ Live_/01-01 - Rock_ One.opus")
        #expect(manifest.rockboxEntries["r-2"]?.relativePath == "Music/Test Artist/2020 - Album_Two_ Live_/01-02 - Rock Two.opus")
        #expect(one.dbid == 0 && one.presetID == "rockbox-opus")
        let tools = try #require(ffmpegTools)
        let info = try await tools.probe(pod.device.mountURL.appendingPathComponent(one.relativePath))
        #expect(info.codec == "opus" && abs(info.durationSeconds - 2) < 0.2)
        #expect(Int64(pod.fileSize(one.relativePath)) == one.outSize)

        // Tags are embedded by ffmpeg.
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = tools.ffprobe
        probe.arguments = ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json",
                           pod.device.mountURL.appendingPathComponent(one.relativePath).path]
        probe.standardOutput = pipe
        try probe.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        probe.waitUntilExit()
        #expect(text.contains("rock: one") && text.contains("test artist") && text.contains("album/two: live?"))

        // cover.jpg: baseline JPEG, 500x500.
        let coverURL = pod.device.mountURL.appendingPathComponent("Music/Test Artist/2020 - Album_Two_ Live_/cover.jpg")
        let cover = try Data(contentsOf: coverURL)
        #expect(cover.range(of: Data([0xFF, 0xC2])) == nil && cover.prefix(2) == Data([0xFF, 0xD8]))
        let source = try #require(CGImageSourceCreateWithData(cover as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 500 && image.height == 500)

        // The iTunesDB knows only the stock tracks and still verifies.
        let data = try Data(contentsOf: pod.device.iTunesDBURL)
        #expect(Hash58.verify(data, guid: pod.guid))
        let db = try ITunesDB.parse(data)
        #expect(db.tracks.map(\.title).sorted() == ["First", "Foreign 1", "Second"])
        #expect(db.playlists.first { $0.name == "Mix" }?.trackIDs == [manifest.entries["s-1"]!.trackID])

        // m3u8 with paths relative to /Playlists, in server order.
        let m3u = try String(contentsOf: pod.device.mountURL.appendingPathComponent("Playlists/Mix.m3u8"), encoding: .utf8)
        #expect(m3u == "#EXTM3U\n../\(manifest.rockboxEntries["r-2"]!.relativePath)\n../\(one.relativePath)\n")
        #expect(manifest.rockboxPlaylists["pl-1"]?.path == "Playlists/Mix.m3u8")

        // Nothing to do on the next run.
        let again = try await makePlan(selection: f.selection(), server: f.server, pod: pod)
        #expect(again.isEmpty, "add \(again.add.map(\.id)) re \(again.reencode.map(\.desired.id)) rt \(again.retag.map(\.desired.id)) rm \(again.remove.map(\.songID)) up \(again.playlistsToUpdate.map(\.id)) cr \(again.playlistsToCreate.map(\.id))")

        // Dropping the album and the playlist from the selection keeps their files.
        let removal = try await makePlan(selection: f.selection(rockbox: false, playlist: false), server: f.server, pod: pod)
        #expect(removal.remove.isEmpty && removal.playlistsToDelete.isEmpty)
    }

    @Test func rockboxOnlyDeviceNeedsNeitherGuidNorDatabase() async throws {
        let f = try Fixture()
        defer { f.base.cleanup() }
        try FileManager.default.removeItem(at: f.pod.device.iTunesDBURL)
        try #require(FirewireGuid.resolve(for: f.pod.device, manualOverride: nil) == nil)
        var selection = Selection()
        selection.albums = ["al-2"]
        selection.presetID = "rockbox-opus"
        let plan = try await makePlan(selection: selection, server: f.server, pod: f.pod)
        #expect(!plan.touchesStock && plan.add.count == 2)
        let run = await runSync(plan, pod: f.pod, server: f.server, settings: f.pod.settings(guid: false))
        #expect(run.error == nil && run.summary?.added == 2)
        #expect(!FileManager.default.fileExists(atPath: f.pod.device.iTunesDBURL.path))
        #expect(f.pod.manifest().rockboxEntries.count == 2)
    }

    @Test func switchingAnAlbumFromStockToRockboxMovesItsFiles() async throws {
        let f = try Fixture()
        defer { f.base.cleanup() }
        _ = await runSync(try await makePlan(selection: f.selection(rockbox: false, playlist: false), server: f.server, pod: f.pod), pod: f.pod, server: f.server)
        #expect(f.pod.manifest().entries.count == 2)

        var selection = f.selection(rockbox: false, playlist: false)
        selection.albumPresets = ["al-1": "rockbox-opus"]
        let plan = try await makePlan(selection: selection, server: f.server, pod: f.pod)
        #expect(plan.remove.count == 2 && plan.add.count == 2)
        let run = await runSync(plan, pod: f.pod, server: f.server)
        #expect(run.error == nil && run.summary?.failures.isEmpty == true)
        let manifest = f.pod.manifest()
        #expect(manifest.entries.isEmpty && manifest.rockboxEntries.count == 2 && manifest.artwork.isEmpty)
        #expect(try f.pod.database().tracks.map(\.title) == ["Foreign 1"])
        #expect(try await SyncEngine(locations: f.pod.locations).orphans(device: f.pod.device).isEmpty)
    }
}
