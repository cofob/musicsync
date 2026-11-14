import Foundation
import Testing
@testable import Library
import Subsonic

/// A song the stub server serves as 1000 bytes.
private func track(_ id: String) -> Song {
    decode(["id": id, "title": "Song \(id)", "album": "Album", "albumId": "al-1", "artist": "Artist", "duration": 200,
            "suffix": "flac", "size": 1000, "coverArt": "cov-al-1"])
}

private func manager(_ dir: TempDir, _ settings: DownloadSettings = DownloadSettings()) -> DownloadManager {
    DownloadManager(serverKey: "demo@http://stub", directory: dir.url, settings: settings, backoff: { _ in .milliseconds(20) })
}

private func states(_ m: DownloadManager) async -> [String: DownloadState] {
    Dictionary(uniqueKeysWithValues: await m.store.entries().map { ($0.id, $0.state) })
}

private func allDone(_ m: DownloadManager, _ count: Int) async -> Bool {
    await eventually { let s = await states(m); return s.count == count && s.values.allSatisfy { $0 == .done } }
}

@Suite struct DownloadStoreTests {
    @Test func songStaysWhileAnyReasonIsLeft() async throws {
        let dir = TempDir()
        let store = DownloadStore(fileURL: dir.url.appendingPathComponent("d.sqlite"))
        try await store.add([track("a")], reason: .song)
        #expect(try await store.pin(.album(album("al-1", "One")), songs: [track("a"), track("b")]).isEmpty)
        #expect(await store.entry("a")?.reasons == [.song, .album("al-1")])

        let released = try await store.remove(.album("al-1"))
        #expect(released.map(\.id) == ["b"])
        #expect(await store.entries().map(\.id) == ["a"])
        #expect(await store.pins().isEmpty)
        #expect(try await store.remove(.song, songIDs: ["a"]).map(\.id) == ["a"])
        #expect(await store.entries().isEmpty)
    }

    @Test func pinFollowsContentChanges() async throws {
        let dir = TempDir()
        let store = DownloadStore(fileURL: dir.url.appendingPathComponent("d.sqlite"))
        let pin = DownloadPin.playlist(decode(["id": "pl-1", "name": "Mix"]))
        _ = try await store.pin(pin, songs: [track("a"), track("b")])
        let released = try await store.pin(pin, songs: [track("b"), track("c")])
        #expect(released.map(\.id) == ["a"])
        #expect(Set(await store.entries().map(\.id)) == ["b", "c"])
        #expect(await store.entry("c")?.state == .queued)
        #expect(await store.pins().map(\.id) == ["playlist:pl-1"])
    }

    @Test func pinKeepsItsOrderAndRepeats() async throws {
        let dir = TempDir()
        let store = DownloadStore(fileURL: dir.url.appendingPathComponent("d.sqlite"))
        _ = try await store.pin(.playlist(decode(["id": "pl-1", "name": "Mix"])), songs: [track("b"), track("a"), track("b")])
        #expect(await store.pinOrder() == [.playlist("pl-1"): ["b", "a", "b"]])
        #expect(Set(await store.entries().map(\.id)) == ["a", "b"])
    }

    @Test func interruptedDownloadsQueueAgainAfterRestart() async throws {
        let dir = TempDir()
        let file = dir.url.appendingPathComponent("d.sqlite")
        try await DownloadStore(fileURL: file).add([track("a")], reason: .song)
        #expect(try await DownloadStore(fileURL: file).markDownloading("a"))
        let reopened = DownloadStore(fileURL: file)
        #expect(await reopened.nextQueued(excluding: []) == nil)
        try await reopened.resetInterrupted()
        #expect(await reopened.nextQueued(excluding: [])?.id == "a")
        #expect(await reopened.nextQueued(excluding: ["a"]) == nil)
    }
}

