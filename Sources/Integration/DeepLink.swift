import Foundation

/// A `musicsync://` link: open an item, play it, search, or run a playback command.
/// The same links name Spotlight items and Handoff activities.
public enum DeepLink: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case album, artist, playlist, song
    }

    public enum Command: String, CaseIterable, Sendable {
        case play, pause, toggle, next, previous, favorite
    }

    /// `musicsync://album/<id>`
    case show(Kind, id: String)
    /// `musicsync://play/album/<id>`
    case play(Kind, id: String)
    /// `musicsync://search?q=<text>`
    case search(String)
    /// `musicsync://command/next`
    case command(Command)

    public static let scheme = "musicsync"
    /// `NSUserActivity` type of the page or song on screen; `userInfo["url"]` holds the link.
    public static let activityType = "dev.cofob.musicsync.browse"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        // Split the encoded path, so an id with an encoded "/" stays one part.
        let parts = url.path(percentEncoded: true).split(separator: "/").compactMap { $0.removingPercentEncoding }
        switch (host, parts.count) {
        case ("search", 0):
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            self = .search(items?.first { $0.name == "q" }?.value ?? "")
        case ("command", 1):
            guard let command = Command(rawValue: parts[0].lowercased()) else { return nil }
            self = .command(command)
        case ("play", 2):
            guard let kind = Kind(rawValue: parts[0].lowercased()), !parts[1].isEmpty else { return nil }
            self = .play(kind, id: parts[1])
        case (_, 1):
            guard let kind = Kind(rawValue: host), !parts[0].isEmpty else { return nil }
            self = .show(kind, id: parts[0])
        default:
            return nil
        }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .show(let kind, let id):
            parts.host = kind.rawValue
            parts.percentEncodedPath = "/" + Self.encode(id)
        case .play(let kind, let id):
            parts.host = "play"
            parts.percentEncodedPath = "/\(kind.rawValue)/" + Self.encode(id)
        case .search(let text):
            parts.host = "search"
            parts.queryItems = [URLQueryItem(name: "q", value: text)]
        case .command(let command):
            parts.host = "command"
            parts.path = "/" + command.rawValue
        }
        return parts.url ?? URL(string: "\(Self.scheme)://")!
    }

    private static let segment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static func encode(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: segment) ?? id }
}
