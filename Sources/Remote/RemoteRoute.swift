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
    /// Removes entry `offset` of the songs up next.
    case removeQueue(offset: Int, id: String?)
    /// Moves entry `from` of the songs up next so that it ends at `to`.
    case moveQueue(from: Int, to: Int, id: String?)
    /// Plays on the server's own output (jukebox) or on the Mac.
    case output(server: Bool)

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
            guard let offset = Self.offset(p["offset"]) else { return nil }
            self = .playQueue(offset: offset, id: p["id"])
        case "remove":
            guard let offset = Self.offset(p["offset"]) else { return nil }
            self = .removeQueue(offset: offset, id: p["id"])
        case "move":
            guard let from = Self.offset(p["from"]), let to = Self.offset(p["to"]) else { return nil }
            self = .moveQueue(from: from, to: to, id: p["id"])
        case "output":
            guard let server = p["server"].flatMap(Self.bool) else { return nil }
            self = .output(server: server)
        default: return nil
        }
    }

    /// Bounded, so `index + 1 + offset` cannot overflow.
    static func offset(_ text: String?) -> Int? {
        guard let n = text.flatMap(Int.init), (0..<10_000_000).contains(n) else { return nil }
        return n
    }

    private static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "1", "true", "on": true
        case "0", "false", "off": false
        default: nil
        }
    }
}

/// What the remote can list, open and play.
public enum RemoteKind: String, Codable, Sendable, CaseIterable {
    case artist, album, playlist, mix, song
}

/// Where `POST /api/play/…` puts the songs: instead of the queue, after the current song, or at the end.
public enum PlayMode: String, Sendable {
    case now, next, last
}

/// What a request asks for. Every route except the page, its manifest and icon, and pairing needs a paired token.
public enum RemoteRoute: Equatable, Sendable {
    case page, manifest, icon
    /// A few seconds of silent audio; the page loops it so that the phone shows lock screen controls.
    case silence
    /// `POST /api/pair` with `code` and `name`.
    case pair(code: String, name: String)
    /// `POST /api/pair` with `link`: the token of the QR code link `/pair?t=<token>`, which only opens the page.
    case pairLink(String, name: String)
    case state, events, lyrics
    case command(RemoteCommand)
    case search(String)
    /// `GET /api/browse/<kind>?offset=n`: a page of all artists, albums, playlists or mixes.
    case list(RemoteKind, offset: Int)
    /// `GET /api/browse/<kind>/<id>?offset=n`: the albums of an artist, the songs of an album, playlist or mix.
    case detail(RemoteKind, id: String, offset: Int)
    /// `POST /api/play/<kind>/<id>?mode=now|next|last&start=n`; `start` is the song to begin with.
    case play(RemoteKind, id: String, mode: PlayMode, start: Int)
    case cover(String)

    public var needsToken: Bool {
        switch self {
        case .page, .manifest, .icon, .pair, .pairLink: false
        default: true
        }
    }

    /// The route, or the error status to answer with.
    public static func parse(_ r: HTTPRequest) -> Result<RemoteRoute, HTTPStatus> {
        guard sameOrigin(r), localHost(r) else { return .failure(.forbidden) }
        let get = r.method == "GET" || r.method == "HEAD", post = r.method == "POST"
        let p = r.parameters
        let route: RemoteRoute?, allowed: Bool
        let s = r.path
        let at = { (i: Int) in s.indices.contains(i) ? s[i] : "" }
        let kind = RemoteKind(rawValue: at(2)), id = at(3), offset = p["offset"] == nil ? 0 : RemoteCommand.offset(p["offset"])
        switch (s.count, at(0), at(1), at(2)) {
        case (0, _, _, _), (1, "pair", _, _): (route, allowed) = (.page, get)
        case (1, "manifest.webmanifest", _, _): (route, allowed) = (.manifest, get)
        case (1, "icon.png", _, _), (1, "apple-touch-icon.png", _, _): (route, allowed) = (.icon, get)
        case (1, "silence.wav", _, _): (route, allowed) = (.silence, get)
        case (2, "cover", let id, _): (route, allowed) = (id.isEmpty ? nil : .cover(id), get)
        case (2, "api", "pair", _):
            let name = p["name"] ?? ""
            (route, allowed) = (p["link"].map { .pairLink($0, name: name) } ?? p["code"].map { .pair(code: $0, name: name) }, post)
        case (2, "api", "state", _): (route, allowed) = (.state, get)
        case (2, "api", "events", _): (route, allowed) = (.events, get)
        case (2, "api", "lyrics", _): (route, allowed) = (.lyrics, get)
        case (2, "api", "search", _): (route, allowed) = (.search(p["q"] ?? ""), get)
        case (3, "api", "command", let name): (route, allowed) = (RemoteCommand(name, p).map(RemoteRoute.command), post)
        case (3, "api", "browse", _):
            (route, allowed) = (kind == .song ? nil : kind.flatMap { k in offset.map { .list(k, offset: $0) } }, get)
        case (4, "api", "browse", _):
            (route, allowed) = (kind == .song || id.isEmpty ? nil : kind.flatMap { k in offset.map { .detail(k, id: id, offset: $0) } }, get)
        case (4, "api", "play", _):
            let mode = PlayMode(rawValue: p["mode"] ?? "now"), start = p["start"] == nil ? 0 : RemoteCommand.offset(p["start"])
            let parsed: RemoteRoute? = if let kind, let mode, let start, !id.isEmpty { .play(kind, id: id, mode: mode, start: start) } else { nil }
            (route, allowed) = (parsed, post)
        default: return .failure(.notFound)
        }
        guard allowed else { return .failure(.methodNotAllowed) }
        guard let route else { return .failure(.badRequest) }
        return .success(route)
    }

    /// Against DNS rebinding: a page of another site that resolves to this Mac sends its own name as `Host`.
    /// Only IP addresses, `localhost` and Bonjour `.local` names are served.
    static func localHost(_ r: HTTPRequest) -> Bool {
        guard let host = r.headers["host"]?.lowercased() else { return true }
        if host.hasPrefix("[") { return true }
        let name = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return name == "localhost" || name.hasSuffix(".local") || (!name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." })
    }

    /// A browser sends `Origin` on cross-site posts; it must name this server.
    static func sameOrigin(_ r: HTTPRequest) -> Bool {
        guard let origin = r.headers["origin"] else { return true }
        guard let host = r.headers["host"], let url = URL(string: origin), let name = url.host else { return false }
        let port = url.port.map { ":\($0)" } ?? ""
        return (name + port).lowercased() == host.lowercased() || ("[" + name + "]" + port).lowercased() == host.lowercased()
    }
}
