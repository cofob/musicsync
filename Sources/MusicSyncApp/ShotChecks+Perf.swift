import AppKit
import Support

/// `check:perf`: the actions that touch the whole library, timed by the longest wait of the main queue while
/// each runs and settles. Any wait over 250 ms fails. Best with a fresh `MUSICSYNC_DEMO_DIR` and the big library
/// of `scripts/big-server.py`, so the first part runs while the mirror is in its "Syncing Songs" phase.
extension ShotChecks {
    static func perf(_ model: AppModel) async {
        let meter = HangMeter()
        defer { meter.stop() }
        func time(_ name: String, settle: Double = 1.5, _ action: () async -> Void) async {
            _ = meter.lap()
            await action()
            try? await Task.sleep(for: .seconds(settle))
            let ms = Int(meter.lap() * 1000)
            check(ms <= 250, "perf \(name): longest main-thread stall \(ms) ms")
        }
        let pages: [SidebarItem] = [.home, .albums, .artists, .songs, .genres, .favorites, .downloaded]

        let syncing = { model.mirrorStatus.state == .running && model.mirrorStatus.phase == .tracks }
        if await wait(syncing) {
            for item in pages where syncing() { await time("syncing: \(item.title)") { await Shot.select(item, model) } }
        } else {
            FileHandle.standardError.write(Data("perf: no \"Syncing Songs\" phase seen; use a fresh MUSICSYNC_DEMO_DIR\n".utf8))
        }

        await Shot.mirrored(model)
        for _ in 0..<6000 where model.isMirrorRunning { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2))  // the reload after the pass
        for item in pages { await time(item.title) { await Shot.select(item, model) } }

        await Shot.select(.songs, model)
        try? await Task.sleep(for: .seconds(2))
        await time("scroll Songs") { await scroll(Shot.tableView(in: mainWindow?.contentView)?.enclosingScrollView, by: 150 * 24) }
        await Shot.select(.albums, model)
        try? await Task.sleep(for: .seconds(2))
        await time("scroll Albums") { await scroll(largestScrollView(), by: 2000) }

        for item in [SidebarItem.songs, .albums, .artists, .search] {
            await Shot.select(item, model)
            try? await Task.sleep(for: .seconds(1))
            await time("type on \(item.title)", settle: 2) {
                for end in "night echo".indices { model.searchText = String("night echo"[...end]); try? await Task.sleep(for: .milliseconds(150)) }
            }
            model.searchText = ""
            try? await Task.sleep(for: .seconds(1))
        }

        if let artist = model.artists.max(by: { ($0.albumCount ?? 0) < ($1.albumCount ?? 0) }) {
            await Shot.select(.artists, model)
            await time("artist with \(artist.albumCount ?? 0) albums", settle: 3) { model.show(.artist(artist.id)) }
        }
        guard let playlist = model.playlists.max(by: { ($0.songCount ?? 0) < ($1.songCount ?? 0) }) else { return check(false, "a playlist") }
        await time("playlist of \(playlist.songCount ?? 0) songs", settle: 3) { await Shot.select(.playlist(playlist.id), model) }
        let songs = (try? await model.playlist(playlist.id))?.entry ?? []
        await time("play \(songs.count) songs") { model.mixes.play(songs, from: .playlist, shuffled: false) }
        if model.player.isPlaying { model.player.toggle() }
        await time("Up Next of \(model.player.queue.count) songs", settle: 2) {
            model.nowPlayingPanel = .queue
            model.showNowPlaying = true
        }
        await time("close Now Playing") { model.showNowPlaying = false }
    }

    /// Scrolls down `step` points every 30 ms, 100 times, as a fast scroll does.
    private static func scroll(_ view: NSScrollView?, by step: CGFloat) async {
        guard let view else { return check(false, "a scroll view") }
        for _ in 0..<100 {
            view.contentView.scroll(to: NSPoint(x: 0, y: view.contentView.bounds.minY + step))
            view.reflectScrolledClipView(view.contentView)
            try? await Task.sleep(for: .milliseconds(30))
        }
        check(view.contentView.bounds.minY > 50 * step, "scrolled to \(Int(view.contentView.bounds.minY)) pt")
    }

    /// The scroll view with the tallest content in the main window: the page's own.
    private static func largestScrollView() -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return mainWindow?.contentView.map(all)?.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}
