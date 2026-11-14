import Preferences
import SwiftUI

/// A page of the Settings window, with its sidebar icon and the words the search finds it by.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, playback, server, library, downloads, sync, shortcuts, remote, sharing, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .sync: "iPod Sync"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .playback: "play.fill"
        case .server: "server.rack"
        case .library: "books.vertical.fill"
        case .downloads: "arrow.down.circle.fill"
        case .sync: "ipod"
        case .shortcuts: "keyboard.fill"
        case .remote: "iphone.radiowaves.left.and.right"
        case .sharing: "square.and.arrow.up.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    /// Fixed like the System Settings icons; not the accent color.
    var color: Color {
        switch self {
        case .general, .advanced: .gray
        case .appearance: .indigo
        case .playback: Color(red: 0.98, green: 0.14, blue: 0.24)
        case .server, .sharing: .blue
        case .library: .orange
        case .downloads: .green
        case .sync: .teal
        case .shortcuts: Color(white: 0.45)
        case .remote: .purple
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["menu bar", "song title", "notifications", "spotlight"]
        case .appearance: ["accent color", "theme", "album covers", "grid", "density", "size", "sidebar", "now playing", "background",
                           "start page", "song list", "columns", "rating", "plays", "format", "row height", "compact", "album color", "animated"]
        case .playback: ["crossfade", "sound check", "replaygain", "volume", "streaming quality", "bitrate", "speed", "gapless", "autoplay"]
        case .server: ["navidrome", "subsonic", "url", "address", "username", "password", "connection", "account"]
        case .library: ["background sync", "mirror", "lyrics", "covers", "home", "shelves", "top picks", "made for you", "recently played",
                        "because you listened", "most played", "discover", "scrobble", "play counts", "history", "stats", "recommendations", "lrclib"]
        case .downloads: ["offline", "storage", "cache", "smart downloads", "space"]
        case .sync: ["ipod", "preset", "format", "aac", "alac", "apple lossless", "flac", "opus", "rockbox", "bitrate", "ffmpeg", "workers",
                     "sound check", "eject", "whole albums", "playlists", "lyrics", "convert on the server", "free space", "capacity",
                     "auto sync", "connect", "play counts", "name", "guid", "firewire", "cover size"]
        case .shortcuts: ["keyboard", "global", "hot keys", "media keys"]
        case .remote: ["iphone", "ipad", "apple watch", "web", "pairing", "port"]
        case .sharing: ["share links", "expire", "public"]
        case .advanced: ["network", "timeout", "cover cache", "clear", "diagnostics", "logs", "export", "reset all settings"]
        }
    }

    func matches(_ query: String) -> Bool { SettingsSearch.matches(query, title: title, keywords: keywords) }
}

/// White symbol on a colored rounded square, as in System Settings.
struct SettingsIcon: View {
    let page: SettingsPage

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(page.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// One-sentence explanation under a settings section.
struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}
