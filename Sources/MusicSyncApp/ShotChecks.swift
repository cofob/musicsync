import AppIntents
import AppKit
import Playback
import Subsonic
import SwiftUI

/// Development only: `check:<name>` scenes act on the real AppKit objects as AppKit does on a click or a key
/// (the demo window is never key, and with a locked screen posted events do not land), log each result to
/// stderr and make the shot exit 1 when one fails. Checks that change a playlist need the local stub server
/// (`MUSICSYNC_DEMO_SERVER`); on the public demo they change the play queue only.
@MainActor enum ShotChecks {
    private(set) static var failed = false
    /// The menu that a pop-up opened, closed again by a timer.
    private static var tracked: NSMenu?

    static func run(_ name: String, _ model: AppModel) async {
        model.player.privateSession = true  // nothing is scrobbled
        switch name {
        case "songs": await songsTable(model)
        case "songs-drop": await songsDrop(model)
        case "songlist": await songList(model)
        case "playlist-keys", "playlist-keys-pushed": await playlistKeys(model, pushed: name.hasSuffix("pushed"))
        case "miniplayer": await miniPlayer(model)
        case "equalizer": await equalizer(model)
        case "artists": await artists(model)
        case "nowplaying-lyrics": await nowPlayingLyrics(model)
        case "nowplaying-drag": await nowPlayingDrag(model)
        case "podcast-resume": await podcastResume(model)
        case "accessibility": await accessibility(model)
        case "intents": await intents(model)
        case "perf": await perf(model)
        case "jukebox": await jukebox(model)
        case "appearance": await appearance(model)
        case "mixes": await mixRules(model)
        default: check(false, "known check \(name)")
        }
    }

    static func check(_ ok: Bool, _ what: String) {
        FileHandle.standardError.write(Data("CHECK \(ok ? "PASS" : "FAIL") \(what)\n".utf8))
        if !ok { failed = true }
    }

    // MARK: Songs page

    private static func songsTable(_ model: AppModel) async {
        await Shot.mirrored(model)
        _ = await wait { !model.isMirrorRunning }  // its refresh would clear the selection
        await Shot.playPaused(model)
        await Shot.select(.songs, model)
        guard let (table, coordinator) = await songs(), let window = table.window, let list = coordinator.list else { return }
        let player = model.player
        let ids = { (rows: [Int]) in rows.compactMap { list.item(at: $0)?.id } }

        let one = rowMenu(table, 2)
        check(titles(one).starts(with: ["Play Next", "Add to Queue"]), "row menu: \(titles(one))")
        perform("Play Next", in: one)
        check(await wait { player.upcoming.first?.id == ids([2]).first }, "row Play Next puts the row after the current song")

        table.selectRowIndexes([4, 6, 7], byExtendingSelection: false)
        let many = rowMenu(table, 6)
        check(titles(many).starts(with: ["Play", "Play Next", "Add to Queue"]), "selection menu: \(titles(many))")
        perform("Add to Queue", in: many)
        check(await wait { player.upcoming.prefix(4).map(\.id) == ids([2, 4, 6, 7]) }, "selection Add to Queue puts the 3 rows after the Play Next row")
        perform("Play Next", in: many)
        check(await wait { player.upcoming.prefix(3).map(\.id) == ids([4, 6, 7]) }, "selection Play Next puts the 3 rows next")
        check(titles(rowMenu(table, 9)).contains("Get Info"), "a row outside the selection gets its own menu")
        check(table.selectedRowIndexes == [4, 6, 7], "the menu keeps the selection")

        let dropped = await dragged(table, coordinator, model)
        check(dropped == ids([4, 6, 7]), "drag of the selection carries its song ids: \(dropped)")

        window.makeFirstResponder(table)
        check(selectAll(window) && table.selectedRowIndexes.count == table.numberOfRows, "⌘A selects all \(table.numberOfRows) rows")
        key(53, "\u{1b}", window).map(table.keyDown)
        try? await Task.sleep(for: .milliseconds(300))
        check(table.selectedRowIndexes.isEmpty, "Escape clears the selection (left: \(table.selectedRowIndexes.count))")

        table.selectRowIndexes([3], byExtendingSelection: false)
        key(36, "\r", window).map(table.keyDown)
        check(await wait { player.current?.id == ids([3]).first && player.queue.count > 1 }, "Return plays from the selected row")
        let rect = table.rect(ofRow: 5)
        await click(table, at: NSPoint(x: rect.minX + 30, y: rect.midY), count: 2)
        check(table.selectedRowIndexes == [5], "a click selects its row: \(Array(table.selectedRowIndexes))")
        check(await wait { player.current?.id == ids([5]).first }, "double-click plays from the clicked row")
        if player.isPlaying { player.toggle() }

        await moreButton(table, coordinator)
        await sortByTitle(table, coordinator)
        await libraryRefresh(table, coordinator, model)
    }

    /// A library refresh brings a new list of the same rows; the table stays where it was.
    private static func libraryRefresh(_ table: NSTableView, _ coordinator: SongsTable.Coordinator, _ model: AppModel) async {
        let old = coordinator.list
        table.scrollRowToVisible(300)
        try? await Task.sleep(for: .milliseconds(300))
        let top = table.rows(in: table.visibleRect).location
        model.apply(artists: model.artists, albums: model.albums, playlists: model.playlists)
        let changed = await wait { coordinator.list !== old }
        try? await Task.sleep(for: .milliseconds(300))
        let now = table.rows(in: table.visibleRect).location
        check(changed && top > 200 && abs(now - top) < 3, "a library refresh keeps the scroll place: row \(top) → \(now)")
    }

