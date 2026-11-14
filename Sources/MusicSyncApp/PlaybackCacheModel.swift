import Foundation
import Library
import Observation
import Playback
import Subsonic

/// The playback cache of the current server: songs the player streams are downloaded once more in the background
/// (the same request, so the same quality) and then play from disk, also offline. The player itself is not touched.
@MainActor @Observable
final class PlaybackCacheModel {
    private(set) var cache: PlaybackCache?
    /// Song id -> cached file.
    private(set) var files: [String: URL] = [:]
    private(set) var usedBytes: Int64 = 0
    @ObservationIgnored private var writing: (id: String, task: Task<Void, Never>)?

    func start(serverKey: String, limitGB: Double) {
        let cache = PlaybackCache(serverKey: serverKey, limitGB: limitGB)
        self.cache = cache
        reload(cache)
    }

    func stop() {
        writing?.task.cancel()
        writing = nil
        cache = nil
        files = [:]
        usedBytes = 0
    }

    func setLimit(gb: Double) {
        guard let cache else { return }
        Task {
            await cache.setLimit(gb: gb)
            reload(cache)
        }
    }

    func clear() {
        guard let cache else { return }
        writing?.task.cancel()
        Task {
            await cache.clear()
            reload(cache)
        }
    }

    func fileURL(_ id: String) -> URL? { files[id] }

    /// Follows the player: a streamed song is cached once it plays; a cached one counts as used.
    func watch(_ player: Player, isOffline: @escaping @MainActor () -> Bool) {
        withObservationTracking {
            _ = player.current?.id
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.trackChanged(player, offline: isOffline())
                self.watch(player, isOffline: isOffline)
            }
        }
    }

    private func trackChanged(_ player: Player, offline: Bool) {
        guard let cache, let index = player.index, case .server(let song)? = player.current, !(player.current?.isLive ?? false) else {
            return cancelWrite(keeping: nil)
        }
        cancelWrite(keeping: song.id)
        if files[song.id] != nil {
            Task { await cache.touch(song.id) }
            return
        }
        // Downloads play from their own file; the cache is only for streams.
        guard player.isPlaying, !offline, writing == nil, player.localFile?(song.id) == nil, let client = player.client else { return }
        let stream = player.settings.stream(for: song, fallback: player.transcoded.contains(index))
        let task = Task { [weak self] in
            // Best effort: a failed write only means the song streams again next time.
            _ = try? await cache.store(song, format: stream.format, maxBitRate: stream.maxBitRate, client: client)
            guard let self, self.cache === cache else { return }
            if writing?.id == song.id { writing = nil }
            reload(cache)
        }
        writing = (song.id, task)
    }

    /// A song that is no longer playing is not cached: only songs played on are kept.
    private func cancelWrite(keeping id: String?) {
        guard let writing, writing.id != id else { return }
        writing.task.cancel()
        self.writing = nil
    }

    private func reload(_ cache: PlaybackCache) {
        Task {
            let files = await cache.files(), used = await cache.usedBytes()
            guard self.cache === cache else { return }
            self.files = files
            usedBytes = used
        }
    }
}
