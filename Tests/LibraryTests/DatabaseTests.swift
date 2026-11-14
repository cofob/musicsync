import Foundation
import ImageIO
import Testing
@testable import Library
import Subsonic

@Suite struct DatabaseTests {
    @Test func opensAndKeepsDataAcrossReopen() async throws {
        let dir = TempDir()
        let db = dir.database()
        #expect(await db.isHealthy)
        #expect(await db.isPopulated == false)
        try await seed(db, albums: [(album("al", "First"), [song("s1", "One")])])
        try await db.setMeta(["lastFullSync": "1"])

        let again = dir.database()
        #expect(await again.albums().map(\.id) == ["al"])
        #expect(await again.album(id: "al")?.song?.map(\.id) == ["s1"])
        #expect(await again.isPopulated)
    }

    @Test func garbageFileIsReplaced() async throws {
        let dir = TempDir()
        let db = dir.database()
        try Data("this is not a database, just text".utf8).write(to: db.fileURL)
        #expect(await db.isHealthy)
        #expect(await db.albums().isEmpty)
        try await seed(db, albums: [(album("al", "First"), [song("s1", "One")])])
        #expect(await db.songCount() == 1)
        #expect(dir.asideFiles.count == 1)
    }

    @Test func damagedPagesAreReplaced() async throws {
        let dir = TempDir()
        do {
            let db = dir.database()
            try await seed(db, albums: (1...50).map { n in (album("al-\(n)", "Album \(n)"), [song("s\(n)", "Song \(n)", albumId: "al-\(n)")]) })
        }
        let url = dir.database().fileURL
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        var bytes = try Data(contentsOf: url)
        for i in 4096..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try bytes.write(to: url)

        let db = dir.database()
        #expect(await db.isHealthy)
        #expect(await db.albums().isEmpty)
        #expect(await db.isPopulated == false)
        #expect(dir.asideFiles.count == 1)
    }

    @Test func schemaVersionChangeRebuilds() async throws {
        let dir = TempDir()
        let path: String
        do {
            let db = dir.database()
            try await seed(db, albums: [(album("al", "First"), [song("s1", "One")])])
            path = db.fileURL.path
        }
        let raw = try SQLiteConnection(path: path)
        try raw.exec("PRAGMA user_version = \(Schema.version + 1)")
        try raw.exec("PRAGMA wal_checkpoint(TRUNCATE)")

        let db = dir.database()
        #expect(await db.albums().isEmpty)
        #expect(await db.isHealthy)
        #expect(dir.asideFiles.count == 1)
        try await seed(db, albums: [(album("al", "First"), [song("s1", "One")])])
        #expect(await db.albumCount() == 1)
    }

    @Test func albumListingCursorSurvivesReopenAndClearsWhenFinished() async throws {
        let dir = TempDir()
        let cursor = AlbumCursor(run: "run-1", offset: 0, scan: "scan")
        do {
            let db = dir.database()
            try await db.beginAlbumListing(cursor)
            try await db.storeAlbumPage([album("a1", "One"), album("a2", "Two")], run: "run-1", nextOffset: 2)
        }
        let db = dir.database()
        #expect(await db.albumCursor() == AlbumCursor(run: "run-1", offset: 2, scan: "scan"))
        try await db.storeAlbumPage([album("a3", "Three")], run: "run-1", nextOffset: 3)
        try await db.finishAlbumListing(run: "run-1")
        #expect(await db.albumCursor() == nil)
        #expect(await db.albumCount() == 3)
    }

    @Test func eachServerHasItsOwnFile() async throws {
        let dir = TempDir()
        let a = dir.database(key: "a@one"), b = dir.database(key: "a@two")
        #expect(a.fileURL != b.fileURL)
        try await seed(a, albums: [(album("al", "First"), [])].map { ($0.0, [song("s1", "One")]) })
        #expect(await b.albums().isEmpty)
        #expect(await a.albums().count == 1)
    }

    @Test func unusableLocationDegradesToEmptyReads() async {
        let dir = TempDir()
        let blocker = dir.url.appendingPathComponent("file")
        try? Data("x".utf8).write(to: blocker)
        let db = LibraryDatabase(serverKey: "k", directory: blocker, coversDirectory: dir.url.appendingPathComponent("c"))
        #expect(await db.isHealthy == false)
        #expect(await db.albums().isEmpty)
        #expect(await db.album(id: "x") == nil)
        #expect(await db.search("x").song.isEmpty)
        #expect(await db.songCount() == 0)
        await #expect(throws: (any Error).self) { try await db.replaceArtists([]) }
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let settings = try JSONDecoder().decode(MirrorSettings.self, from: Data(#"{"enabled":false,"throttleMs":5}"#.utf8))
        #expect(settings.enabled == false && settings.throttleMs == 5)
        #expect(settings.intervalMinutes == 30 && settings.includeCovers)
    }

    @Test func insertingTwentyThousandSongsIsFast() async throws {
        let dir = TempDir()
        let db = dir.database()
        let data = (0..<2000).map { n -> (Album, [Song]) in
            (album("al-\(n)", "Album \(n)", songs: 10),
             (0..<10).map { song("s-\(n)-\($0)", "Song \(n) \($0)", albumId: "al-\(n)", track: $0 + 1) })
        }
        let start = ContinuousClock.now
        try await db.storeAlbumPage(data.map(\.0), run: "r", nextOffset: 2000)
        for (a, songs) in data { try await db.storeAlbumTracks(albumId: a.id, songs: songs) }
        let elapsed = ContinuousClock.now - start
        #expect(await db.songCount() == 20_000)
        #expect(elapsed < .seconds(3))
        #expect(await db.search("song 1999").song.isEmpty == false)
    }

    @Test func pagesAreSortedFilteredAndFast() async throws {
        let dir = TempDir()
        let db = dir.database()
        try await seed(db, albums: (0..<2000).map { n in
            (album("al-\(n)", "Album \(n)", songs: 10),
             (0..<10).map { song("s-\(n)-\($0)", "Song \(n) \($0)", albumId: "al-\(n)", track: $0 + 1) })
        })
        #expect(await db.songCount(matching: "") == 20_000)
        #expect(await db.songCount(matching: "song 1999") == 10)
        #expect(await db.albumCount(matching: "album 7") == 111)  // 7, 70–79, 700–799
        let start = ContinuousClock.now
        let deep = await db.songs(sort: .title, matching: "", limit: 200, offset: 19_800)
        #expect(ContinuousClock.now - start < .milliseconds(300))
        #expect(deep.count == 200)
        let forward = await db.songs(sort: .title, matching: "", limit: 20_000, offset: 0)
        let backward = await db.songs(sort: .title, descending: true, matching: "", limit: 20_000, offset: 0)
        #expect(backward.map(\.id) == forward.reversed().map(\.id))
        #expect(await db.albums(sort: .name, matching: "album 7", limit: 5, offset: 0).map(\.name) == ["Album 7", "Album 70", "Album 700", "Album 701", "Album 702"])
    }
}

@Test func smallCoverIsScaledJPEG() throws {
    let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))

    let small = LibraryDatabase.compactCover(png as Data)
    let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == LibraryDatabase.smallCoverSize)
}
