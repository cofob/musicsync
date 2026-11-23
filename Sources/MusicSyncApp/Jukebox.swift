import SwiftUI
import Observation
import Subsonic

/// Jukebox mode (Subsonic `jukeboxControl`): the server's own audio output plays the queue and the app is its remote.
/// The player keeps the queue; while this is its `remote`, the changes go to the server and a status poll brings the
/// server's song, position and play state back.
@MainActor @Observable
final class Jukebox: PlayerRemote {
    /// The user has the jukebox role and the server answered `status`.
    private(set) var isAvailable = false
    private(set) var isActive = false
    /// Host name of the server, for the output list.
    private(set) var serverName = ""

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var client: SubsonicClient?
    /// What the server was last told or reported; nil when unknown, so the next sync sends everything.
    @ObservationIgnored private var sent: JukeboxTarget?
    @ObservationIgnored private var gain: Double?
    /// The local volume, back when playback returns to this Mac.
    @ObservationIgnored private var localVolume = 1.0
    /// Actions waiting to go out, oldest first; `sender` sends them one at a time.
    @ObservationIgnored private var pending: [JukeboxAction] = []
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    private var player: Player { app.player }

    /// Offers the jukebox when the server has one for the user. In demo mode only a local stub server
    /// (`scripts/big-server.py`) is asked: the public demo must never play out loud.
    func connected(_ client: SubsonicClient) async {
        self.client = client
        guard !app.demo || client.baseURL.host == "127.0.0.1" else { return }
        let role = (try? await client.getUser(username: client.config.username).jukeboxRole) == true
        let works = role ? (try? await client.jukebox(.status)) != nil : false
        guard isCurrent(client) else { return }
        isAvailable = works
        serverName = client.baseURL.host ?? "Server"
    }

    /// Before a server change: the server stops, and the player is local again.
    func leave() {
        if isActive, let client { Task { _ = try? await client.jukebox(.stop) } }
        detach()
        client = nil
        isAvailable = false
    }

    /// Moves playback to the server: it goes on there at the same song and position, at the server's volume.
    func activate() async {
        guard isAvailable, !isActive, let client else { return }
        let status: JukeboxStatus
        do { status = try await client.jukebox(.status) } catch { return app.report(error) }
        guard isCurrent(client), !isActive else { return }
        let playing = player.isPlaying
        localVolume = player.volume
        gain = status.gain
        isActive = true
        player.remote = self
        player.mixer.stop()
        player.isPlaying = playing
        if let gain { player.volume = gain }
        sent = nil
        sync(restart: true)
        poller = Task { [weak self] in await self?.poll(client) }
    }

    /// Back to this Mac: the server stops and the queue goes on here at its position, paused when it was.
    func deactivate() async {
        guard isActive, let client else { return }
        await sender?.value
        let playing = player.isPlaying
        let status = try? await client.jukebox(.stop)
        guard isActive, isCurrent(client) else { return }
        if let status { apply(status) }
        let position = player.elapsed
        detach()
        guard let index = player.index else { return }
        player.start(at: index, paused: !playing)
        if position > 0 { player.seek(to: position) }
    }

    private func detach() {
        poller?.cancel()
        poller = nil
        pending = []
        sent = nil
        guard isActive else { return }
        isActive = false
        player.remote = nil
        player.volume = localVolume
    }

    // MARK: PlayerRemote

    func sync(restart: Bool) {
        let wanted = JukeboxTarget(queue: serverIds, current: player.index, playing: player.isPlaying)
        send(wanted.actions(from: sent, position: Int(player.elapsed), restart: restart))
        sent = wanted
        player.updateNowPlaying()
    }

    func setGain(_ gain: Double) {
        guard gain != self.gain else { return }
        self.gain = gain
        send([.setGain(gain)])
    }

    // MARK: Server

    /// A song id per queue entry; nil for local files, which the server cannot play.
    private var serverIds: [String?] {
        player.queue.map { if case .server(let song) = $0 { song.id } else { nil } }
    }

    /// Volume changes replace a waiting one, so a slider drag does not queue up.
    private func send(_ actions: [JukeboxAction]) {
        for action in actions {
            if case .setGain = action, case .setGain? = pending.last { pending.removeLast() }
            pending.append(action)
        }
        guard sender == nil, !pending.isEmpty, let client else { return }
        sender = Task { [weak self] in await self?.drain(client) }
    }

    private func drain(_ client: SubsonicClient) async {
        var last: JukeboxStatus?
        while !pending.isEmpty, isActive, isCurrent(client) {
            do { last = try await client.jukebox(pending.removeFirst()) } catch {
                app.report(error)
                pending = []
                sent = nil
                last = nil
            }
        }
        sender = nil
        if let last { apply(last) }
    }

    /// Every second the position moves on while playing; every second time the server's status replaces it, but
    /// only while a window of the app (main, MiniPlayer or the menu bar player) is on screen.
    private func poll(_ client: SubsonicClient) async {
        for tick in 1... {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isActive else { return }
            if player.isPlaying, player.duration > 0 { player.elapsed = min(player.elapsed + 1, player.duration) }
            guard tick % 2 == 0, sender == nil, Self.isOnScreen, let status = try? await client.jukebox(.status), sender == nil, isCurrent(client) else { continue }
            apply(status)
        }
    }

    /// A window the user can see; the menu bar item's own window cannot become key, so it does not count.
    static var isOnScreen: Bool {
        #if os(macOS)
        !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
        #else
        UIApplication.shared.applicationState != .background
        #endif
    }

    /// Takes the server's song, position, play state and volume: another client may have changed it.
    private func apply(_ status: JukeboxStatus) {
        guard isActive else { return }
        let ids = serverIds
        let index = status.currentIndex.flatMap { JukeboxTarget.queueIndex(of: $0, in: ids) }
        if let index { player.follow(index) }
        if let playing = status.playing { player.isPlaying = playing }
        if let position = status.position, player.duration > 0 { player.elapsed = min(max(0, Double(position)), player.duration) }
        if let gain = status.gain, gain != self.gain { self.gain = gain; player.volume = gain }
        sent = JukeboxTarget(ids: ids.compactMap { $0 }, index: index == nil ? nil : status.currentIndex, playing: player.isPlaying)
        player.updateNowPlaying()
    }

    private func isCurrent(_ client: SubsonicClient) -> Bool { client.baseURL == app.client?.baseURL && client.baseURL == self.client?.baseURL }
}
