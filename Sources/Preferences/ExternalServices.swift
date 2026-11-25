import Foundation

/// Hosts other than the user's server. The app connects to one only after the user allows it (`ExternalAccess`).
/// `Resources/InternetAccessPolicy.plist` lists the same hosts for Little Snitch.
public enum ExternalService: String, CaseIterable, Sendable {
    case presetCache, presetArchive, lrclib, artistPhotos, radio

    public var title: String {
        switch self {
        case .presetCache: "Visualizer Preset Cache"
        case .presetArchive: "Preset Archive on GitHub"
        case .lrclib: "LRCLIB Lyrics"
        case .artistPhotos: "Artist Photos"
        case .radio: "Internet Radio"
        }
    }

    /// What goes to the host and what comes back.
    public var purpose: String {
        switch self {
        case .presetCache: "Downloads visualizer presets with their pictures and compiled shaders. Nothing about you or your music is sent."
        case .presetArchive: "Downloads the Cream of the Crop preset pack from GitHub. Nothing about you or your music is sent."
        case .lrclib: "Sends the title, artist, album and length of the song in Now Playing to find lyrics the server does not have."
        case .artistPhotos: "Loads the artist photos that your server links to on other hosts (Last.fm, Spotify, Deezer)."
        case .radio: "Plays internet radio streams directly from the station hosts that you added on the server."
        }
    }

    /// Why the app needs it, and what stops when it is denied.
    public var reason: String {
        switch self {
        case .presetCache: "Without it, presets are compiled and measured on this device, which is slower."
        case .presetArchive: "Without it, the preset pack cannot be downloaded."
        case .lrclib: "Without it, only the lyrics of your server are shown."
        case .artistPhotos: "Without it, artists without a photo on your server show their initials."
        case .radio: "Without it, internet radio stations do not play."
        }
    }

    /// Known hosts; radio hosts are the stations' own.
    public var hosts: [String] {
        switch self {
        case .presetCache: ["musicsync-cache.cfb.wtf"]
        case .presetArchive: ["codeload.github.com"]
        case .lrclib: ["lrclib.net"]
        case .artistPhotos: ["lastfm.freetls.fastly.net", "i.scdn.co", "*.dzcdn.net"]
        case .radio: []
        }
    }
}

/// The user's answers for `ExternalService`s: true = allowed, false = denied, none = ask.
public struct ExternalAccess: StoredSettings {
    public var answers: [String: Bool] = [:]

    public static let defaultsKey = "externalAccess"

    public init() {}

    public subscript(_ service: ExternalService) -> Bool? {
        get { answers[service.rawValue] }
        set { answers[service.rawValue] = newValue }
    }
}
