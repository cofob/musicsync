import AppKit
import Subsonic

/// `check:flaky`: against `scripts/big-server.py` with `BIG_MEDIA=1` (streams) and a bad network
/// (e.g. `FAULT_DROP=0.3 FAULT_500=0.1 FAULT_LATENCY=2`).
/// Every main page finishes loading within `MUSICSYNC_FLAKY_SECONDS` (default 90) by itself, without a click on Try Again:
/// no loading placeholder and no "Couldn’t Load" message is left, and the page has its content. Then an album plays.
extension ShotChecks {
    static func flaky(_ model: AppModel) async {
        guard let base = model.config?.baseURL, base.host == "127.0.0.1" else { return check(false, "flaky needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        let bound = Double(ProcessInfo.processInfo.environment["MUSICSYNC_FLAKY_SECONDS"] ?? "") ?? 90
        let search = model.search
        let pages: [(String, () async -> Void, () -> Bool)] = [
            ("Home", { await Shot.select(.home, model) }, { !model.shelves.isEmpty }),
            ("Albums", { await Shot.select(.albums, model) }, { !model.albums.isEmpty }),
            ("Artists", { await Shot.select(.artists, model) }, { !model.artists.isEmpty }),
            ("Songs", { await Shot.select(.songs, model) }, { songRowsLoaded() }),
            ("Genres", { await Shot.select(.genres, model) }, { true }),
            ("Playlists", { await Shot.select(.playlists, model) }, { !model.playlists.isEmpty }),
            ("an album", { if let album = model.albums.first { model.show(.album(album)) } }, { !model.albums.isEmpty }),
            ("an artist", { if let id = model.albums.first?.artistId { model.show(.artist(id)) } }, { !model.albums.isEmpty }),
            ("a playlist", { if let playlist = model.playlists.first { model.show(.playlist(playlist)) } }, { !model.playlists.isEmpty }),
            ("search", { await Shot.select(.search, model); search.commit("Night") }, { !(search.result?.album.isEmpty ?? true) }),
        ]
        for (name, open, content) in pages {
            let start = Date()
            await open()
            let done = await settled(within: bound, content)
            let state = "\(PageProbe.placeholders) placeholders, \(PageProbe.failures) messages, content \(content())"
            check(done, "\(name) loads by itself in \(Int(Date().timeIntervalSince(start))) s (\(state))")
        }
        await messageRecovers(model, base: base, bound: bound)
        guard let album = model.albums.first else { return check(false, "an album to play") }
        let start = Date()
        model.play(album)
        let plays = await settled(within: bound) { model.player.isPlaying && model.player.elapsed > 1 }
        let player = model.player
        check(plays, "playback starts in \(Int(Date().timeIntervalSince(start))) s (\(player.current?.title ?? "no song"), \(Int(player.elapsed)) s, "
              + "offline \(model.downloads.isOffline), \(player.errorMessage ?? model.errorMessage ?? "no error"))")
        check(!model.downloads.isOffline, "the server does not count as offline")
        model.player.pause()
    }

    /// A page opened while the server refuses the password (not tried again by the client) shows the message,
    /// then loads by itself once the server takes the password again.
    private static func messageRecovers(_ model: AppModel, base: URL, bound: Double) async {
        guard let channel = model.podcasts.channels.first, let url = URL(string: "fault?auth=8", relativeTo: base) else {
            return check(false, "a podcast to open")
        }
        _ = try? await URLSession.shared.data(from: url)
        let start = Date()
        model.show(.podcast(channel))
        check(await wait { PageProbe.failures > 0 }, "a page that fails shows the message")
        let done = await settled(within: bound) { true }
        check(done, "the page loads by itself after the failure in \(Int(Date().timeIntervalSince(start))) s (\(PageProbe.failures) messages)")
    }

    /// True once nothing loads or failed on screen and `content` holds, for a whole second.
    private static func settled(within seconds: Double, _ content: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        var since: Date?
        while Date() < end {
            if PageProbe.placeholders == 0 && PageProbe.failures == 0 && content() {
                if Date().timeIntervalSince(since ?? Date()) >= 1 { return true }
                since = since ?? Date()
            } else { since = nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// The Songs table has rows and its first ones are filled.
    private static func songRowsLoaded() -> Bool {
        guard let table = Shot.tableView(in: mainWindow?.contentView) as? SongsTable.Table,
              let list = (table.delegate as? SongsTable.Coordinator)?.list, table.numberOfRows > 0 else { return false }
        return (0..<min(20, table.numberOfRows)).allSatisfy { list.item(at: $0) != nil }
    }
}
