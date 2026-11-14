import Foundation
import Testing
@testable import Device
@testable import ITunesDB
@testable import Sync

@Suite struct StateTests {
    @Test func selectionRoundTripsAndToleratesMissingKeys() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SelectionStore(locations: testLocations(dir))
        #expect(store.load(deviceKey: "KEY").isEmpty)
        var selection = Selection()
        selection.albums = ["a"]; selection.artists = ["x"]; selection.playlists = ["p"]
        selection.albumPresets = ["a": "rockbox-flac"]
        selection.excludedAlbums = ["gone"]
        try store.save(selection, deviceKey: "KEY")
        #expect(store.load(deviceKey: "KEY") == selection)
        #expect(store.load(deviceKey: "OTHER").isEmpty)
        #expect(try JSONDecoder().decode(Selection.self, from: Data("{}".utf8)).isEmpty)
        #expect(selection.presetID(forAlbum: "a", default: "stock-aac") == "rockbox-flac")
        #expect(selection.presetID(forAlbum: "b", default: "stock-aac") == "stock-aac")
        selection.presetID = "rockbox-opus"
        #expect(selection.presetID(forAlbum: "b", default: "stock-aac") == "rockbox-opus")
    }

    @Test func manifestRoundTripsAndNeverBlocksOnBadFiles() throws {
        let pod = try FakeIPod.make()
        defer { pod.cleanup() }
        let d = makeDesired(makeSong("a"))
        var manifest = Manifest(serverKey: "srv")
        manifest.entries["a"] = makeEntry(d, dbid: 7, trackID: 3)
        manifest.playlists["p"] = 9
        manifest.artwork["al-1"] = 100
        manifest.lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        try ManifestStore.save(manifest, for: pod.device)
        let loaded = ManifestStore.load(for: pod.device, serverKey: "srv")
        #expect(loaded.manifest == manifest && loaded.warning == nil)

        // Other server: empty manifest, warning, file untouched.
        let other = ManifestStore.load(for: pod.device, serverKey: "other")
        #expect(other.manifest.entries.isEmpty && other.manifest.serverKey == "other" && other.warning != nil)

        // Corrupt: empty manifest, warning, copy kept for inspection.
        try Data("{not json".utf8).write(to: ManifestStore.url(for: pod.device))
        let corrupt = ManifestStore.load(for: pod.device, serverKey: "srv")
        #expect(corrupt.manifest.entries.isEmpty && corrupt.warning != nil)
        #expect(pod.exists("iPod_Control/MusicSync/manifest.json.corrupt"))

        try FileManager.default.removeItem(at: ManifestStore.url(for: pod.device))
        let missing = ManifestStore.load(for: pod.device, serverKey: "srv")
        #expect(missing.manifest.entries.isEmpty && missing.warning == nil)

        // Present but not readable: a sync stops, the app gets a warning.
        try FileManager.default.createDirectory(at: ManifestStore.url(for: pod.device), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ManifestStore.read(for: pod.device, serverKey: "srv") }
        #expect(ManifestStore.load(for: pod.device, serverKey: "srv").warning != nil)
    }

    @Test func corruptManifestNeverDeletesForeignTracksInASync() async throws {
        let pod = try FakeIPod.make(foreignTracks: 2)
        defer { pod.cleanup() }
        try FileManager.default.createDirectory(at: pod.device.musicSyncDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: ManifestStore.url(for: pod.device))
        let server = StubServer()
        let plan = try await makePlan(selection: Selection(), server: server, pod: pod)
        #expect(plan.remove.isEmpty)
        let run = await runSync(plan, pod: pod, server: server)
        #expect(run.error == nil && run.warnings.contains { $0.contains("manifest") })
        #expect(try pod.database().tracks.count == 2)
    }

    @Test func libraryGroupsAlbumsAndMarksManagedTracks() {
        var manifest = Manifest(serverKey: "s")
        manifest.entries["m1"] = makeEntry(makeDesired(makeSong("m1")), dbid: 77, trackID: 1)
        var managed = makeTrack(1, album: "Mine", artist: "Me", dbid: 77, size: 10)
        managed.albumArtist = ""
        let library = makeLibrary(tracks: [
            managed, makeTrack(2, album: "Other", artist: "Zed", size: 20), makeTrack(3, album: "Other", artist: "Zed", size: 30),
        ], manifest: manifest)
        #expect(library.albums.map(\.name) == ["Mine", "Other"])
        #expect(library.albums[0].artist == "Me" && library.albums[0].managedCount == 1)
        #expect(library.albums[1].tracks.map(\.title) == ["Foreign 2", "Foreign 3"] && library.albums[1].foreignCount == 2)
        #expect(library.totalSize == 60 && library.managedSize == 10 && library.foreignSize == 50)
        #expect(library.tracks.first?.songID == "m1")
        #expect(library.name == "Test iPod")
    }

    @Test func backupsKeepTheNewestTen() throws {
        let pod = try FakeIPod.make()
        defer { pod.cleanup() }
        try ManifestStore.save(Manifest(serverKey: "s"), for: pod.device)
        try Data("pc".utf8).write(to: pod.device.playCountsURL)
        let root = pod.root.appendingPathComponent("backups")
        var last = root
        for i in 0..<14 { last = try Backups.create(device: pod.device, root: root, now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)) }
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(kept.count == 10 && kept.last == last.lastPathComponent)
        let files = try FileManager.default.contentsOfDirectory(atPath: last.path).sorted()
        #expect(files == ["Play Counts", "iTunesDB", "manifest.json"])
        // Same second twice: both are kept apart.
        let a = try Backups.create(device: pod.device, root: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        let b = try Backups.create(device: pod.device, root: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(a != b)
    }

    @Test func originalDatabaseIsCopiedOnce() throws {
        let pod = try FakeIPod.make()
        defer { pod.cleanup() }
        Backups.keepOriginal(device: pod.device)
        let copy = pod.device.iTunesDir.appendingPathComponent("iTunesDB.musicsync-orig")
        let original = try Data(contentsOf: copy)
        try pod.write(ITunesDB.empty(name: "Changed"))
        Backups.keepOriginal(device: pod.device)
        #expect(try Data(contentsOf: copy) == original)
    }
}
