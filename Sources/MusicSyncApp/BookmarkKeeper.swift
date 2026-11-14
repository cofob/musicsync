import Foundation
import Observation
import Playback
import Subsonic

/// Server bookmarks for long items such as podcast episodes (`ResumePoint`): saved on pause, on song change, on stop
/// and every 30 s while playing. An item played again goes on from its bookmark.
@MainActor @Observable
final class BookmarkKeeper {
    /// Saved positions in milliseconds, by song id; episode rows show them.
    private(set) var positions: [String: Int] = [:]
    /// The server answered `getBookmarks`.
    private(set) var supported = false

    private struct Item {
        let id: String
        let duration: TimeInterval
        let client: SubsonicClient
    }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var throttle = SaveThrottle(minimumGap: 5, interval: 30)
    /// The long item playing at the last check, where it was and whether it played.
    @ObservationIgnored private var seen: (item: Item?, elapsed: TimeInterval, playing: Bool) = (nil, 0, false)

    init(app: AppModel) {
        self.app = app
        // Every second while playing; otherwise until the song or the play state changes.
        Task { [weak self] in
            var busy = true
            while !Task.isCancelled {
                if busy { try? await Task.sleep(for: .seconds(1)) } else { await nextChange { _ = (self?.app.player.current, self?.app.player.isPlaying) } }
                guard let self else { return }
                busy = self.tick()
            }
        }
    }

    /// After connecting: loads the bookmarks of the user.
    func connected(_ client: SubsonicClient) async {
        positions = [:]
        supported = false
        guard let marks = try? await client.getBookmarks(), isCurrent(client) else { return }
        positions = Dictionary(marks.map { ($0.entry.id, $0.position) }, uniquingKeysWith: { first, _ in first })
        supported = true
    }

    /// Drops the bookmark of a finished item, e.g. after "Mark as Played".
    func clear(_ id: String) {
        guard supported, let client = app.client, positions.removeValue(forKey: id) != nil else { return }
        Task { try? await client.deleteBookmark(id: id) }
    }

    /// True while playing.
    private func tick() -> Bool {
        let player = app.player, now = Date()
        let item = longItem()
        if item?.id != seen.item?.id {
            if let old = seen.item { write(old, at: seen.elapsed) }
            throttle = SaveThrottle(minimumGap: 5, interval: 30)
            if let item, player.elapsed < 3,
               let at = positions[item.id].flatMap({ ResumePoint.resume(position: $0, duration: item.duration) }) { player.seek(to: at) }
        } else if let item, seen.playing, !player.isPlaying {
            write(item, at: player.elapsed)
        }
        if let item, player.isPlaying {
            throttle.playing(now: now)
            if throttle.fire(now: now) { write(item, at: player.elapsed) }
        }
        seen = (item, player.elapsed, player.isPlaying)
        return player.isPlaying
    }

    /// The current entry when it is a server item long enough for a bookmark.
    private func longItem() -> Item? {
        guard case .server(let song)? = app.player.current, let duration = song.duration.map(TimeInterval.init),
              duration > ResumePoint.minimumDuration, let client = app.client else { return nil }
        return Item(id: song.id, duration: duration, client: client)
    }

    private func write(_ item: Item, at elapsed: TimeInterval) {
        guard supported, isCurrent(item.client) else { return }
        switch ResumePoint.action(elapsed: elapsed, duration: item.duration) {
        case .save(let ms):
            guard positions[item.id] != ms else { return }
            positions[item.id] = ms
            Task { try? await item.client.createBookmark(id: item.id, position: ms) }
        case .delete:
            guard positions.removeValue(forKey: item.id) != nil else { return }
            Task { try? await item.client.deleteBookmark(id: item.id) }
        case .none: break
        }
    }

    private func isCurrent(_ client: SubsonicClient) -> Bool {
        app.client?.baseURL == client.baseURL && app.client?.username == client.username
    }
}
