import AppKit
import Subsonic

/// `check:jukebox`: plays an album on the jukebox of `scripts/big-server.py` (run with BIG_MEDIA=1, so this Mac can
/// play it after), checks the stub's state after each control, and moves back to this Mac.
extension ShotChecks {
    static func jukebox(_ model: AppModel) async {
        guard model.config?.baseURL.host == "127.0.0.1", let client = model.client else {
            return check(false, "jukebox needs MUSICSYNC_DEMO_SERVER on 127.0.0.1")
        }
        let jukebox = model.jukebox, player = model.player
        check(await wait { jukebox.isAvailable }, "the stub offers the jukebox")
        guard let album = await Shot.first({ model.albums.first }), let songs = try? await model.album(album.id)?.song,
              songs.count > 4 else { return check(false, "an album with 5 songs") }
        /// Waits up to 10 s for the stub's jukebox to match.
        func server(_ what: String, _ matches: (JukeboxPlaylist) -> Bool) async {
            var last: JukeboxPlaylist?
            for _ in 0..<50 {
                last = try? await client.jukeboxPlaylist()
                if let last, matches(last) { return check(true, what) }
                try? await Task.sleep(for: .milliseconds(200))
            }
            check(false, "\(what): \(String(describing: last.map { ($0.songs.count, $0.status) }))")
        }

        await jukebox.activate()
        check(jukebox.isActive && player.remote != nil, "switches to the server")
        player.play(songs)
        await server("the server plays the album") { $0.songs.map(\.id) == songs.map(\.id) && $0.currentIndex == 0 && $0.playing == true }
        check(player.isPlaying && !player.mixer.hasCurrent, "nothing plays on this Mac")
        player.next()
        await server("Next skips on the server") { $0.currentIndex == 1 && $0.playing == true }
        player.seek(to: 60)
        await server("a seek moves the server") { (60..<70).contains($0.position ?? 0) }
        player.volume = 0.3
        await server("the volume sets the gain") { abs(($0.gain ?? 0) - 0.3) < 0.01 }
        player.toggle()
        await server("Pause stops the server") { $0.playing == false && $0.currentIndex == 1 }
        player.removeUpcoming(at: [0])
        await server("a queue edit keeps the song and position") {
            $0.songs.count == songs.count - 1 && $0.currentIndex == 1 && $0.playing == false && (59..<70).contains($0.position ?? 0)
        }
        player.toggle()
        try? await Task.sleep(for: .seconds(5))
        check(player.isPlaying && player.elapsed > 62, "the position runs on while the server plays: \(player.elapsed)")
        _ = try? await client.jukebox(.setGain(0.7))
        check(await wait { abs(player.volume - 0.7) < 0.01 }, "the poll brings another client's volume: \(player.volume)")
        // Hidden, the app stops asking the server; shown again, it catches up. The server's index 3 is songs[4].
        NSApp.hide(nil)
        _ = try? await client.jukebox(.skip(index: 3, offset: 0))
        try? await Task.sleep(for: .seconds(4))
        check(player.current?.id == songs[1].id, "no poll while the app is hidden: \(player.current?.title ?? "none")")
        NSApp.unhideWithoutActivation()
        check(await wait { player.current?.id == songs[4].id }, "the poll goes on when the app shows again: \(player.current?.title ?? "none")")
        // Another remote moves the server on: the poll brings its song.
        _ = try? await client.jukebox(.skip(index: 2, offset: 5))
        check(await wait { player.current?.id == songs[3].id }, "the poll follows the server's song: \(player.current?.title ?? "none")")

        await jukebox.deactivate()
        check(!jukebox.isActive && player.remote == nil && player.mixer.hasCurrent, "back on this Mac")
        check(player.current?.id == songs[3].id && (4...9).contains(player.elapsed), "goes on at the server's song and position: \(player.elapsed)")
        check(player.volume == 0, "the local volume comes back: \(player.volume)")
        await server("the server stopped") { $0.playing == false }
        player.pause()
    }
}
