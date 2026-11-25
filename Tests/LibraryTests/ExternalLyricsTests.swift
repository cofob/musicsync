import Foundation
import Testing
@testable import Library
import Subsonic

@Suite struct ExternalLyricsTests {
    @Test func storesFoundAndNoneApartFromServerLyrics() async throws {
        let dir = TempDir()
        let db = dir.database()
        let synced: StructuredLyrics = decode(["synced": true, "line": [["start": 0, "value": "Hi"]]])
        #expect(await db.externalLyrics(songId: "s1", source: "LRCLIB") == nil)
        try await db.storeExternalLyrics(songId: "s1", source: "LRCLIB", lyrics: synced)
        try await db.storeExternalLyrics(songId: "s2", source: "LRCLIB", lyrics: nil)
        #expect(await db.externalLyrics(songId: "s1", source: "LRCLIB") == .some(synced))
        #expect(await db.externalLyrics(songId: "s2", source: "LRCLIB") == .some(nil))
        #expect(await db.externalLyrics(songId: "s1", source: "Other") == nil)
        // Server lyrics stay unknown, so the mirror still asks the server.
        #expect(await db.storedLyrics(songId: "s1") == nil)
        // An old "none" is asked again; found lyrics are kept.
        try await db.write { try $0.run("UPDATE external_lyrics SET fetchedAt = 0", []) }
        #expect(await db.externalLyrics(songId: "s2", source: "LRCLIB") == nil)
        #expect(await db.externalLyrics(songId: "s1", source: "LRCLIB") == .some(synced))
    }

    @Test func addsTheTableToAnExistingLibrary() async throws {
        let dir = TempDir()
        try await dir.database().write { try $0.exec("DROP TABLE external_lyrics") }
        let reopened = dir.database()
        try await reopened.storeExternalLyrics(songId: "s1", source: "LRCLIB", lyrics: nil)
        #expect(await reopened.externalLyrics(songId: "s1", source: "LRCLIB") == .some(nil))
    }

    @Test func storesVideos() async throws {
        let dir = TempDir()
        let db = dir.database()
        #expect(await db.externalVideo(songId: "s1") == nil)
        try await db.storeExternalVideo(songId: "s1", video: .youtube(id: "abcdefghijk"))
        try await db.storeExternalVideo(songId: "s2", video: nil)
        #expect(await db.externalVideo(songId: "s1") == .some(.youtube(id: "abcdefghijk")))
        #expect(await db.externalVideo(songId: "s2") == .some(nil))
    }
}