@Suite struct DownloadManagerTests {
    @Test func downloadsFilesCoversAndLyrics() async throws {
        let dir = TempDir(), server = makeServer()
        server.setLyrics(song: "a", synced: false, lines: [(0, "La")])
        let m = manager(dir)
        await m.start(client: server.client)
        try await m.pin(.album(album("al-1", "One")), songs: [track("a"), track("b")])

        #expect(await allDone(m, 2))
        let entry = try #require(await m.store.entry("a"))
        let file = try #require(m.fileURL(entry))
        #expect(try Data(contentsOf: file) == server.audio)
        #expect(entry.size == 1000 && entry.format == "flac")
        #expect(await m.store.usedBytes() == 2000)
        #expect(await m.store.lyrics("a")?.first?.line.first?.value == "La")
        #expect(FileManager.default.fileExists(atPath: m.coversDirectory.appendingPathComponent("cov-al-1@600").path))
        #expect(server.requests("download").count == 2)
        #expect(await eventually { m.currentStatus.batchTotal == 0 && m.currentStatus.progress.isEmpty })

        try await m.remove(.album("al-1"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: m.coversDirectory.path))?.isEmpty == true })
    }

    @Test func convertedQualityStreamsWithFormat() async throws {
        let dir = TempDir(), server = makeServer()
        var settings = DownloadSettings()
        settings.quality = .mp3
        settings.maxBitRate = 128
        let m = manager(dir, settings)
        await m.start(client: server.client)
        try await m.download([track("a")])
        #expect(await allDone(m, 1))
        #expect(server.requests("stream") == ["stream:a"])
        #expect(await m.store.entry("a")?.fileName?.hasSuffix(".mp3") == true)
        #expect(await m.store.entry("a")?.bitRate == 128)
    }

    @Test func failuresAreRetriedThenKept() async throws {
        let dir = TempDir(), server = makeServer()
        let m = manager(dir)
        await m.start(client: server.client)
        server.failDownloads = 2
        try await m.download([track("a")])
        #expect(await allDone(m, 1))

        server.failDownloads = 10
        try await m.download([track("b")])
        #expect(await eventually { await m.store.entry("b")?.state == .failed })
        #expect(server.requests("download:b").count == DownloadManager.maxAttempts)
        #expect(await m.store.entry("b")?.error != nil)

        server.failDownloads = 0
        await m.retry(["b"])
        #expect(await allDone(m, 2))
    }

    @Test func cancelStopsUntilRetry() async throws {
        let dir = TempDir(), server = makeServer()
        server.delayMs = 3000
        let m = manager(dir)
        await m.start(client: server.client)
        try await m.download([track("a")])
        #expect(await eventually { await m.store.entry("a")?.state == .downloading })
        await m.cancel("a")
        #expect(await eventually { await m.running.isEmpty })
        let entry = try #require(await m.store.entry("a"))
        #expect(entry.isCancelled && entry.fileName == nil)
        #expect(server.requests("download:a").count <= 1)  // no retry; the cancel can come before the request reaches the stub
        #expect(await m.waiting.isEmpty)

        server.delayMs = 0
        await m.retry(["a"])
        #expect(await allDone(m, 1))
    }

    @Test func storageLimitStopsNewDownloads() async throws {
        let dir = TempDir(), server = makeServer()
        var settings = DownloadSettings()
        settings.storageLimitGB = 2500 / 1e9
        settings.concurrency = 1
        let m = manager(dir, settings)
        await m.start(client: server.client)
        try await m.download([track("a"), track("b"), track("c")])
        #expect(await eventually { m.currentStatus.blocked == .storageLimit })
        #expect(await states(m) == ["a": .done, "b": .done, "c": .queued])

        settings.storageLimitGB = 0
        await m.update(settings: settings)
        #expect(await allDone(m, 3))
        #expect(m.currentStatus.blocked == nil)
    }

    @Test func queueResumesAfterRestart() async throws {
        let dir = TempDir(), server = makeServer()
        server.delayMs = 3000
        let first = manager(dir)
        await first.start(client: server.client)
        try await first.download([track("a")])
        #expect(await eventually { await first.store.entry("a")?.state == .downloading })
        await first.stop()

        server.delayMs = 0
        let second = manager(dir)
        await second.start(client: server.client)
        #expect(await allDone(second, 1))
    }

    @Test func offlinePausesTheQueue() async throws {
        let dir = TempDir(), server = makeServer()
        let m = manager(dir)
        await m.setOffline(true)
        await m.start(client: server.client)
        try await m.download([track("a")])
        #expect(m.currentStatus.blocked == .offline)
        #expect(server.requests("download").isEmpty)
        await m.setOffline(false)
        #expect(await allDone(m, 1))
    }
}

@Suite struct DownloadSettingsTests {
    @Test func roundTripAndDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "download-settings-\(UUID().uuidString)"))
        #expect(DownloadSettings.load(from: defaults) == DownloadSettings())
        var settings = DownloadSettings()
        settings.quality = .aac
        settings.maxBitRate = 192
        settings.storageLimitGB = 5
        settings.save(to: defaults)
        #expect(DownloadSettings.load(from: defaults) == settings)

        let old = try JSONDecoder().decode(DownloadSettings.self, from: Data(#"{"quality":"mp3"}"#.utf8))
        #expect(old.quality == .mp3 && old.maxBitRate == 256 && old.concurrency == 2)
    }

    @Test func plans() {
        var settings = DownloadSettings()
        #expect(settings.plan(for: track("a")) == DownloadPlan(format: nil, maxBitRate: nil, suffix: "flac", bitRate: nil))
        let ogg: Song = decode(["id": "o", "title": "O", "suffix": "ogg", "duration": 100])
        #expect(settings.plan(for: ogg).format == "mp3")
        settings.quality = .aac
        settings.maxBitRate = 128
        #expect(settings.plan(for: track("a")) == DownloadPlan(format: "aac", maxBitRate: 128, suffix: "aac", bitRate: 128))
        #expect(settings.plan(for: ogg).estimate(ogg) == 100 * 128 * 125)
    }
}
