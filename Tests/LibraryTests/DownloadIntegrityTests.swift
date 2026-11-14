import Foundation
import Testing
@testable import Library
import Subsonic

/// Short files, resumed downloads and leftover part files.
@Suite struct DownloadIntegrityTests {
    private func track(_ id: String, size: Int = 1000, duration: Int = 200) -> Song {
        decode(["id": id, "title": "Song \(id)", "album": "Album", "albumId": "al-1", "artist": "Artist", "duration": duration,
                "suffix": "flac", "size": size])
    }

    private func manager(_ dir: TempDir, _ settings: DownloadSettings = DownloadSettings(), backoff: Duration = .milliseconds(20)) -> DownloadManager {
        DownloadManager(serverKey: "demo@http://stub", directory: dir.url, settings: settings, backoff: { _ in backoff })
    }

    private func files(_ m: DownloadManager) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: m.filesDirectory.path)) ?? []).sorted()
    }

    private func failsEveryTry(_ song: Song, _ settings: DownloadSettings = DownloadSettings()) async throws {
        let dir = TempDir(), server = makeServer()
        let m = manager(dir, settings)
        await m.start(client: server.client)
        try await m.download([song])
        #expect(await eventually { await m.store.entry(song.id)?.state == .failed })
        #expect(server.requests(settings.quality == .original ? "download" : "stream").count == DownloadManager.maxAttempts)
        #expect(await m.store.entry(song.id)?.error?.hasPrefix("The download is incomplete") == true)
        #expect(files(m).isEmpty)
    }

    /// The server sends 1000 bytes of a 2000-byte original.
    @Test func smallerThanTheServerSizeFails() async throws {
        try await failsEveryTry(track("a", size: 2000))
    }

    /// The audio is 200 s of a 1000 s song; a conversion has no size to check.
    @Test func shorterThanTheSongFails() async throws {
        var settings = DownloadSettings()
        settings.quality = .mp3
        try await failsEveryTry(track("a", duration: 1000), settings)
    }

    private func part(_ m: DownloadManager, _ id: String) -> URL {
        m.filesDirectory.appendingPathComponent(DownloadManager.partPrefix + DownloadManager.fileName(id, suffix: "flac"))
    }

    /// Half a file from the first try: the second asks only for the rest.
    @Test func partResumesWithRange() async throws {
        let dir = TempDir(), server = makeServer()
        server.dropDownloads = 1
        let m = manager(dir, backoff: .milliseconds(500))
        await m.start(client: server.client)
        try await m.download([track("a")])
        #expect(await eventually { await m.waiting.count == 1 })
        try server.audio.prefix(500).write(to: part(m, "a"))
        #expect(await eventually { await m.store.entry("a")?.state == .done })
        #expect(server.ranges == ["bytes=500-"])
        let file = try #require(await m.store.entry("a").flatMap(m.fileURL))
        #expect(try Data(contentsOf: file) == server.audio)
        #expect(files(m) == [file.lastPathComponent])
    }

    @Test func droppedDownloadIsTriedAgain() async throws {
        let dir = TempDir(), server = makeServer()
        server.dropDownloads = 2
        let m = manager(dir)
        await m.start(client: server.client)
        try await m.download([track("a")])
        #expect(await eventually { await m.store.entry("a")?.state == .done })
        #expect(server.requests("download:a").count == 3)
    }

    @Test func cancelAndRemoveLeaveNoFiles() async throws {
        let dir = TempDir(), server = makeServer()
        server.dropDownloads = 2
        let m = manager(dir, backoff: .seconds(60))
        await m.start(client: server.client)
        try await m.download([track("a"), track("b")])
        #expect(await eventually { await m.waiting.count == 2 })
        // Both wait for a retry with part of the file.
        for id in ["a", "b"] { try server.audio.prefix(500).write(to: part(m, id)) }
        await m.cancel("a")
        #expect(files(m) == [part(m, "b").lastPathComponent])
        try await m.download([track("c")])
        #expect(await eventually { await m.store.entry("c")?.state == .done })
        try await m.removeAll()
        #expect(files(m).isEmpty)
    }

    /// A part file of a song that is no longer in the store (a crash) goes at the next start.
    @Test func startSweepsOrphanParts() async throws {
        let dir = TempDir(), server = makeServer()
        let m = manager(dir)
        let orphan = m.filesDirectory.appendingPathComponent("part-0123abcd.flac")
        try Data(count: 10).write(to: orphan)
        await m.start(client: server.client)
        #expect(files(m).isEmpty)
    }
}
