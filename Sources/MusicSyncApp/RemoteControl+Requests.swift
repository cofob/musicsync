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
        case .search(let text): return await search(text)
        case .playAlbum(let id): app.system.open(.play(.album, id: id)); return HTTPResponse(.noContent)
        case .playPlaylist(let id): app.system.open(.play(.playlist, id: id)); return HTTPResponse(.noContent)
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
            guard let index = player.index, player.queue.indices.contains(index + 1 + offset),
                  id == nil || player.queue[index + 1 + offset].id == id else { return false }
            player.playUpcoming(at: offset)
        }
        return true
    }

    /// Albums from the server search, then playlists by name.
    private func search(_ text: String) async -> HTTPResponse {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let client = app.client else { return .json(["items": [RemoteSearchItem]()]) }
        let store = app.store
        do {
            let albums = try await client.search3(text, artistCount: 0, albumCount: 12, songCount: 0).album
            guard store === app.store else { return .error(.conflict) }
            let playlists = app.playlists.filter { $0.name.localizedStandardContains(text) }.prefix(6)
            searchCovers = Set(albums.compactMap(\.coverArt) + playlists.compactMap(\.coverArt))
            let items = albums.map { RemoteSearchItem(kind: "album", id: $0.id, name: $0.name, detail: $0.artist, coverArt: $0.coverArt) }
                + playlists.map { RemoteSearchItem(kind: "playlist", id: $0.id, name: $0.name, detail: nil, coverArt: $0.coverArt) }
            return .json(["items": items])
        } catch {
            return .error(.unavailable)
        }
    }

    /// Only covers the page can show: the queue, the library lists and the last search. Never a free URL.
    private func cover(_ id: String, small: Bool) async -> HTTPResponse {
        let player = app.player
        let known = player.queue.contains { $0.coverArt == id } || searchCovers.contains(id)
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
