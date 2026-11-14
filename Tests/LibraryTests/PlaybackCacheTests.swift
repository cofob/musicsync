import Foundation
import Subsonic
import Testing
@testable import Library

/// A 1000-byte song.
private func track(_ id: String) -> Song {
    decode(["id": id, "title": "Song \(id)", "duration": 200, "suffix": "flac", "size": 1000])
}

@Suite struct CacheIndexTests {
    private func item(_ name: String, _ size: Int64, _ used: Double) -> CacheIndex.Item { .init(fileName: name, size: size, used: used) }

    @Test func evictsLeastRecentlyUsedFirst() {
        var index = CacheIndex()
        #expect(index.insert("a", item("a", 400, 1), limit: 1000).isEmpty)
        #expect(index.insert("b", item("b", 400, 2), limit: 1000).isEmpty)
        index.touch("a", at: 3)
        #expect(index.insert("c", item("c", 400, 4), limit: 1000).map(\.fileName) == ["b"])
        #expect(Set(index.items.keys) == ["a", "c"])
        #expect(index.bytes == 800)
    }

    @Test func trimAndOversizedItems() {
        var index = CacheIndex()
        _ = index.insert("a", item("a", 300, 1), limit: 1000)
        _ = index.insert("b", item("b", 300, 2), limit: 1000)
        #expect(index.trim(to: 300).map(\.fileName) == ["a"])
        #expect(index.trim(to: 0).map(\.fileName) == ["b"])
        #expect(index.insert("big", item("big", 2000, 5), limit: 1000).map(\.fileName) == ["big"])
        #expect(index.items.isEmpty)
    }

    @Test func replacingAFileReturnsTheOldOne() {
        var index = CacheIndex()
        _ = index.insert("a", item("a.flac", 300, 1), limit: 1000)
        #expect(index.insert("a", item("a.mp3", 200, 2), limit: 1000).map(\.fileName) == ["a.flac"])
        #expect(index.bytes == 200)
    }
}

@Suite struct PlaybackCacheTests {
    @Test func storesTheStreamAndEvictsTheOldest() async throws {
        let dir = TempDir(), server = makeServer()
        let cache = PlaybackCache(serverKey: "demo@http://stub", directory: dir.url, limitGB: 2500 / 1e9)
        let file = try #require(try await cache.store(track("a"), format: "raw", maxBitRate: nil, client: server.client))
        #expect(file.pathExtension == "flac")
        #expect(try Data(contentsOf: file) == server.audio)
        #expect(server.requests("stream") == ["stream:a"])
        #expect(try await cache.store(track("a"), format: "raw", maxBitRate: nil, client: server.client) == file)
        #expect(server.requests("stream").count == 1)  // already cached

        let b = try #require(try await cache.store(track("b"), format: "mp3", maxBitRate: 128, client: server.client))
        #expect(b.pathExtension == "mp3")
        await cache.touch("a")
        _ = try await cache.store(track("c"), format: "raw", maxBitRate: nil, client: server.client)
        #expect(Set(await cache.files().keys) == ["a", "c"])
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(await cache.usedBytes() == 2000)

        // The index survives a restart.
        let reopened = PlaybackCache(serverKey: "demo@http://stub", directory: dir.url, limitGB: 2500 / 1e9)
        #expect(Set(await reopened.files().keys) == ["a", "c"])
        await reopened.setLimit(gb: 1500 / 1e9)
        #expect(Set(await reopened.files().keys) == ["c"])
        await reopened.clear()
        #expect(await reopened.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A lost connection is tried again; a file shorter than the song is not kept, and no part file is left.
    @Test func checksAndRetriesTheDownload() async throws {
        let dir = TempDir(), server = makeServer()
        let cache = PlaybackCache(serverKey: "demo@http://stub", directory: dir.url, limitGB: 1)
        server.dropDownloads = 2
        #expect(try await cache.store(track("a"), format: "raw", maxBitRate: nil, client: server.client) != nil)
        #expect(server.requests("stream:a").count == 3)
        let long: Song = decode(["id": "b", "title": "Long", "duration": 1000, "suffix": "flac", "size": 1000])
        await #expect(throws: (any Error).self) { try await cache.store(long, format: "raw", maxBitRate: nil, client: server.client) }
        #expect(Set(await cache.files().keys) == ["a"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(!names.contains { $0.hasPrefix(DownloadManager.partPrefix) })
    }

    @Test func offCacheStoresNothing() async throws {
        let dir = TempDir(), server = makeServer()
        let cache = PlaybackCache(serverKey: "demo@http://stub", directory: dir.url, limitGB: 0)
        #expect(try await cache.store(track("a"), format: "raw", maxBitRate: nil, client: server.client) == nil)
        #expect(server.requests("stream").isEmpty)
    }
}
