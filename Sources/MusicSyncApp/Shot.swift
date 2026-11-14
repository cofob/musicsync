import AppKit
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
            guard let album = await first({ model.albums.first }) else { break }
            model.play(album)
            _ = await first({ model.player.current })
            model.player.toggle()  // paused: the scene needs a song, not sound
            model.showNowPlaying = true
        case "settings":
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
            window.title = "Settings"
            window.orderFront(nil)
            extraWindow = window
        case let s where s.hasPrefix("search:"):
            await select(.search, model)
            model.searchText = String(s.dropFirst(7))
            model.search.submit(model.searchText)
        default:
            print("Unknown scene: \(scene)")
            exit(2)
        }
    }

    /// A new selection clears the path and the search text a moment later, so wait for that first.
    private static func select(_ item: SidebarItem, _ model: AppModel) async {
        model.selection = item
        try? await Task.sleep(for: .milliseconds(300))
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
    /// `MUSICSYNC_SHOT_METHOD=cache` forces the AppKit path.
    private static func save(to url: URL) -> Bool {
        guard let window = NSApp.orderedWindows.first(where: \.isVisible) else { return false }
        let image = env["MUSICSYNC_SHOT_METHOD"] == "cache" ? nil : windowServerImage(window)
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
