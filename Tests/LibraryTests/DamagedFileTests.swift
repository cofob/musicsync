import Foundation
import Subsonic
import Testing
@testable import Library

/// Damaged download and cache files: reads give empty values, nothing traps, and good rows still load.
@Suite struct DamagedFileTests {
    private func song(_ id: String) -> Song { decode(["id": id, "title": "Song \(id)", "duration": 200, "size": 1000]) }

    @Test func garbageDownloadStoreReadsEmpty() async throws {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("downloads.sqlite")
        try Data(repeating: 0xAB, count: 8192).write(to: url)
        let store = DownloadStore(fileURL: url)
        #expect(await store.entries().isEmpty)
        #expect(await store.pins().isEmpty)
        #expect(await store.usedBytes() == 0)
        #expect(await store.entry("s-1") == nil)
        #expect(await store.lyrics("s-1") == nil)
        #expect(await store.pinOrder().isEmpty)
        await #expect(throws: (any Error).self) { try await store.add([song("s-1")], reason: .album("al-1")) }
        // The user's file is kept as it is.
        #expect(try Data(contentsOf: url) == Data(repeating: 0xAB, count: 8192))
    }

    @Test func damagedRowsAreSkipped() async throws {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("downloads.sqlite")
        let store = DownloadStore(fileURL: url)
        try await store.add([song("s-1"), song("s-2")], reason: .album("al-1"))
        let db = try SQLiteConnection(path: url.path)
        try db.run("UPDATE songs SET json = 'garbage', size = 9223372036854775807 WHERE id = 's-1'")
        try db.run("UPDATE songs SET state = 'nonsense', size = -5 WHERE id = 's-2'")
        try db.run("INSERT INTO pins(reason, json, songIDs, addedAt) VALUES('album:x', '{', 'nope', 0)")
        #expect(await store.entries().map(\.song.id) == ["s-2"])
        #expect(await store.pins().isEmpty)
        _ = await store.usedBytes()
    }

    @Test func damagedPlaybackCacheIndexIsIgnored() async throws {
        let dir = TempDir()
        let folder = dir.url.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dir.url.appendingPathComponent("victim"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("big"))
        for data in [Data("garbage".utf8), Data(#"{"items":{"a":{"fileName":"../victim","size":4,"used":1},"b":{"fileName":"big","size":9223372036854775807,"used":1e300}}}"#.utf8)] {
            try data.write(to: folder.appendingPathComponent("index.json"))
            let cache = PlaybackCache(serverKey: "k", directory: folder, limitGB: 1)
            #expect(await cache.files().isEmpty)
            #expect(await cache.usedBytes() == 0)
        }
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("victim").path))
    }

    @Test func serverSuffixStaysInTheCacheFolder() async throws {
        let dir = TempDir(), server = StubLibraryServer()
        let cache = PlaybackCache(serverKey: "k", directory: dir.url.appendingPathComponent("cache"), limitGB: 1)
        let song: Song = decode(["id": "s-1", "title": "T", "suffix": "../../flac", "size": 1000])
        let file = try #require(try await cache.store(song, format: "raw", maxBitRate: nil, client: server.client))
        #expect(file.deletingLastPathComponent().lastPathComponent == "cache" && file.pathExtension == "flac")
        let huge: Song = decode(["id": "s-2", "title": "T", "duration": Int.max])
        _ = try await cache.store(huge, format: "mp3", maxBitRate: nil, client: server.client)
    }

    @Test func junkServerNumbersGiveBoundedEstimates() {
        let song: Song = decode(["id": "s", "title": "T", "suffix": "flac", "duration": Int.max, "bitRate": Int.max, "size": Int.max])
        let unsized: Song = decode(["id": "s", "title": "T", "suffix": "flac", "duration": Int.max, "bitRate": Int.max])
        let plans = [DownloadPlan(format: nil, maxBitRate: nil, suffix: "flac", bitRate: .max), DownloadPlan(format: "mp3", maxBitRate: 320, suffix: "mp3", bitRate: .max)]
        let sizes = plans.flatMap { plan in [song, unsized].map(plan.estimate) }
        #expect(sizes.allSatisfy { (0..<1 << 50).contains($0) })
    }
}
