import AppKit
import Carbon.HIToolbox
import Integration
import Library
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

    static func start(_ model: AppModel) {
        guard let output else { return }
        Task {
            let delay = Double(env["MUSICSYNC_SHOT_DELAY"] ?? "") ?? 6
            try? await Task.sleep(for: .seconds(1))  // the main window opens
            NSApp.windows.first?.setContentSize(NSSize(width: 1280, height: 820))
            await show(env["MUSICSYNC_SCENE"] ?? "home", model)
            try? await Task.sleep(for: .seconds(delay))
            exit(save(to: URL(fileURLWithPath: output)) ? 0 : 1)
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

    /// Shows `view` in its own window, for views that are not part of the main window.
    private static func open(_ view: some View, _ title: String, _ model: AppModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.environment(model)))
        window.title = title
        window.orderFront(nil)
        extraWindow = window
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

    /// Captures the front app window through the window server (with materials), else through AppKit.
    /// `MUSICSYNC_SHOT_METHOD=cache` forces the AppKit path; a locked screen uses it too, as the window server gives a blank image then.
    private static func save(to url: URL) -> Bool {
        guard let window = NSApp.orderedWindows.first(where: \.isVisible) else { return false }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        let image = env["MUSICSYNC_SHOT_METHOD"] == "cache" || locked ? nil : windowServerImage(window)
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

    private static func cachedImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
