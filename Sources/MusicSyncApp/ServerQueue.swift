import AppKit
import Observation
import Playback
import Subsonic
import Support

/// The play queue on the server (`savePlayQueue`/`getPlayQueue`): saved on pause, on song change and every 30 s
/// while playing; a newer queue from another device is offered as "Continue from…" (hand-off).
@MainActor @Observable
final class ServerQueue {
    /// A queue saved by another device.
    struct Offer {
        let device: String
        let songs: [Song]
        let index: Int
        let position: TimeInterval
        let changed: Date
        var song: Song { songs[index] }
    }

    private static let enabledKey = "syncPlayQueue"
    private static let handledKey = "playQueueHandled"
    /// Most ids sent; long queues are cut around the current song, to keep the request short.
    private static let limit = 200

    /// Settings > Playback.
    var enabled = UserDefaults.app.object(forKey: enabledKey) as? Bool ?? true {
        didSet { UserDefaults.app.set(enabled, forKey: Self.enabledKey); if enabled { Task { await check() } } else { offer = nil } }
    }
    /// The server answered `getPlayQueue`.
    private(set) var supported = false
    private(set) var offer: Offer?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var throttle = SaveThrottle(minimumGap: 10, interval: 30)
    /// Saving starts once something played here, so a launch does not overwrite the queue of another device.
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var seen: (song: String?, playing: Bool) = (nil, false)
    /// What this app saved last.
    @ObservationIgnored private var saved: RemoteQueueState?
    @ObservationIgnored private var inactiveSince: Date?
    @ObservationIgnored private var observers: [Any] = []

    init(app: AppModel) {
        self.app = app
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inactiveSince = Date() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            },
        ]
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// After connecting and loading the local queue: finds out if the server keeps queues and offers a newer one.
    func connected(_ client: SubsonicClient) async {
        supported = false
        offer = nil
        armed = false
        saved = nil
        throttle = SaveThrottle(minimumGap: 10, interval: 30)
        do {
            let info = try await client.getPlayQueue()
            guard isCurrent(client) else { return }
            supported = true
            evaluate(info, client)
        } catch SubsonicError.api(code: 70, _) {
            supported = isCurrent(client)  // no queue saved yet
        } catch {}
    }

    /// Looks for a newer queue on the server.
    func check() async {
        guard enabled, supported, let client = app.client, !app.player.isPlaying,
              let info = try? await client.getPlayQueue(), isCurrent(client) else { return }
        evaluate(info, client)
    }

    /// Plays the offered queue from its position.
    func resume() {
        guard let offer else { return }
        markHandled(offer.changed)
        self.offer = nil
        app.player.play(offer.songs, startAt: offer.index, shuffled: false)
        if offer.position > 0 { app.player.seek(to: offer.position) }
    }

    func dismiss() {
        if let offer { markHandled(offer.changed) }
        offer = nil
    }

    private func evaluate(_ info: PlayQueueInfo?, _ client: SubsonicClient) {
        guard enabled, !app.player.isPlaying, let info, let current = info.current,
              let index = info.songs.firstIndex(where: { $0.id == current }) else { return }
        let remote = RemoteQueueState(current: current, position: TimeInterval(info.position ?? 0) / 1000,
                                      changed: info.changedDate, changedBy: info.changedBy)
        let local: (String?, TimeInterval) = (app.player.current?.id, app.player.elapsed)
        guard let changed = remote.changed,
              QueueHandoff.offers(remote, client: SubsonicClient.clientName, saved: saved, handled: handled(client), local: local) else { return }
        offer = Offer(device: info.changedBy ?? "another device", songs: info.songs, index: index, position: remote.position, changed: changed)
    }

    private func becameActive() {
        defer { inactiveSince = nil }
        guard let since = inactiveSince, Date().timeIntervalSince(since) > 60 else { return }
        Task { await check() }
    }

    private func tick() {
        let player = app.player, now = Date()
        let song: String? = if case .server(let s)? = player.current { s.id } else { nil }
        if player.isPlaying { armed = true }
        if armed, song != seen.song || (seen.playing && !player.isPlaying) { throttle.request(now: now) }
        if player.isPlaying { throttle.playing(now: now) }
        seen = (song, player.isPlaying)
        guard enabled, supported, armed, let song, let client = app.client, throttle.fire(now: now) else { return }
        save(song, client)
    }

    private func save(_ song: String, _ client: SubsonicClient) {
        let player = app.player
        let ids = player.queue.compactMap { if case .server(let s) = $0 { s.id } else { nil } }
        let at = ids.firstIndex(of: song) ?? 0, start = max(0, min(at - 20, ids.count - Self.limit))
        let window = Array(ids[start..<min(ids.count, start + Self.limit)])
        saved = RemoteQueueState(current: song, position: player.elapsed, changed: nil, changedBy: nil)
        if offer != nil { offer = nil }  // playing here wins
        let position = Int(player.elapsed * 1000)
        Task { try? await client.savePlayQueue(ids: window, current: song, position: position) }
    }

    private func isCurrent(_ client: SubsonicClient) -> Bool {
        app.client?.baseURL == client.baseURL && app.client?.username == client.username
    }

    private func handled(_ client: SubsonicClient) -> Date? {
        (UserDefaults.app.dictionary(forKey: Self.handledKey)?[QueueKeeper.key(client)] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    private func markHandled(_ date: Date) {
        guard let client = app.client else { return }
        var all = UserDefaults.app.dictionary(forKey: Self.handledKey) ?? [:]
        all[QueueKeeper.key(client)] = date.timeIntervalSince1970
        UserDefaults.app.set(all, forKey: Self.handledKey)
    }
}
