import Foundation

public enum RepeatSetting: String, Codable, Sendable, CaseIterable {
    case off, all, one
}

/// A playback command from the remote: `POST /api/command/<name>`, arguments in the query or a JSON body.
public enum RemoteCommand: Equatable, Sendable {
    case toggle, play, pause, next, previous, star
    /// nil toggles.
    case shuffle(Bool?)
    /// nil moves to the next mode.
    case repeatMode(RepeatSetting?)
    case seek(Double)
    /// 0…1
    case volume(Double)
    /// Entry `offset` of the songs after the current one; `id` guards against a queue that changed meanwhile.
    case playQueue(offset: Int, id: String?)

    init?(_ name: String, _ p: [String: String]) {
        switch name {
        case "toggle": self = .toggle
        case "play": self = .play
        case "pause": self = .pause
        case "next": self = .next
        case "previous": self = .previous
        case "star": self = .star
        case "shuffle":
            guard let on = p["on"] else { self = .shuffle(nil); return }
            guard let value = Self.bool(on) else { return nil }
            self = .shuffle(value)
        case "repeat":
            guard let mode = p["mode"] else { self = .repeatMode(nil); return }
            guard let value = RepeatSetting(rawValue: mode) else { return nil }
            self = .repeatMode(value)
        case "seek":
            guard let time = p["time"].flatMap(Double.init), time.isFinite, time >= 0 else { return nil }
            self = .seek(time)
        case "volume":
            guard let value = p["value"].flatMap(Double.init), value.isFinite else { return nil }
            self = .volume(min(max(value, 0), 1))
        case "queue":
            // Bounded, so `index + 1 + offset` cannot overflow.
            guard let offset = p["offset"].flatMap(Int.init), (0..<10_000_000).contains(offset) else { return nil }
            self = .playQueue(offset: offset, id: p["id"])
        default: return nil
        }
    }

    private static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "1", "true", "on": true
        case "0", "false", "off": false
        default: nil
        }
    }
}

/// What a request asks for. Every `/api` route except pairing and every cover needs a paired token.
public enum RemoteRoute: Equatable, Sendable {
    case page, manifest, icon
    /// `POST /api/pair` with `code` and `name`.
    case pair(code: String, name: String)
    /// `GET /pair?t=<token>`: the link in the QR code.
    case pairLink(String)
    case state, events
    case command(RemoteCommand)
    case search(String)
    case playAlbum(String), playPlaylist(String)
    case cover(String)

    public var needsToken: Bool {
        switch self {
        case .page, .manifest, .icon, .pair, .pairLink: false
        default: true
        }
    }

    /// The route, or the error status to answer with.
    public static func parse(_ r: HTTPRequest) -> Result<RemoteRoute, HTTPStatus> {
        guard sameOrigin(r) else { return .failure(.forbidden) }
        let get = r.method == "GET" || r.method == "HEAD", post = r.method == "POST"
        let p = r.parameters
        let route: RemoteRoute?, allowed: Bool
        let s = r.path
        let at = { (i: Int) in s.indices.contains(i) ? s[i] : "" }
        switch (s.count, at(0), at(1), at(2)) {
        case (0, _, _, _): (route, allowed) = (.page, get)
        case (1, "manifest.webmanifest", _, _): (route, allowed) = (.manifest, get)
        case (1, "icon.png", _, _), (1, "apple-touch-icon.png", _, _): (route, allowed) = (.icon, get)
        case (1, "pair", _, _): (route, allowed) = (p["t"].map(RemoteRoute.pairLink), get)
        case (2, "cover", let id, _): (route, allowed) = (id.isEmpty ? nil : .cover(id), get)
        case (2, "api", "pair", _): (route, allowed) = (p["code"].map { .pair(code: $0, name: p["name"] ?? "") }, post)
        case (2, "api", "state", _): (route, allowed) = (.state, get)
        case (2, "api", "events", _): (route, allowed) = (.events, get)
        case (2, "api", "search", _): (route, allowed) = (.search(p["q"] ?? ""), get)
        case (3, "api", "command", let name): (route, allowed) = (RemoteCommand(name, p).map(RemoteRoute.command), post)
        case (4, "api", "play", "album"): (route, allowed) = (s[3].isEmpty ? nil : .playAlbum(s[3]), post)
        case (4, "api", "play", "playlist"): (route, allowed) = (s[3].isEmpty ? nil : .playPlaylist(s[3]), post)
        default: return .failure(.notFound)
        }
        guard allowed else { return .failure(.methodNotAllowed) }
        guard let route else { return .failure(.badRequest) }
        return .success(route)
    }

    /// A browser sends `Origin` on cross-site posts; it must name this server.
    static func sameOrigin(_ r: HTTPRequest) -> Bool {
        guard let origin = r.headers["origin"] else { return true }
        guard let host = r.headers["host"], let url = URL(string: origin), let name = url.host else { return false }
        let port = url.port.map { ":\($0)" } ?? ""
        return (name + port).lowercased() == host.lowercased() || ("[" + name + "]" + port).lowercased() == host.lowercased()
    }
}