    /// The table once its first rows have loaded.
    static func songs() async -> (SongsTable.Table, SongsTable.Coordinator)? {
        let found = await Shot.first { () -> (SongsTable.Table, SongsTable.Coordinator)? in
            guard let table = Shot.tableView(in: mainWindow?.contentView) as? SongsTable.Table,
                  let coordinator = table.delegate as? SongsTable.Coordinator, let list = coordinator.list,
                  table.numberOfRows > 20, (0..<20).allSatisfy({ list.item(at: $0) != nil }) else { return nil }
            return (table, coordinator)
        }
        check(found != nil, "Songs table has loaded rows")
        return found
    }

    /// The context menu of a right-click on `row`.
    private static func rowMenu(_ table: NSTableView, _ row: Int) -> NSMenu? {
        let rect = table.rect(ofRow: row)
        guard let window = table.window else { return nil }
        let menu = mouse(.rightMouseDown, table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), window).flatMap(table.menu(for:))
        menu.map { table.didCloseMenu($0, with: nil) }  // as AppKit does when the menu closes: clears `clickedRow`
        return menu
    }

    /// Writes the selected rows to a pasteboard as a drag does and reads them back as the sidebar drop does.
    private static func dragged(_ table: NSTableView, _ coordinator: SongsTable.Coordinator, _ model: AppModel) async -> [String] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("musicsync-check-\(getpid())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(table.selectedRowIndexes.compactMap { coordinator.tableView(table, pasteboardWriterForRow: $0) })
        let items = pasteboard.pasteboardItems ?? []
        check(items.count == table.selectedRowIndexes.count && items.allSatisfy { $0.types.contains(.string) },
              "drag pasteboard: \(items.map { $0.types.map(\.rawValue) })")
        return await model.songIds(items.compactMap { $0.string(forType: .string) }.compactMap(DragPayload.init))
    }

    /// The "•••" of a title cell takes the click and opens the song menu; the rest of the cell leaves it to the table.
    private static func moreButton(_ table: NSTableView, _ coordinator: SongsTable.Coordinator) async {
        table.scrollRowToVisible(0)
        try? await Task.sleep(for: .milliseconds(300))
        guard let cell = table.view(atColumn: table.column(withIdentifier: .init("title")), row: 1, makeIfNecessary: false) as? SongsTable.TextCell,
              let window = cell.window else { return check(false, "title cell of row 1") }
        let frame = cell.frame
        check(cell.hitTest(NSPoint(x: frame.maxX - 15, y: frame.midY)) === cell && cell.hitTest(NSPoint(x: frame.minX + 20, y: frame.midY)) == nil,
              "the ••• area takes the click, the title leaves it to the table")
        let point = cell.convert(NSPoint(x: frame.width - 15, y: frame.height / 2), to: nil)
        let shown = await popUp { mouse(.leftMouseDown, point, window).map(cell.mouseDown) }
        check(titles(shown).starts(with: ["Play Next", "Add to Queue"]), "••• opens the song menu: \(titles(shown))")
        check(table.selectedRowIndexes == [5], "••• leaves the selection")
    }

    /// A click on the Title header sorts by title, a second one reverses it.
    private static func sortByTitle(_ table: NSTableView, _ coordinator: SongsTable.Coordinator) async {
        guard let header = table.headerView else { return check(false, "table header") }
        let column = table.column(withIdentifier: .init("title"))
        var lists: [PagedList<Song>] = coordinator.list.map { [$0] } ?? []
        for ascending in [true, false] {
            let rect = header.headerRect(ofColumn: column)
            track(header, at: NSPoint(x: rect.midX, y: rect.midY))
            let list = await Shot.first { () -> PagedList<Song>? in
                guard let list = coordinator.list, !lists.contains(where: { $0 === list }), table.sortDescriptors.first?.ascending == ascending, (0..<5).allSatisfy({ list.item(at: $0) != nil }) else { return nil }
                return list
            }
            let titles = (0..<5).compactMap { list?.item(at: $0)?.title }
            let sorted = zip(titles, titles.dropFirst()).allSatisfy { ($0.localizedCaseInsensitiveCompare($1) == .orderedDescending) != ascending || $0.localizedCaseInsensitiveCompare($1) == .orderedSame }
            let descriptor = table.sortDescriptors.first
            check(list != nil && sorted && descriptor?.key == "title" && descriptor?.ascending == ascending,
                  "Title header sorts \(ascending ? "up" : "down"): \(titles)")
            list.map { lists.append($0) }
        }
    }

    /// The sidebar playlist drop with the dragged songs, against the local stub server.
    private static func songsDrop(_ model: AppModel) async {
        guard model.config?.baseURL.host == "127.0.0.1" else { return check(false, "songs-drop needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        await Shot.mirrored(model)
        await Shot.select(.songs, model)
        guard let (table, coordinator) = await songs(), let list = coordinator.list,
              let playlist = await Shot.first({ model.editablePlaylists.last }) else { return }
        table.selectRowIndexes([1, 2, 3], byExtendingSelection: false)
        let ids = await dragged(table, coordinator, model)
        check(ids == [1, 2, 3].compactMap { list.item(at: $0)?.id }, "drag carries the 3 song ids")
        let before = playlist.songCount ?? 0
        model.add(ids, to: playlist)
        // A second run finds the songs there already: then the drop asks first.
        let asks = { if case .duplicates(ids, _, 3)? = model.playlistPrompt { true } else { false } }
        check(await wait { model.playlists.first { $0.id == playlist.id }?.songCount == before + 3 || asks() },
              "drop adds 3 songs to \(playlist.name) (\(before)), or asks about duplicates: \(asks())")
    }

    // MARK: Album and playlist lists

    /// Click, ⌘A, Return and Escape on an album page.
    private static func songList(_ model: AppModel) async {
        await Shot.select(.albums, model)
        guard let album = await Shot.first({ model.albums.first { ($0.songCount ?? 0) > 3 } }),
              let songs = try? await model.album(album.id)?.song, let window = mainWindow else { return check(false, "an album") }
        model.show(.album(album))
        try? await Task.sleep(for: .seconds(3))
        let player = model.player
        let ids = songs.map(\.id)
        await tap(window, row: 1, top: 393, height: 42)
        check(responder(window), "a click focuses the list: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        await send(key(36, "\r", window), window)
        check(await wait { player.current?.id == ids[1] && player.queue.map(\.id) == ids }, "Return plays the album from the clicked row: \(player.current.flatMap { ids.firstIndex(of: $0.id) } ?? -1)")
        check(selectAll(window), "⌘A goes to the list")
        try? await Task.sleep(for: .milliseconds(300))
        await send(key(36, "\r", window), window)
        check(await wait { player.current?.id == ids[0] && player.queue.map(\.id) == ids }, "⌘A, Return plays all rows")
        player.next()
        check(await wait { player.current?.id == ids[1] }, "next song")
        await send(key(53, "\u{1b}", window), window)
        await send(key(36, "\r", window), window)
        try? await Task.sleep(for: .seconds(2))
        check(player.current?.id == ids[1], "Escape clears: Return then plays nothing: \(player.current.flatMap { ids.firstIndex(of: $0.id) } ?? -1)")
        if player.isPlaying { player.toggle() }
    }

    /// Return and ⌘A on an own playlist, opened from the sidebar or pushed from Playlists; Delete and Edit > Delete
    /// instead against the local stub server, which has no audio.
    private static func playlistKeys(_ model: AppModel, pushed: Bool) async {
        guard let playlist = await Shot.first({ model.editablePlaylists.first { ($0.songCount ?? 0) > 2 } }), let window = mainWindow else { return check(false, "a playlist") }
        if pushed { await Shot.select(.playlists, model); model.show(.playlist(playlist)) } else { await Shot.select(.playlist(playlist.id), model) }
        try? await Task.sleep(for: .seconds(3))
        await tap(window, row: 1, top: 414, height: 54)
        guard model.config?.baseURL.host == "127.0.0.1" else {
            let ids = (try? await model.playlist(playlist.id)?.entry?.map(\.id)) ?? []
            await send(key(36, "\r", window), window)
            check(await wait { model.player.current?.id == ids[1] }, "Return plays the playlist from the clicked row")
            await commandA(window)
            await send(key(36, "\r", window), window)
            check(await wait { model.player.queue.map(\.id) == ids && model.player.current?.id == ids.first }, "⌘A, Return plays all rows: queue \(model.player.queue.count) of \(ids.count), at \(model.player.current.flatMap { ids.firstIndex(of: $0.id) } ?? -1)")
            model.player.next()
            await send(key(53, "\u{1b}", window), window)
            await send(key(36, "\r", window), window)
            try? await Task.sleep(for: .seconds(2))
            check(model.player.current?.id == ids[1], "Escape clears: Return then plays nothing \(model.player.current.flatMap { ids.firstIndex(of: $0.id) } ?? -1)")
            if model.player.isPlaying { model.player.toggle() }
            return
        }
        // The count the server has now; earlier runs changed the stub playlist.
        let count = { model.playlists.first { $0.id == playlist.id }?.songCount }
        guard let before = (try? await model.playlist(playlist.id))?.entry?.count else { return check(false, "playlist entries") }
        await send(key(51, "\u{7f}", window), window)
        check(await wait { count() == before - 1 }, "Delete removes the clicked row from \(playlist.name) (\(before))")
        await tap(window, row: 1, top: 414, height: 54)
        let edit = menuAction(#selector(NSText.delete(_:)), window)
        let removed = await wait { count() == before - 2 }
        check(edit && removed, "Edit > Delete removes the clicked row")
        guard !pushed, let artist = (try? await model.playlist(playlist.id))?.entry?.compactMap(\.artistId).first else { return }
        // A page without a song list pushed over the playlist: the commands must not reach the hidden rows.
        await tap(window, row: 1, top: 414, height: 54)
        model.show(.artist(artist))
        try? await Task.sleep(for: .seconds(2))
        await send(key(51, "\u{7f}", window), window)
        _ = menuAction(#selector(NSText.delete(_:)), window)
        await commandA(window)
        try? await Task.sleep(for: .seconds(2))
        let entries = { (try? await model.playlist(playlist.id))?.entry?.count }
        check(await entries() == before - 2, "Delete, Edit > Delete and ⌘A on a pushed artist page leave the playlist")
        model.path = []
        try? await Task.sleep(for: .seconds(2))
        await send(key(51, "\u{7f}", window), window)
        check(await wait { count() == before - 3 }, "back on the playlist, Delete removes only the clicked row")
    }

    // MARK: Now Playing

    /// Synced lyrics at line 30 of 60: right after Now Playing opens, that line is on screen, without waiting for the next line.
    private static func nowPlayingLyrics(_ model: AppModel) async {
        await Shot.playPaused(model)
        guard case .server(let song)? = model.player.current, let window = mainWindow, let content = window.contentView else { return check(false, "a song") }
        let json = #"{"synced":true,"line":["# + (0..<60).map { #"{"start":\#($0 * 5000),"value":"Line \#($0)"}"# }.joined(separator: ",") + "]}"
        model.lyricsCache[song.id] = (try? JSONDecoder().decode(StructuredLyrics.self, from: Data(json.utf8))).flatMap(Lyrics.init)
        model.player.seek(to: 151)
        _ = await wait { abs(model.player.elapsed - 151) < 1 }
        model.nowPlayingPanel = .lyrics
        model.showNowPlaying = true
        try? await Task.sleep(for: .seconds(1.5))  // the slide and the lyrics fade; the next line is at 155 s
        // The lyrics stack: 220 pt above and below 60 lines of height h with 26 pt between them.
        let lineHeight = { (scroll: NSScrollView) in ((scroll.documentView?.frame.height ?? 0) - 440 - 59 * 26) / 60 }
        guard let scroll = views(content, of: NSScrollView.self).first(where: { (30...50).contains(lineHeight($0)) }) else { return check(false, "lyrics scroll view") }
        let h = lineHeight(scroll), viewport = scroll.contentView.bounds.height
        // `scrollTo` with anchor 0.35 puts that point of line 30 at that point of the viewport.
        let expected = 220 + 30 * (h + 26) + 0.35 * h - 0.35 * viewport
        let offset = scroll.contentView.bounds.minY
        check(model.player.elapsed < 154 && abs(offset - expected) < 4, "the lyrics open on line 30 at once: offset \(offset), expected \(expected)")
    }

    /// A drag on the volume slider in the title bar area changes the volume and leaves the window in place.
    private static func nowPlayingDrag(_ model: AppModel) async {
        await Shot.playPaused(model)
        model.showNowPlaying = true
        try? await Task.sleep(for: .seconds(1))
        guard let window = mainWindow, let content = window.contentView else { return check(false, "main window") }
        let bars = views(content, of: BarMouseArea.AreaView.self)
        check(!bars.isEmpty && bars.allSatisfy { !$0.mouseDownCanMoveWindow }, "\(bars.count) bars do not move the window")
        guard let volume = bars.first(where: { abs($0.bounds.width - 120) < 1 }), let frameView = content.superview else { return check(false, "volume slider") }
        check(frameView.hitTest(frameView.convert(NSPoint(x: volume.bounds.midX, y: volume.bounds.midY), from: volume)) === volume, "the volume slider gets its clicks")
        let before = window.frame
        model.player.volume = 0.2
        let y = volume.bounds.midY
        for (type, x) in [(NSEvent.EventType.leftMouseDragged, 0.5), (.leftMouseDragged, 0.8), (.leftMouseUp, 0.8)] {
            mouse(type, volume.convert(NSPoint(x: volume.bounds.width * x, y: y), to: nil), window).map { NSApp.postEvent($0, atStart: false) }
        }
        mouse(.leftMouseDown, volume.convert(NSPoint(x: volume.bounds.width * 0.2, y: y), to: nil), window).map(window.sendEvent)
        check(await wait { abs(model.player.volume - 0.8) < 0.02 }, "the drag sets the volume: \(model.player.volume)")
        check(window.frame == before, "the window stays: \(before) → \(window.frame)")
    }

    private static func views<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, of: type) }
    }

    // MARK: Windows

    private static func miniPlayer(_ model: AppModel) async {
        await Shot.playPaused(model)
        UserDefaults.app.set(false, forKey: MiniPlayer.queueKey)
        UserDefaults.app.set(false, forKey: MiniPlayer.onTopKey)
        guard let main = mainWindow, main.isVisible else { return check(false, "main window") }
        check(windowMenu("Switch to MiniPlayer"), "Window > Switch to MiniPlayer")
        let found = await Shot.first { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MiniPlayer.id) == true && $0.isVisible } }
        guard let mini = found else { return check(false, "MiniPlayer opens") }
        check(!main.isVisible, "the main window hides")
        try? await Task.sleep(for: .milliseconds(500))
        for level in [NSWindow.Level.floating, .normal] {
            let item = windowMenu("Keep MiniPlayer on Top")
            let ok = await wait { mini.level == level }
            check(item && ok, "Keep on Top: level \(mini.level.rawValue)")
        }
        let songs = model.player.queue
        if !songs.isEmpty {
            model.player.play(Array(repeating: songs, count: 300 / songs.count + 1).flatMap { $0 })  // a long queue
            if model.player.isPlaying { model.player.toggle() }
        }
        // The default size, again, after a resize with Up Next open, and after a resize without it.
        for width in [nil, 400, 260] as [CGFloat?] {
            if let width { mini.setFrame(NSRect(x: mini.frame.minX, y: mini.frame.maxY - width, width: width, height: width), display: true) }
            try? await Task.sleep(for: .milliseconds(300))
            let before = mini.frame, content = mini.contentView?.frame.height ?? 0
            let shown = await upNext(mini, open: true)
            check(shown < 0.25, "Up Next shows \(model.player.queue.count) songs in \(Int(shown * 1000)) ms")
            check(await wait { abs(mini.frame.height - (before.height + MiniPlayer.queueHeight)) < 1 && abs(mini.frame.maxY - before.maxY) < 1 },
                  "Up Next adds \(MiniPlayer.queueHeight) pt below, the top stays: \(before) → \(mini.frame)")
            if width == 400 {  // the user makes the window narrower with Up Next open
                mini.setFrame(NSRect(x: mini.frame.minX, y: mini.frame.minY + 60, width: 340, height: mini.frame.height - 60), display: true)
                try? await Task.sleep(for: .milliseconds(300))
            }
            let wide = mini.frame.width
            let hidden = await upNext(mini, open: false)
            check(hidden < 0.1, "Up Next hides in \(Int(hidden * 1000)) ms")
            check(await wait { abs(mini.frame.height - wide) < 1 && abs((mini.contentView?.frame.height ?? 0) - wide) < 1 && abs(mini.frame.maxY - before.maxY) < 1 },
                  "Up Next again: the window is square, \(content) pt high before, content \(mini.contentView?.frame.height ?? 0) in \(mini.frame)")
        }
        mini.performClose(nil)
        check(await wait { !mini.isVisible && main.isVisible }, "closing the MiniPlayer shows the main window")
    }

    /// Turns Up Next on or off as its button does (the controls show only under the mouse); returns the seconds
    /// until the Up Next list is in the window or gone; the window grows or shrinks after that.
    private static func upNext(_ mini: NSWindow, open: Bool) async -> TimeInterval {
        let start = Date()
        UserDefaults.app.set(open, forKey: MiniPlayer.queueKey)
        for _ in 0..<1000 where (Shot.tableView(in: mini.contentView)?.numberOfRows ?? 0 > 0) != open {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return Date().timeIntervalSince(start)
    }

    private static func equalizer(_ model: AppModel) async {
        let player = model.player
        player.equalizer = EqualizerSettings()
        check(windowMenu("Equalizer"), "Window > Equalizer")
        guard let window = await Shot.first({ NSApp.windows.first { $0.title == "Equalizer" && $0.isVisible } }) else { return check(false, "Equalizer opens") }
        try? await Task.sleep(for: .milliseconds(500))
        // The preset menu: the focusable view at the top right.
        guard let content = window.contentView, let preset = EqualizerPreset.builtIn.first(where: { $0.name == "Rock" }),
              let button = content.subviews.first(where: { $0.frame.minX > content.bounds.midX && $0.frame.height >= 20 }) else { return check(false, "preset menu") }
        let menu = await popUp { await click(button, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY)) }
        check(titles(menu).dropFirst().starts(with: EqualizerPreset.builtIn.map(\.name)), "preset menu: \(titles(menu))")
        perform(preset.name, in: menu)
        check(await wait { player.equalizer.preset == preset.name && player.equalizer.gains == EqualizerGains(preamp: 0, bands: preset.bands) && player.mixer.usesEqualizer },
              "preset Rock turns the equalizer on with its gains: \(player.equalizer.preset ?? "Manual") \(player.equalizer.gains)")
    }

    // MARK: Artists

    /// The 280 pt artist list starts right of the sidebar and keeps its width once the artist page loads.
    private static func artists(_ model: AppModel) async {
        await Shot.select(.artists, model)
        try? await Task.sleep(for: .seconds(4))  // the list and the first artist page load
        guard let window = mainWindow, let content = window.contentView else { return check(false, "main window") }
        // A scroll view under the glass sidebar spans it too; its left inset is the part that the sidebar covers.
        let frames = scrollViews(in: content).map { view in
            let frame = view.convert(view.bounds, to: nil)
            return NSRect(x: frame.minX + view.contentInsets.left, y: frame.minY, width: frame.width - view.contentInsets.left, height: frame.height)
        }
        guard let sidebar = frames.first(where: { $0.minX < 1 }),
              let list = frames.first(where: { abs($0.width - 280) < 1 }) else { return check(false, "sidebar and artist list: \(frames)") }
        check(list.minX >= sidebar.maxX - 1, "the artist list \(list) starts right of the sidebar \(sidebar)")
    }

    // MARK: Accessibility

    /// What VoiceOver reads on Home, an album, Now Playing and the MiniPlayer, and the player keys.
    private static func accessibility(_ model: AppModel) async {
        guard AccessibilityAudit.isTrusted else { return check(false, "the terminal has the Accessibility permission (System Settings > Privacy)") }
        await Shot.playPaused(model)
        UserDefaults.app.set(false, forKey: MiniPlayer.queueKey)
        guard let window = mainWindow else { return check(false, "main window") }
        let player = model.player
        let on = { (isOn: Bool) in isOn ? "On" : "Off" }
        try? await Task.sleep(for: .seconds(4))

        let home = audit("Home", window: window.title)
        check(home.filter { $0.role == "AXButton" && $0.label.contains(", ") }.count >= 5, "Home cards read \"Album, Artist\"")
        toggles(["Shuffle": on(player.shuffle), "Repeat": player.repeatMode.rawValue.capitalized], in: home)
        slider("Position", in: home)

        await albumRows(model, window)
        await playerKeys(model, window)
        await songsTable(model, window)

        model.nowPlayingPanel = .queue
        model.showNowPlaying = true
        try? await Task.sleep(for: .seconds(1.5))
        let playing = audit("Now Playing", window: window.title)
        let starred = { if case .server(let song)? = player.current { model.isStarred(song) } else { false } }
        toggles(["Favorite": on(starred()), "Lyrics": "Off", "Queue": "On", "Shuffle": on(player.shuffle)], in: playing)
        if model.mixes.isAvailable { toggles(["AutoPlay": on(model.mixes.autoPlay)], in: playing) }
        check(!playing.contains { $0.label == "Hide Sidebar" || $0.label == "Open Now Playing" }, "the page under Now Playing is hidden from VoiceOver")
        if let volume = slider("Volume", in: playing) {
            player.volume = 0.5
            AXUIElementPerformAction(volume.element, "AXIncrement" as CFString)
            check(await wait { abs(player.volume - 0.6) < 0.01 }, "VoiceOver increment on Volume: \(player.volume)")
        }
        slider("Position", in: playing)
        key(53, "\u{1b}", window).map { if !window.performKeyEquivalent(with: $0) { window.sendEvent($0) } }
        check(await wait { !model.showNowPlaying }, "Escape closes Now Playing")

        check(windowMenu("Switch to MiniPlayer"), "Window > Switch to MiniPlayer")
        guard let mini = await Shot.first({ NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MiniPlayer.id) == true && $0.isVisible } }) else { return check(false, "MiniPlayer opens") }
        try? await Task.sleep(for: .seconds(1))  // its controls show for a moment at first
        let small = audit("MiniPlayer", window: mini.title)
        toggles(["Favorite": on(starred()), "Up Next": "Off", "Shuffle": on(player.shuffle)], in: small)
        slider("Position", in: small)
        mini.performClose(nil)
        _ = await wait { window.isVisible }
    }

    /// Album rows read title and time; ↓ and ↑ move the selection, Return plays it.
    private static func albumRows(_ model: AppModel, _ window: NSWindow) async {
        guard let album = await Shot.first({ model.albums.first { ($0.songCount ?? 0) > 3 } }),
              let songs = try? await model.album(album.id)?.song else { return check(false, "an album") }
        model.show(.album(album))
        try? await Task.sleep(for: .seconds(3))
        let nodes = audit("Album", window: window.title)
        let song = songs[1]
        let time = song.duration.map { spokenTime(TimeInterval($0)) } ?? ""
        check(nodes.contains { $0.label.hasPrefix(song.title + ", ") && $0.label.hasSuffix(time) }, "a song row reads \"\(song.title), …, \(time)\"")
        await tap(window, row: 1, top: 393, height: 42)
        for (code, arrow) in [(125, NSDownArrowFunctionKey), (125, NSDownArrowFunctionKey), (126, NSUpArrowFunctionKey)] {
            await send(key(UInt16(code), arrowKey(arrow), window), window)
        }
        await send(key(36, "\r", window), window)
        check(await wait { model.player.current?.id == songs[2].id }, "↓ ↓ ↑ from row 1, then Return plays row 2: \(model.player.current.flatMap { c in songs.firstIndex { $0.id == c.id } } ?? -1)")
        if model.player.isPlaying { model.player.toggle() }
        model.path = []
    }

    /// The Songs table (AppKit): its cells and buttons have names too.
    private static func songsTable(_ model: AppModel, _ window: NSWindow) async {
        await Shot.mirrored(model)
        await Shot.select(.songs, model)
        guard await songs() != nil else { return }
        audit("Songs", window: window.title)
        await Shot.select(.home, model)
    }

    /// ⌘→, ⌘←, ⌘↑ and ⌘↓ in the Playback menu, and Space.
    private static func playerKeys(_ model: AppModel, _ window: NSWindow) async {
        let player = model.player
        let menu = NSApp.mainMenu?.item(withTitle: "Playback")?.submenu
        let arrows = ["Next": NSRightArrowFunctionKey, "Previous": NSLeftArrowFunctionKey, "Increase Volume": NSUpArrowFunctionKey, "Decrease Volume": NSDownArrowFunctionKey]
        for (title, arrow) in arrows.sorted(by: { $0.key < $1.key }) {
            let item = menu?.item(withTitle: title)
            check(item?.keyEquivalent == arrowKey(arrow) && item?.keyEquivalentModifierMask == .command, "Playback > \(title) is ⌘ and an arrow")
        }
        player.volume = 0.5
        for (title, expected) in [("Increase Volume", 0.6), ("Decrease Volume", 0.5)] {
            if let menu, let i = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: i) }
            check(await wait { abs(player.volume - expected) < 0.01 }, "\(title): \(player.volume)")
        }
        // Through the app's event monitor, as a typed key goes.
        let wasPlaying = player.isPlaying
        key(49, " ", window).map(NSApp.sendEvent)
        check(await wait { player.isPlaying != wasPlaying }, "Space toggles playback")
        if player.isPlaying { player.toggle() }
    }

    private static func arrowKey(_ code: Int) -> String { String(Character(UnicodeScalar(UInt16(code)) ?? " ")) }

    /// Every control has a label; returns the tree of the window titled `window`.
    @discardableResult private static func audit(_ name: String, window: String) -> [AccessibilityAudit.Node] {
        let nodes = AccessibilityAudit.nodes().filter { $0.window == window }
        let missing = AccessibilityAudit.unlabeled(nodes)
        check(nodes.count > 20 && missing.isEmpty, "\(name): \(nodes.count) elements, controls without a label: \(missing.map { "\($0.role)/\($0.subrole)" })")
        return nodes
    }

    /// The buttons with these labels read these values.
    private static func toggles(_ values: [String: String], in nodes: [AccessibilityAudit.Node]) {
        for (label, value) in values.sorted(by: { $0.key < $1.key }) {
            let found = nodes.filter { $0.label == label && $0.role == "AXButton" }.map(\.value)
            check(!found.isEmpty && found.allSatisfy { $0 == value }, "\(label) reads \(value): \(found)")
        }
    }

    /// The slider labeled `label`: VoiceOver can move it and reads its value in words.
    @discardableResult private static func slider(_ label: String, in nodes: [AccessibilityAudit.Node]) -> AccessibilityAudit.Node? {
        let found = nodes.first { $0.role == "AXSlider" && $0.label == label }
        let words = found?.value.map { label == "Volume" ? $0.hasSuffix("%") : $0.contains(" of ") } ?? false
        check(found.map { $0.actions.contains("AXIncrement") && $0.actions.contains("AXDecrement") } == true && words,
              "\(label) is an adjustable slider: \(found?.value ?? "none") \(found?.actions ?? [])")
        return found
    }

    // MARK: Helpers

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    static var mainWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true } }

    /// Needs `scripts/big-server.py`, fresh: its episode st-0-1 (21 min) has a bookmark at 7:00.
    private static func podcastResume(_ model: AppModel) async {
        guard model.config?.baseURL.host == "127.0.0.1" else { return check(false, "podcast-resume needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        let podcasts = model.podcasts, player = model.player
        check(await wait { podcasts.isVisible && model.bookmarks.supported }, "podcasts and bookmarks load")
        guard let channel = podcasts.channels.first(where: { $0.id == "ch-0" }), let full = try? await podcasts.channel(channel.id),
              let episode = full.episodes.first(where: { $0.song?.id == "st-0-1" }) else { return check(false, "stub episode st-0-1") }
        await Shot.select(.podcasts, model)
        model.show(.podcast(channel))
        let shown = podcasts.progress(episode) ?? 0
        check(abs(shown - 420.0 / 1260) < 0.01, "the row shows the bookmark: \(shown)")
        podcasts.play(episode, in: full.episodes)
        try? await Task.sleep(for: .seconds(4))
        check(await wait { player.isPlaying && player.elapsed > 419 && player.elapsed < 440 }, "plays on from the bookmark at 7:00: \(player.elapsed)")
        player.seek(to: 500)
        _ = await wait { abs(player.elapsed - 500) < 2 }
        model.bookmarks.saveNow()  // as on quit: the server has it when this returns
        let quit = try? await model.client?.getBookmarks().first { $0.entry.id == "st-0-1" }?.position
        check(quit.map { abs($0 - 500_000) < 3000 } == true, "quitting saves the position: \(String(describing: quit))")
        player.seek(to: 600)
        try? await Task.sleep(for: .seconds(2))
        player.toggle()
        let kept = { model.bookmarks.positions["st-0-1"].map { abs($0 - 600_000) < 5000 } == true }
        check(await wait(kept), "pause keeps the position: \(String(describing: model.bookmarks.positions["st-0-1"]))")
        try? await Task.sleep(for: .seconds(1))
        let saved = try? await model.client?.getBookmarks().first { $0.entry.id == "st-0-1" }?.position
        check(saved.map { abs($0 - 600_000) < 5000 } == true, "the server has it: \(String(describing: saved))")
        podcasts.markPlayed(episode)
        try? await Task.sleep(for: .seconds(1))
        let left = try? await model.client?.getBookmarks().contains { $0.entry.id == "st-0-1" }
        check(left == false && podcasts.progress(episode) == nil, "Mark as Played drops the bookmark")
    }

    // MARK: Shortcuts

    /// Runs the Shortcuts actions through `perform()`, as Shortcuts does. Adding to a playlist needs the stub server.
    private static func intents(_ model: AppModel) async {
        let player = model.player
        func failure<I: AppIntent>(_ intent: I) async -> Error? {
            do { _ = try await intent.perform(); player.pause(); return nil } catch { return error }
        }
        func run<I: AppIntent>(_ intent: I, _ what: String) async -> Error? {
            let error = await failure(intent)
            if let error { check(false, "\(what): \(error)") }
            return error
        }
        guard let album = await Shot.first({ model.albums.first { ($0.songCount ?? 0) > 1 } }),
              let songs = try? await model.album(album.id)?.song else { return check(false, "an album") }

        let albums = try? await AlbumQuery().entities(matching: album.name.uppercased())
        check(albums?.contains { $0.id == album.id } == true, "the album query finds \(album.name)")
        let playAlbum = PlayAlbumIntent()
        playAlbum.album = AlbumEntity(id: album.id, name: album.name, artist: album.artistName)
        playAlbum.shuffle = false
        if await run(playAlbum, "Play Album") == nil {
            check(player.queue.map(\.id) == songs.map(\.id) && !player.shuffle, "Play Album plays \(album.name) in order")
        }
        let current = try? await GetCurrentSongIntent().perform().value
        check(current?.id == player.current?.id && current?.title == songs.first?.title, "Get Current Song gives \(current?.title ?? "nothing")")

        if let id = album.artistId, let artist = try? await ArtistQuery().entities(for: [id]).first {
            let playArtist = PlayArtistIntent()
            playArtist.artist = artist
            playArtist.shuffle = true
            if await run(playArtist, "Play Artist") == nil { check(player.shuffle && !player.queue.isEmpty, "Play Artist shuffles \(artist.name)") }
        } else { check(false, "the artist query finds the album artist") }

        if let playlist = try? await PlaylistQuery().suggestedEntities().first, let entries = try? await model.playlist(playlist.id)?.entry {
            let playPlaylist = PlayPlaylistIntent()
            playPlaylist.playlist = playlist
            playPlaylist.shuffle = false
            if await run(playPlaylist, "Play Playlist") == nil { check(player.queue.map(\.id) == entries.map(\.id), "Play Playlist plays \(playlist.name)") }
        }

        let title = songs[1].title
        let found = try? await SongQuery().entities(matching: title)
        check(found?.contains { $0.id == songs[1].id } == true, "the song query finds \(title)")
        let playMusic = PlayMusicIntent()
        playMusic.text = title
        if await run(playMusic, "Play \(title)") == nil {
            check(player.queue.contains { [$0.title, $0.album, $0.artist].contains(title) }, "Play \(title) plays its best match")
        }
        playMusic.text = "zzqx no such music"
        let none = await failure(playMusic)
        check(none.map { if case IntentError.notFound = $0 { true } else { false } } == true, "Play fails for text that matches nothing: \(String(describing: none))")

        if await run(ShuffleLibraryIntent(), "Shuffle Library") == nil { check(player.shuffle && player.queue.count > 1, "Shuffle Library: \(player.queue.count) songs") }
        _ = await run(ToggleShuffleIntent(), "Toggle Shuffle")
        check(!player.shuffle, "Toggle Shuffle turns shuffle off")
        let setRepeat = SetRepeatIntent()
        setRepeat.mode = .one
        _ = await run(setRepeat, "Set Repeat")
        check(player.repeatMode == .one, "Set Repeat to One")
        player.repeatMode = .off
        let setVolume = SetVolumeIntent()
        setVolume.level = 30
        _ = await run(setVolume, "Set Volume")
        check(abs(player.volume - 0.3) < 0.001, "Set Volume to 30%: \(player.volume)")
        player.volume = 0

        let before = player.queue.map(\.id)
        if let error = await failure(StartStationIntent()) {
            check(!model.mixes.isAvailable && error is IntentError, "Start Station needs the local library: \(error)")
        } else {
            check(await wait { player.queue.map(\.id) != before }, "Start Station plays a station: \(player.queue.count) songs")
            player.pause()
        }

        if model.config?.baseURL.host == "127.0.0.1", let playlist = model.editablePlaylists.first(where: { $0.songCount == 50 }), let song = model.system.currentSong {
            let before = (try? await model.playlist(playlist.id)?.entry?.count) ?? 0
            let add = AddCurrentSongToPlaylistIntent()
            add.playlist = PlaylistEntity(id: playlist.id, name: playlist.name)
            _ = await run(add, "Add Current Song to Playlist")
            let entries = try? await model.playlist(playlist.id)?.entry
            check(entries?.count == before + 1 && entries?.last?.id == song.id, "Add Current Song to Playlist adds \(song.title) to \(playlist.name)")
        }

        IntentHost.system = nil
        let refused = await failure(playAlbum)
        check(refused.map { if case IntentError.notConnected = $0 { true } else { false } } == true, "Play Album fails without a server: \(String(describing: refused))")
        IntentHost.system = model.system
        player.pause()
    }

    static func wait(_ condition: () -> Bool) async -> Bool { await Shot.first { condition() ? true : nil } ?? false }

    private static func titles(_ menu: NSMenu?) -> [String] { menu?.items.map(\.title).filter { !$0.isEmpty } ?? [] }

    private static func perform(_ title: String, in menu: NSMenu?) {
        guard let menu, let i = menu.items.firstIndex(where: { $0.title == title }) else { return check(false, "menu item \(title)") }
        menu.performActionForItem(at: i)
    }

    /// Runs the item of the Window menu.
    private static func windowMenu(_ title: String) -> Bool {
        guard let menu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu, let i = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: i)
        return true
    }

    /// ⌘A as the menu bar handles it: the Edit menu item's action, up the responder chain of the window.
    private static func selectAll(_ window: NSWindow) -> Bool {
        let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == "a" && $0.keyEquivalentModifierMask == .command }
        return item?.action.map { menuAction($0, window) } ?? false
    }

    /// ⌘A in the order of `NSApplication.sendEvent`: the window's key equivalents, the Edit menu item when a
    /// responder takes its action, else a key down for the first responder.
    private static func commandA(_ window: NSWindow) async {
        guard let event = key(0, "a", window, .command) else { return }
        let taken = window.performKeyEquivalent(with: event) || selectAll(window)
        if !taken { window.sendEvent(event) }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// A menu action as `NSApp.sendAction(_:to: nil)` sends it in a key window: up the responder chain,
    /// where SwiftUI hosting views answer through `supplementalTarget`.
    private static func menuAction(_ action: Selector, _ window: NSWindow) -> Bool {
        var responder = window.firstResponder
        while let r = responder {
            if let target = r.responds(to: action) ? r : r.supplementalTarget(forAction: action, sender: nil) as? NSObject {
                return NSApp.sendAction(action, to: target, from: nil)
            }
            responder = r.nextResponder
        }
        return false
    }

    /// Runs `open`, which pops up a menu, and closes the menu again; returns it.
    private static func popUp(_ open: () async -> Void) async -> NSMenu? {
        tracked = nil
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu  // posted on the main thread
            MainActor.assumeIsolated { tracked = menu }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { tracked?.cancelTracking() } }
        RunLoop.main.add(timer, forMode: .eventTracking)
        await open()
        for _ in 0..<20 where tracked == nil { try? await Task.sleep(for: .milliseconds(100)) }
        timer.invalidate()
        NotificationCenter.default.removeObserver(observer)
        return tracked
    }

    /// The first responder is a SwiftUI view, not the window.
    private static func responder(_ window: NSWindow) -> Bool { window.firstResponder is NSView }

    /// A key down as the window hands it over, then a pause as a person makes: SwiftUI reads the new state on the next update.
    private static func send(_ event: NSEvent?, _ window: NSWindow) async {
        event.map(window.sendEvent)
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Clicks a SwiftUI list row: `top` is the first row's y from the top of the window content.
    private static func tap(_ window: NSWindow, row: Int, top: Double, height: Double) async {
        guard let content = window.contentView else { return }
        let y = top + Double(row) * height
        await click(content, at: NSPoint(x: 700, y: content.isFlipped ? y : content.bounds.height - y))
    }

    /// A click as the window hands it over; the table selects and double-clicks through its gesture recognizers.
    private static func click(_ view: NSView, at point: NSPoint, count: Int = 1) async {
        guard let window = view.window else { return }
        let location = view.convert(point, to: nil)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                mouse(type, location, window, clicks: n).map(window.sendEvent)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// A click on a view that tracks the mouse itself (the table header): the mouse-up waits in the queue for its loop.
    private static func track(_ view: NSView, at point: NSPoint) {
        guard let window = view.window, let down = mouse(.leftMouseDown, view.convert(point, to: nil), window),
              let up = mouse(.leftMouseUp, view.convert(point, to: nil), window) else { return }
        NSApp.postEvent(up, atStart: true)
        view.mouseDown(with: down)
    }

    private static func mouse(_ type: NSEvent.EventType, _ location: NSPoint, _ window: NSWindow, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    private static func key(_ code: UInt16, _ characters: String, _ window: NSWindow, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
}
