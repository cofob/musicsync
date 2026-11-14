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
        default: check(false, "known check \(name)")
        }
    }

    private static func check(_ ok: Bool, _ what: String) {
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
    private static func songs() async -> (SongsTable.Table, SongsTable.Coordinator)? {
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
        let before = mini.frame
        await upNext(mini)
        check(await wait { abs(mini.frame.height - (before.height + MiniPlayer.queueHeight)) < 1 && abs(mini.frame.maxY - before.maxY) < 1 },
              "Up Next adds \(MiniPlayer.queueHeight) pt below, the top stays: \(before) → \(mini.frame)")
        await upNext(mini)
        check(await wait { abs(mini.frame.height - before.height) < 1 && abs(mini.frame.maxY - before.maxY) < 1 },
              "Up Next again: back to \(before.height) pt, the top stays: \(mini.frame)")
        mini.performClose(nil)
        check(await wait { !mini.isVisible && main.isVisible }, "closing the MiniPlayer shows the main window")
    }

    /// Clicks Up Next, the last button at the bottom right of the cover; the controls show for 4 s after opening.
    private static func upNext(_ mini: NSWindow) async {
        guard let content = mini.contentView else { return }
        let y = mini.frame.width - 24  // the cover is square, Up Next goes below it
        await click(content, at: NSPoint(x: content.bounds.width - 26, y: content.isFlipped ? y : content.bounds.height - y))
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

    // MARK: Helpers

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true } }

    private static func wait(_ condition: () -> Bool) async -> Bool { await Shot.first { condition() ? true : nil } ?? false }

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
