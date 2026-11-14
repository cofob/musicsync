import AppKit
import Integration
import Remote
import Subsonic

/// Requests of the remote page, after `RemoteAccess` checked the route and the token.
extension RemoteControl {
    func handle(_ request: HTTPRequest) async -> RemoteServer.Reply {
        let decision = access.decide(request)
        if access.tokensChanged { saveDevices() }
        switch decision {
        case .respond(let response): return .response(response)
        case .serve(.events, let device?): return .events(owner: device.id, first: ServerSentEvent.frame("state", state().json))
        case .serve(let route, _): return .response(await serve(route, request))
        }
    }

    private func serve(_ route: RemoteRoute, _ request: HTTPRequest) async -> HTTPResponse {
        switch route {
        case .page: return HTTPResponse(headers: [("Content-Type", "text/html; charset=utf-8")], body: Data(RemotePage.html.utf8))
        case .manifest: return HTTPResponse(headers: [("Content-Type", "application/manifest+json")], body: Data(RemotePage.manifest.utf8))
        case .icon: return HTTPResponse(headers: [("Content-Type", "image/png"), ("Cache-Control", "max-age=86400")], body: Self.icon)
        case .state: return .json(state())
        case .command(let command):
            guard run(command) else { return .error(.conflict) }
            return .json(state())
        case .silence: return RemoteAudio.ranged(RemoteAudio.silence, type: "audio/wav", range: request.headers["range"])
        case .lyrics: return .json(await lyrics())
        case .search(let text): return await search(text)
        case .list(let kind, let offset): return await list(kind, offset: offset)
        case .detail(let kind, let id, let offset): return await detail(kind, id: id, offset: offset)
        case .play(let kind, let id, let mode, let start): return await play(kind, id: id, mode: mode, start: start)
        case .cover(let id): return await cover(id, small: request.query["size"] == "small")
        case .pair, .pairLink, .events: return .error(.notFound)
        }
    }

    /// False when the command does not fit the queue (nothing playing, the queue changed).
    private func run(_ command: RemoteCommand) -> Bool {
        let player = app.player
        switch command {
        case .toggle: app.system.run(.toggle)
        case .play: app.system.run(.play)
        case .pause: app.system.run(.pause)
        case .next: app.system.run(.next)
        case .previous: app.system.run(.previous)
        case .star:
            guard let song = currentSong else { return false }
            app.toggleStar(song)
        case .shuffle(let on): player.setShuffle(on ?? !player.shuffle)
        case .repeatMode(let mode): player.repeatMode = mode.map(RepeatMode.init) ?? player.repeatMode.next
        case .seek(let time):
            guard player.current != nil else { return false }
            player.seek(to: player.duration > 0 ? min(time, player.duration) : time)
        case .volume(let value): player.volume = value
        case .playQueue(let offset, let id):
            guard upcoming(offset, id) else { return false }
            player.playUpcoming(at: offset)
        case .removeQueue(let offset, let id):
            guard upcoming(offset, id) else { return false }
            player.removeUpcoming(at: [offset])
        case .moveQueue(let from, let to, let id):
            guard upcoming(from, id), upcoming(to, nil) else { return false }
            player.moveUpcoming(from: [from], to: to > from ? to + 1 : to)
        case .output(let server):
            let jukebox = app.jukebox
            guard jukebox.isAvailable else { return false }
            Task { if server { await jukebox.activate() } else { await jukebox.deactivate() } }
        }
        return true
    }

    /// True when entry `offset` of the songs up next exists and, if given, has the song `id`.
    private func upcoming(_ offset: Int, _ id: String?) -> Bool {
        let player = app.player
        guard let index = player.index, player.queue.indices.contains(index + 1 + offset) else { return false }
        return id == nil || player.queue[index + 1 + offset].id == id
    }

    /// Only covers the page can show: the queue, the library lists and the last search. Never a free URL.
    private func cover(_ id: String, small: Bool) async -> HTTPResponse {
        let player = app.player
        let known = player.queue.contains { $0.coverArt == id } || listedCovers.contains(id)
            || app.albums.contains { $0.coverArt == id } || app.playlists.contains { $0.coverArt == id }
        guard known, let client = app.client else { return .error(.notFound) }
        let size = small ? 120 : 600, key = "\(id)@\(size)"
        var data = covers[key]
        if data == nil {
            data = try? await client.coverArt(id: id, size: size)
            if covers.count > 40 { covers.removeAll() }
            covers[key] = data
        }
        guard let data else { return .error(.notFound) }
        let png = data.starts(with: [0x89, 0x50, 0x4e, 0x47])
        return HTTPResponse(headers: [("Content-Type", png ? "image/png" : "image/jpeg"), ("Cache-Control", "private, max-age=86400")], body: data)
    }

    /// The app icon at 180 px, for the home screen.
    private static let icon: Data = {
        let size = NSSize(width: 180, height: 180)
        let image = NSImage(size: size, flipped: false) { rect in
            NSApp.applicationIconImage.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }()
}

extension RepeatMode {
    init(_ setting: RepeatSetting) {
        switch setting {
        case .off: self = .off
        case .all: self = .all
        case .one: self = .one
        }
    }

    var setting: RepeatSetting {
        switch self {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }
}
