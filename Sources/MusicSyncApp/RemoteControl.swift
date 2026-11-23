import Foundation
import Observation
import Remote
import Subsonic
import Support

/// Settings > Remote: a web remote for iPhone, iPad and Apple Watch on the local network. Off by default.
/// It follows the player through Observation and sends commands through the same player calls as the UI.
@MainActor @Observable
final class RemoteControl {
    private static let enabledKey = "remoteEnabled", portKey = "remotePort", devicesKey = "remoteDevices"
    static let defaultPort = 8686

    @ObservationIgnored unowned let app: AppModel
    /// The demo suite is shared by parallel demo instances, so the demo keeps nothing and starts off;
    /// development only: `MUSICSYNC_REMOTE_PORT=<port>` turns it on there.
    @ObservationIgnored private let persists: Bool

    var isEnabled: Bool {
        didSet { if persists { UserDefaults.app.set(isEnabled, forKey: Self.enabledKey) }; restart() }
    }
    var port: Int {
        didSet {
            guard (1024...65535).contains(port) else { port = oldValue; return }
            if persists { UserDefaults.app.set(port, forKey: Self.portKey) }
            restart()
        }
    }
    /// Why the server is not running although it is on.
    private(set) var failure: String?
    var access: RemoteAccess
    @ObservationIgnored var server: RemoteServer?
    @ObservationIgnored private var watchers: [AnyObject] = []
    /// Elapsed time of the last pushed state; a jump away from the expected time (a seek) pushes again.
    @ObservationIgnored private var pushed: (elapsed: Double, at: Date)?
    /// Recent covers by `<id>@<size>`; a few, as the page asks for the same ones again.
    @ObservationIgnored var covers: [String: Data] = [:]
    /// Covers of the searches and lists sent to the page, which may be outside the library lists.
    @ObservationIgnored var listedCovers: Set<String> = []
    @ObservationIgnored private var quitObserver: Any?

    var devices: [PairedDevice] { access.tokens.devices }

    init(app: AppModel) {
        self.app = app
        persists = !app.demo
        let env = ProcessInfo.processInfo.environment["MUSICSYNC_REMOTE_PORT"].flatMap(Int.init)
        let defaults = UserDefaults.app
        isEnabled = persists ? defaults.bool(forKey: Self.enabledKey) : env != nil
        port = persists ? (defaults.object(forKey: Self.portKey) as? Int ?? Self.defaultPort) : env ?? Self.defaultPort
        let saved = persists ? defaults.data(forKey: Self.devicesKey).flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } : nil
        access = RemoteAccess(tokens: TokenStore(devices: saved ?? []))
    }

    /// Called once at launch; the server stops when the app quits.
    func start() {
        quitObserver = NotificationCenter.default.addObserver(forName: .appWillTerminate, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.server?.stop() }
        }
        restart()
    }

    /// `http://<name>.local:<port>`, the address to open on the phone.
    var address: String {
        let host = LocalHost.address ?? "localhost"
        return "http://\(host):\(port)"
    }

    private func restart() {
        server?.stop()
        server = nil
        watchers = []
        failure = nil
        guard isEnabled else { return access.gate.close() }
        let name = "MusicSync on " + LocalHost.name
        let server = RemoteServer(port: UInt16(port), name: name) { [weak self] request in
            await self?.handle(request) ?? .response(.error(.unavailable))
        }
        do {
            try server.start { [weak self] message in
                Task { @MainActor in self?.failure = message; self?.server = nil }
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        self.server = server
        let player = app.player
        watchers = [
            Watcher({ [weak self] in self?.state(elapsed: false) }) { [weak self] _ in self?.push() },
            Watcher({ player.elapsed }) { [weak self] in self?.elapsedChanged($0) },
        ]
    }

    // MARK: Pairing

    var pairingCode: String? { access.gate.isOpen() ? access.gate.code : nil }
    var pairingLink: String { address + "/pair?t=" + access.gate.linkToken }
    var pairingEnds: Date? { access.gate.openUntil }

    func openPairing() { access.gate.open() }
    func closePairing() { access.gate.close() }

    /// A token for Shortcuts or scripts; shown once.
    func newToken(name: String) -> String {
        let token = access.tokens.pair(name: name)
        saveDevices()
        return token
    }

    func revoke(_ device: PairedDevice) {
        access.tokens.revoke(device.id)
        saveDevices()
        server?.closeStreams(owner: device.id)
    }

    func saveDevices() {
        access.saved()
        if persists { UserDefaults.app.set(try? JSONEncoder().encode(access.tokens.devices), forKey: Self.devicesKey) }
    }

    // MARK: State

    /// What the page shows. `elapsed: false` leaves the time out, for change tracking.
    func state(elapsed: Bool = true) -> RemoteState {
        let player = app.player
        let next = player.index.map { Array(player.queue.dropFirst($0 + 1).prefix(RemoteState.queueLimit)) } ?? []
        var state = RemoteState(song: player.current.map(Self.item), elapsed: elapsed ? player.elapsed : 0, duration: player.duration,
                                playing: player.isPlaying, volume: player.volume, shuffle: player.shuffle,
                                repeatMode: player.repeatMode.setting,
                                starred: currentSong.map(app.isStarred) ?? false, queue: next.map(Self.item))
        output(&state)
        return state
    }

    var currentSong: Song? {
        if case .server(let song)? = app.player.current { return song }
        return nil
    }

    private static func item(_ item: PlayItem) -> RemoteState.Item {
        RemoteState.Item(id: item.id, title: item.title, artist: item.artist, album: item.album, coverArt: item.coverArt)
    }

    private func push() {
        guard let server else { return }
        let state = state()
        pushed = (state.elapsed, Date())
        server.broadcast(ServerSentEvent.frame("state", state.json))
    }

    private func elapsedChanged(_ elapsed: TimeInterval) {
        guard let pushed else { return }
        let expected = pushed.elapsed + (app.player.isPlaying ? Date().timeIntervalSince(pushed.at) : 0)
        if abs(elapsed - expected) > 2 { push() }
    }
}
