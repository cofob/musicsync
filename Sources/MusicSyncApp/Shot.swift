import AppKit
import Carbon.HIToolbox
import Integration
import Library
import Playback
import Preferences
import Recommend
import Subsonic
import SwiftUI

/// Development only: `MUSICSYNC_SHOT=<png>` opens `MUSICSYNC_SCENE`, waits `MUSICSYNC_SHOT_DELAY` seconds (default 6),
/// saves a PNG of the front app window and quits. Run it through `scripts/shot.sh`.
@MainActor enum Shot {
    private static let env = ProcessInfo.processInfo.environment
    static let output = env["MUSICSYNC_SHOT"]
    /// A window that is not part of the scene graph (Settings); kept alive until the capture.
    private static var extraWindow: NSWindow?
    /// Titles of a menu bar menu and its submenus to open before the capture, e.g. ["Playback", "Sleep Timer"].
    private static var menuPath: [String] = []

    static func start(_ model: AppModel) {
        guard let output else { return }
        Task {
            let delay = Double(env["MUSICSYNC_SHOT_DELAY"] ?? "") ?? 6
            try? await Task.sleep(for: .seconds(1))  // the main window opens
            NSApp.windows.first?.setContentSize(NSSize(width: 1280, height: 820))
            await show(env["MUSICSYNC_SCENE"] ?? "home", model)
            try? await Task.sleep(for: .seconds(delay))
            let capture: @MainActor @Sendable () -> Void = { exit(save(to: URL(fileURLWithPath: output)) ? 0 : 1) }
            if menuPath.isEmpty { capture() } else { openMenu(then: capture) }
        }
    }

