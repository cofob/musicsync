import Foundation
import Testing
@testable import Library
import Subsonic

/// Full mirror pass against a real server. Runs only with MUSICSYNC_LIVE_URL, MUSICSYNC_LIVE_USER
/// and MUSICSYNC_LIVE_PASSFILE set; MUSICSYNC_LIVE_DIR keeps the database for inspection.
private let env = ProcessInfo.processInfo.environment

@Test(.enabled(if: env["MUSICSYNC_LIVE_URL"] != nil), .timeLimit(.minutes(60)))
func liveMirrorPass() async throws {
    let password = try String(contentsOfFile: env["MUSICSYNC_LIVE_PASSFILE"]!, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let client = SubsonicClient(baseURL: URL(string: env["MUSICSYNC_LIVE_URL"]!)!, username: env["MUSICSYNC_LIVE_USER"]!, password: password)
    let dir = TempDir()
    let root = env["MUSICSYNC_LIVE_DIR"].map { URL(fileURLWithPath: $0) } ?? dir.url
    let db = LibraryDatabase(serverKey: "live", directory: root, coversDirectory: root.appendingPathComponent("covers"))
    var settings = MirrorSettings()
    settings.enabled = false
    let mirror = LibraryMirror(database: db, settings: settings)
    await mirror.start(client: client)

    let log = Task {
        var last: (MirrorPhase?, Int) = (nil, -1)
        for await s in mirror.status where s.phase != last.0 || s.done / 500 != last.1 {
            last = (s.phase, s.done / 500)
            print("[mirror] \(s.state) \(s.phase?.rawValue ?? "-") \(s.done)/\(s.total.map(String.init) ?? "?") warnings=\(s.warnings) \(s.lastWarning ?? "")")
        }
    }
    for pass in 1...2 {
        let start = Date()
        await mirror.syncNow()
        let s = mirror.currentStatus
        print("[pass \(pass)] \(Int(Date().timeIntervalSince(start)))s state=\(s.state) warnings=\(s.warnings) \(s.lastWarning ?? "")")
        print("[pass \(pass)] artists=\(await db.artistCount()) albums=\(await db.albumCount()) songs=\(await db.songCount()) playlists=\(await db.playlists().count)")
        #expect(s.lastSuccess != nil)
    }
    log.cancel()
    await mirror.stop()

    #expect(await db.isPopulated)
    #expect(await db.albumCount() > 0)
    let first = try #require(await db.albums().first)
    #expect(await db.album(id: first.id)?.song?.isEmpty == false)
    let hits = await db.search(String(first.name.prefix(4)))
    #expect(hits.album.isEmpty == false)
}
