import Foundation
import Library
import Playback
import Subsonic
import Support

/// Keeps the queue across launches: saves it to a file every few seconds while it changes or plays and on quit,
/// and loads it paused after connecting to the same server (`QueueSnapshot`).
@MainActor
final class QueueKeeper {
    private unowned let app: AppModel
    private var throttle = SaveThrottle(minimumGap: 2, interval: 10)
    /// Server of the loaded queue; nothing is saved before the load ran, so a launch never overwrites the file.
    private var server: String?
    /// Current entry, play state and entry keys at the last check, to see changes.
    private var seen: (key: Int?, playing: Bool, keys: [Int], shuffle: Bool, repeatMode: RepeatMode)?
    private var observer: Any?

    static var file: URL { Paths.appSupport.appendingPathComponent("Queue.json") }

    init(app: AppModel) {
        self.app = app
        observer = NotificationCenter.default.addObserver(forName: .appWillQuit, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.saveNow() }
        }
        // Every second while playing or a save waits; otherwise until the queue or the play state changes.
        Task { [weak self] in
            var busy = true
            while !Task.isCancelled {
                if busy { try? await Task.sleep(for: .seconds(1)) } else { await nextChange { _ = self?.signature } }
                guard let self else { return }
                busy = self.tick()
            }
        }
    }

    static func key(_ client: SubsonicClient) -> String { "\(client.username)@\(client.baseURL.absoluteString)" }

    /// After connecting: loads the queue saved for this server, without songs that are gone or local files that
    /// were removed. Songs that cannot play offline stay; the player skips them.
    func restore(_ client: SubsonicClient, library: Library?) async {
        let key = Self.key(client), url = Self.file
        server = nil
        let saved = await Task.detached { QueueSnapshot<PlayItem>.load(from: url) }.value
        guard app.client?.baseURL == client.baseURL, app.client?.username == client.username else { return }
        defer { server = key }
        guard let saved, saved.server == key, app.player.current == nil else { return }
        var known: Set<String>?
        if let db = library?.database, await db.isHealthy, await db.isPopulated {
            let ids = saved.items.compactMap { if case .server(let s) = $0 { s.id } else { nil } }
            known = Set(await db.songs(ids: ids).map(\.id))
        }
        let files = await Task.detached { Set(saved.items.compactMap { item -> String? in
            if case .file(let url, _, _, _) = item, url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { url.path } else { nil }
        }) }.value
        guard app.client?.baseURL == client.baseURL, app.player.current == nil,
              let kept = saved.filtered({ item in
                  switch item {
                  case .server(let song): known?.contains(song.id) ?? true
                  case .file(let url, _, _, _): !files.contains(url.path)
                  }
              }) else { return }
        app.player.restore(kept)
        seen = signature
    }

    /// Before the server changes: saves the queue and stops saving until the next `restore`.
    func leave() {
        saveNow()
        server = nil
        seen = nil
    }

    /// Writes the queue now, on the main thread; for quitting, when there is no time to wait.
    func saveNow() {
        guard let server else { return }
        if let snapshot = app.player.snapshot(server: server) { try? snapshot.save(to: Self.file) }
        else { try? FileManager.default.removeItem(at: Self.file) }
    }

    private var signature: (key: Int?, playing: Bool, keys: [Int], shuffle: Bool, repeatMode: RepeatMode) {
        let player = app.player
        return (player.index.map { player.line.keys[$0] }, player.isPlaying, player.line.keys, player.shuffle, player.repeatMode)
    }

    /// True while playing or a save waits.
    private func tick() -> Bool {
        guard let server else { return false }
        let now = Date(), current = signature
        if let seen, seen.key != current.key || seen.playing != current.playing || seen.keys != current.keys
            || seen.shuffle != current.shuffle || seen.repeatMode != current.repeatMode { throttle.request(now: now) }
        if current.playing { throttle.playing(now: now) }
        seen = current
        if throttle.fire(now: now) {
            let snapshot = app.player.snapshot(server: server), url = Self.file
            Task.detached(priority: .utility) {
                if let snapshot { try? snapshot.save(to: url) } else { try? FileManager.default.removeItem(at: url) }
            }
        }
        return current.playing || throttle.due != nil
    }
}