    /// Opens a scene. Add new scenes here.
    private static func show(_ scene: String, _ model: AppModel) async {
        switch scene {
        case "home": model.selection = .home
        case "albums": model.selection = .albums
        case "artists": model.selection = .artists
        case "songs": model.selection = .songs
        case "playlists": model.selection = .playlists
        case "album":
            await select(.albums, model)
            if let album = await first({ model.albums.first }) { model.show(.album(album)) }
        case "artist":
            await select(.artists, model)
            if let artist = await first({ model.artists.first }) { model.show(.artist(artist.id)) }
        case "nowplaying":
            await playPaused(model)
            model.showNowPlaying = true
        case "settings": open(SettingsView(), "Settings", model)
        case let s where s.hasPrefix("settings:"):
            // `settings:<page>`, or `settings:?<query>` for the search.
            let name = String(s.dropFirst(9))
            if name.hasPrefix("?") {
                open(SettingsView(query: String(name.dropFirst())), "Settings", model)
            } else {
                open(SettingsView(page: SettingsPage(rawValue: name) ?? .general), "Settings", model)
            }
        case let s where s.hasPrefix("page:"):
            // A settings page alone at its full height, to see its lower sections.
            open(SettingsView.content(SettingsPage(rawValue: String(s.dropFirst(5))) ?? .general), "Settings", model)
        case let s where s.hasPrefix("look:"):
            // `look:<accent>:<density>:<scene>`, e.g. `look:pink:large:albums`; the saved settings stay unchanged.
            let parts = s.split(separator: ":").map(String.init)
            guard parts.count == 4 else { break }
            AppPreferences.shared.appearance.accent = .init(rawValue: parts[1]) ?? .red
            AppPreferences.shared.appearance.density = .init(rawValue: parts[2]) ?? .medium
            AppearanceSettings().save()
            await show(parts[3], model)
        case "sync-checking":
            model.sync.checked = (40, 120)
            open(SyncSheet(), "Sync", model)
        case "menubar":
            await playPaused(model)
            open(MenuBarPlayer(), "Menu Bar", model)
        case "menubar-empty": open(MenuBarPlayer(), "Menu Bar", model)
        case "playlist":
            let editable = { model.editablePlaylists.first { ($0.songCount ?? 0) > 2 } }
            if let playlist = await first(editable) { await select(.playlist(playlist.id), model) }
        case "newplaylist":
            await select(.playlists, model)
            model.playlistPrompt = .create(songIds: [])
        case let s where s.hasPrefix("favorites:"):
            UserDefaults.app.set(FavoritesView.Segment(rawValue: String(s.dropFirst(10)).capitalized)?.rawValue, forKey: FavoritesView.segmentKey)
            model.selection = .favorites
        case "info":
            guard let album = await first({ model.albums.first }), let song = try? await model.album(album.id)?.song?.first else { break }
            model.infoSong = song
        case "album-download":
            // Starts downloading the shortest album and shows its page.
            await select(.albums, model)
            guard let album = await shortestAlbum(model) else { break }
            model.download(album)
            model.show(.album(album))
        case "downloaded":
            await select(.albums, model)
            if let album = await shortestAlbum(model) {
                model.download(album)
                _ = await first({ model.downloads.state(of: .album(album.id)) == .done ? true : nil })
            }
            await select(.downloaded, model)
        case "settings-downloads": open(DownloadSettingsView(), "Downloads", model)
        case "smart-downloading", "downloaded-smart", "downloaded-smart-all":
            await smartFavorites(model)
            let smart = model.smartDownloads
            if scene == "smart-downloading" {
                model.downloads.settings.smart.favorites.budgetGB = 0.5  // more to download than the earlier scenes kept
                DownloadSettings().save()
                _ = await first({ smart.pending > 0 && model.downloads.entries.values.contains { $0.state == .done } ? true : nil })
            } else {
                for _ in 0..<3000 where smart.lastPlan?.songs.values.allSatisfy(\.isEmpty) ?? true || smart.pending > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            }
            UserDefaults.app.set((scene == "downloaded-smart" ? DownloadedView.Filter.smart : .all).rawValue, forKey: DownloadedView.filterKey)
            await select(.downloaded, model)
        case "settings-smart":
            await smartFavorites(model)
            _ = await first({ model.smartDownloads.lastPlan?.songs.values.contains { !$0.isEmpty } == true ? true : nil })
            open(Form { SmartDownloadSettings(); PlaybackCacheSettings() }.formStyle(.grouped).frame(width: 520, height: 900), "Smart Downloads", model)
        case "cache":
            // Plays (muted) until the song is in the cache, then pauses.
            guard let album = await first({ model.albums.first }) else { break }
            model.play(album)
            for _ in 0..<1200 where model.downloads.cache.files.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            model.player.pause()
            open(Form { PlaybackCacheSettings() }.formStyle(.grouped).frame(width: 520, height: 230), "Cache", model)
        case let s where s.hasPrefix("menu:"):
            await playPaused(model)
            menuPath = s.dropFirst(5).split(separator: "/").map(String.init)
        case "settings-playback":
            model.player.settings.transitions = .crossfade
            model.player.settings.soundCheck = .album
            model.player.settings.quality = .aac
            PlaybackSettings().save()  // the demo defaults stay unchanged
            _ = await first({ model.player.supportsTranscodeOffset ? true : nil })
            open(PlaybackSettingsView(), "Playback", model)
        case "settings-automix":
            model.player.settings.transitions = .autoMix
            PlaybackSettings().save()
            // Songs of three albums, paused: they mix, so AutoMix analyzes them in the background.
            var songs: [Song] = []
            for album in (await first({ model.albums.count > 2 ? model.albums : nil }) ?? []).prefix(3) {
                if let song = try? await model.album(album.id)?.song?.first { songs.append(song) }
            }
            model.player.play(songs)
            _ = await first({ model.player.current })
            model.player.toggle()
            open(PlaybackSettingsView(), "Playback", model)
        case "offline":
            await select(.albums, model)
            guard let album = await first({ model.albums.first }) else { break }
            model.downloads.isOffline = true
            model.show(.album(album))
        case "mixes":
            await seedHistory(model)
            model.selection = .home
        case "mix":
            await seedHistory(model)
            if let mix = await first({ model.mixes.mixes.first }) { model.show(.mix(mix.id)) }
        case "autoplay":
            await seedHistory(model)
            model.mixes.autoPlay = true
            guard let mix = await first({ model.mixes.mixes.first }) else { break }
            model.mixes.play(mix, startAt: mix.trackIds.count - 1)  // the last song: AutoPlay fills the queue
            _ = await first({ model.player.current })
            model.player.toggle()
            model.nowPlayingPanel = .queue
            model.showNowPlaying = true
        case let s where s.hasPrefix("search:"):
            await select(.search, model)
            model.searchText = String(s.dropFirst(7))
            model.search.submit(model.searchText)
        case "settings-general": open(GeneralSettingsView(), "General", model)
        case "settings-shortcuts", "settings-shortcuts-recording":
            model.system.hotKeys.enabled = true
            model.system.hotKeys.assign(KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P"), to: .playPause)
            model.system.hotKeys.assign(KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey), key: "→"), to: .next)
            open(ShortcutsSettingsView(recording: scene.hasSuffix("recording") ? .favorite : nil), "Shortcuts", model)
        case "settings-sharing": open(SharesSettingsView(), "Sharing", model)
        case "settings-remote", "settings-remote-off":
            if scene.hasSuffix("off") { model.remote.isEnabled = false } else { await remoteScene(model) }
            open(RemoteSettingsView(), "Remote", model)
        case "share-menu":
            guard let album = await first({ model.albums.first }), let song = try? await model.album(album.id)?.song?.first else { break }
            open(VStack(alignment: .leading) { SongMenuItems(song: song) }.buttonStyle(.borderless).padding(20).frame(width: 280), "Song Menu", model)
        case let s where s.hasPrefix("link:"):
            // Opens an item through its deep link, parsed back from the URL as the system would hand it over.
            guard let album = await first({ model.albums.first }), let song = try? await model.album(album.id)?.song?.first else { break }
            let links: [String: DeepLink] = ["album": .show(.album, id: album.id), "artist": .show(.artist, id: album.artistId ?? ""),
                                             "song": .show(.song, id: song.id), "search": .search(album.name)]
            await select(.home, model)
            links[String(s.dropFirst(5))].flatMap { DeepLink(url: $0.url) }.map(model.system.open)
        case let s where s.hasPrefix("artist:"):
            await mirrored(model)
            if let artist = model.artists.first(where: { $0.name == s.dropFirst(7) }) { model.show(.artist(artist.id)) }
        case let s where s.hasPrefix("album:"):
            await mirrored(model)
            if let album = model.albums.first(where: { $0.name == s.dropFirst(6) }) { model.show(.album(album)) }
        case "genres":
            await mirrored(model)
            model.selection = .genres
        case let s where s.hasPrefix("genre:"):
            await mirrored(model)
            model.show(.genre(String(s.dropFirst(6))))
        case "stats":
            await seedHistory(model)
            model.show(.stats)
        case "stats-server":
            // A fresh demo folder: no history, so the server's play counts are shown.
            await mirrored(model)
            model.show(.stats)
        case "radio", "radio-empty", "radio-playing", "radio-nowplaying":
            // The demo server has no stations and its user is no admin, so the scene brings its own.
            _ = await first({ model.radio.isLoaded ? true : nil })
            model.radio.stations = scene == "radio-empty" ? [] : [
                RadioStation(id: "1", name: "Groove Salad", streamUrl: "https://ice1.somafm.com/groovesalad-128-mp3", homePageUrl: "https://somafm.com"),
                RadioStation(id: "2", name: "Drone Zone", streamUrl: "https://ice1.somafm.com/dronezone-128-mp3", homePageUrl: "https://somafm.com"),
                RadioStation(id: "3", name: "Radio Paradise", streamUrl: "https://stream.radioparadise.com/aac-128"),
            ]
            model.radio.canEdit = true
            await select(.radio, model)
            if scene.hasSuffix("playing") {
                model.radio.play(model.radio.stations[0])
                try? await Task.sleep(for: .seconds(1))
                if model.player.isPlaying { model.player.toggle() }
                model.showNowPlaying = scene == "radio-nowplaying"
            }
        case "upnext", "queue-quit":
            // History, Playing Next and AutoPlay sections, paused; "queue-quit" then quits, so the queue is saved.
            await queueScene(model)
            if scene == "queue-quit" {
                _ = await first({ model.player.elapsed > 40 ? true : nil })
                NSApp.terminate(nil)
            }
            model.nowPlayingPanel = .queue
            model.showNowPlaying = true
        case "automix-label":
            // The queue during a mix; a real mix needs sound, so the flag is set.
            await queueScene(model)
            try? await Task.sleep(for: .seconds(2))  // the time update after the seek has come
            model.player.isMixing = true
            model.nowPlayingPanel = .queue
            model.showNowPlaying = true
        case "queue-restored":
            _ = await first({ model.player.current })
            model.nowPlayingPanel = .queue
            model.showNowPlaying = true
        case "queue-sync":
            // Plays muted and privately for a moment, so the queue is saved on the server.
            await queueScene(model)
            model.player.toggle()
            try? await Task.sleep(for: .seconds(4))
            model.player.toggle()
        case "resume":
            _ = await first({ model.serverQueue.offer })
            await select(.home, model)
        case "multiselect", "multiselect-menu":
            // Click, ⌘-click and ⇧-click on album rows: the first, third, fourth and fifth are selected.
            await select(.albums, model)
            guard let album = await first({ model.albums.first }) else { break }
            model.show(.album(album))
            if scene == "multiselect-menu", let songs = try? await model.album(album.id)?.song {
                open(VStack(alignment: .leading) { SongsMenuItems(songs: Array(songs.prefix(3))) }.buttonStyle(.borderless).padding(20).frame(width: 280), "Songs Menu", model)
                break
            }
            try? await Task.sleep(for: .seconds(3))
            for (row, flags) in [(0, NSEvent.ModifierFlags()), (2, .command), (4, .shift)] {
                click(CGPoint(x: 700, y: 393 + row * 42), flags)
                try? await Task.sleep(for: .milliseconds(700))  // no double-click
            }
        case "miniplayer", "miniplayer-queue":
            // Through the Window menu, as the user does; the main window hides.
            await playPaused(model)
            UserDefaults.app.set(scene.hasSuffix("queue"), forKey: MiniPlayer.queueKey)
            if let menu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu, let i = menu.items.firstIndex(where: { $0.title == "Switch to MiniPlayer" }) {
                menu.performActionForItem(at: i)
            }
        case "radio-editor":
            open(StationEditor(station: RadioStation(id: "1", name: "Groove Salad", streamUrl: "https://ice1.somafm.com/groovesalad-128-mp3")), "Station", model)
        default:
            print("Unknown scene: \(scene)")
            exit(2)
        }
    }

    /// Waits until the lists come from the local mirror, which takes a few minutes on the first run.
    private static func mirrored(_ model: AppModel) async {
        for _ in 0..<3000 where !model.usesLocalLibrary { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Demo only: a month of made-up listening (favorite albums, some skips), so the mixes have a history.
    /// Waits for the local mirror, which takes a few minutes on the first run.
    private static func seedHistory(_ model: AppModel) async {
        var library: Library?
        for _ in 0..<3000 where library == nil {
            library = model.usesLocalLibrary ? model.library : nil
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.demo, let library, await library.history.events(limit: 1).isEmpty else { return }
        let albums = await library.database.albums(sort: .name, limit: 12)
        var songs: [[Song]] = []
        for album in albums { songs.append(await library.database.album(id: album.id)?.song ?? []) }
        let now = Date()
        for day in 0..<30 {
            let start = now.addingTimeInterval(-Double(day) * 86400 - 3600)
            // Albums 0–5 are favorites, played in turn; albums 6–11 get skipped after a few seconds.
            let session = songs[day % 6].prefix(6) + songs[(day + 3) % 6].prefix(4) + songs[6 + day % 6].prefix(2)
            for (i, song) in session.enumerated() {
                let skipped = i >= 10
                let length = Double(song.duration ?? 200)
                try? await library.history.record(PlayEvent(songId: song.id, startedAt: start.addingTimeInterval(Double(i) * 240),
                                                             played: skipped ? 8 : length, duration: length, source: .album))
            }
        }
        await model.mixes.load(refresh: true)
    }

    /// Demo only: smart downloads of favorites and the most played songs as small mp3 files. Only the running app
    /// gets these settings; the saved ones stay unchanged. Waits for the local mirror.
    private static func smartFavorites(_ model: AppModel) async {
        var settings = model.downloads.settings
        settings.quality = .mp3
        settings.maxBitRate = 128
        settings.smart.favorites.isOn = true
        settings.smart.favorites.budgetGB = 0.1
        settings.smart.mostPlayed.isOn = true
        settings.smart.mostPlayed.budgetGB = 0.1
        settings.smart.mostPlayedCount = 25
        model.downloads.settings = settings
        DownloadSettings().save()
        await mirrored(model)
        model.smartDownloads.run()
    }

    /// Demo only: the remote on (port from `MUSICSYNC_REMOTE_PORT`), two paired devices and an open pairing code.
    private static func remoteScene(_ model: AppModel) async {
        model.remote.isEnabled = true
        _ = model.remote.newToken(name: "iPhone")
        _ = model.remote.newToken(name: "Apple Watch")
        model.remote.openPairing()
        // `MUSICSYNC_REMOTE_CODE_FILE=<path>` gets the code, so a script can pair while the scene stays open.
        if let file = env["MUSICSYNC_REMOTE_CODE_FILE"] { try? model.remote.pairingCode?.write(toFile: file, atomically: true, encoding: .utf8) }
    }

    /// Loads the first album, paused: a scene needs a song, not sound.
    private static func playPaused(_ model: AppModel) async {
        guard let album = await first({ model.albums.first }) else { return }
        model.play(album)
        _ = await first({ model.player.current })
        model.player.toggle()
    }

    /// A paused queue of three albums: two songs of the first in the history, two Play Next songs, AutoPlay songs,
    /// 42 s into the current song. Private, so nothing is scrobbled.
    private static func queueScene(_ model: AppModel) async {
        guard let albums = await first({ model.albums.count >= 3 ? Array(model.albums.prefix(3)) : nil }) else { return }
        var lists: [[PlayItem]] = []
        for album in albums { lists.append(((try? await model.album(album.id))?.song ?? []).map(PlayItem.server)) }
        guard let client = model.client, lists[0].count > 3 else { return }
        let player = model.player
        player.privateSession = true
        player.restore(QueueSnapshot(server: QueueKeeper.key(client), items: lists[0], origins: lists[0].map { _ in .source },
                                     index: 0, elapsed: 0, shuffle: false, repeatMode: "off"))
        player.start(at: 1, paused: true)
        player.start(at: 2, paused: true)
        player.playNext(Array(lists[1].prefix(2)))
        player.addAutoPlay(Array(lists[2].prefix(4)))
        _ = await first({ player.duration > 0 ? true : nil })
        player.seek(to: 42)
    }

    /// Shows `view` in its own window, for views that are not part of the main window.
    private static func open(_ view: some View, _ title: String, _ model: AppModel) {
        // The tint as the Settings scene sets it.
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.environment(model).tint(Color.musicAccent)))
        window.title = title
        window.orderFront(nil)
        extraWindow = window
    }

    /// Clicks the front window at `point` (from the top left of its content) with `flags`, as the mouse does.
    private static func click(_ point: CGPoint, _ flags: NSEvent.ModifierFlags) {
        guard let window = NSApp.windows.first(where: \.isVisible), let height = window.contentView?.bounds.height else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1).map { NSApp.postEvent($0, atStart: false) }
        }
    }

    /// A new selection clears the path and the search text a moment later, so wait for that first.
    private static func select(_ item: SidebarItem, _ model: AppModel) async {
        model.selection = item
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The album with the shortest playing time: the smallest real download.
    private static func shortestAlbum(_ model: AppModel) async -> Album? {
        await first({ model.albums.isEmpty ? nil : model.albums.min { ($0.duration ?? .max) < ($1.duration ?? .max) } })
    }

    /// Polls `value` until it is not nil, for at most 30 s.
    private static func first<T>(_ value: () -> T?) async -> T? {
        for _ in 0..<300 {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Pops up the menu of `menuPath` inside the main window and runs `capture` a second later. The pop-up
    /// tracks the mouse until the menu closes, so `capture` runs from a timer in the menu's run loop mode.
    private static func openMenu(then capture: @escaping @MainActor @Sendable () -> Void) {
        guard let first = menuPath.first, var menu = NSApp.mainMenu?.item(withTitle: first)?.submenu,
              let view = NSApp.windows.first(where: \.isVisible)?.contentView else { return capture() }
        for title in menuPath.dropFirst() { if let sub = menu.item(withTitle: title)?.submenu { menu = sub } }
        let timer = Timer(timeInterval: 1, repeats: false) { _ in MainActor.assumeIsolated { capture() } }
        RunLoop.main.add(timer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: 380, y: view.bounds.height - 120), in: view)
    }

    /// Captures the front app window through the window server (with materials), else through AppKit.
    /// `MUSICSYNC_SHOT_METHOD=cache` forces the AppKit path; a locked screen uses it too, as the window server gives a blank image then.
    private static func save(to url: URL) -> Bool {
        guard let window = NSApp.orderedWindows.first(where: \.isVisible) else { return false }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        let image = env["MUSICSYNC_SHOT_METHOD"] == "cache" || locked ? nil : menuPath.isEmpty ? windowServerImage(window) : appWindowsImage()
        guard let rep = image.map(NSBitmapImageRep.init(cgImage:)) ?? cachedImage(window),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `CGWindowListCreateImage` of this one window; it is unavailable in the SDK, so it is loaded at run time.
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        // Options: including window (1 << 3); bounds ignore framing (1 << 0) | best resolution (1 << 3).
        return unsafeBitCast(symbol, to: Create.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?
            .takeRetainedValue()
    }

    /// All on-screen windows of this app in one image: the main window with an open menu.
    private static func appWindowsImage() -> CGImage? {
        typealias Create = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"),
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var ids = list.filter { $0[kCGWindowOwnerPID as String] as? Int32 == getpid() }
            .compactMap { ($0[kCGWindowNumber as String] as? UInt32).map { UnsafeRawPointer(bitPattern: UInt($0)) } }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        return unsafeBitCast(symbol, to: Create.self)(.null, array, 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    private static func cachedImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
