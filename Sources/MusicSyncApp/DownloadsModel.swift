import Foundation
import Library
import Observation
import Subsonic
import Support

/// Offline downloads of the current server: live state for the views, the player hooks and the offline check.
/// The actions that need the library are in `AppModel+Downloads`.
@MainActor @Observable
final class DownloadsModel {
    /// Songs of one pin, counted on every store change so views read them in O(1).
    struct Group: Equatable {
        var ids: [String] = []
        var done = 0
        var failed = 0
    }

    enum GroupState: Equatable {
        case none, done
        case downloading(Double)
        /// Every song that did not finish failed.
        case failed(Int)
    }

    private(set) var manager: DownloadManager?
    /// Song id -> entry.
    private(set) var entries: [String: DownloadEntry] = [:]
    private(set) var pins: [DownloadPin] = []
    private(set) var groups: [DownloadReason: Group] = [:]
    private(set) var usedBytes: Int64 = 0
    private(set) var status = DownloadStatus()
    /// True when the server cannot be reached; set by the reachability check (and the `offline` shot scene).
    var isOffline = false
    /// Settings > Downloads; saved on every change.
    var settings = DownloadSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            let settings = settings, manager = manager
            Task { await manager?.update(settings: settings) }
        }
    }
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// Plays downloaded files, and skips songs that cannot play while offline.
    func attach(to player: Player) {
        player.localFile = { [weak self] id in self?.fileURL(id) }
        player.canPlay = { [weak self] item in
            guard let self, case .server(let song) = item else { return true }
            return isAvailable(song)
        }
    }

    // MARK: Lifecycle

    /// Opens the downloads of `client`'s server and resumes the queue.
    func start(client: SubsonicClient) {
        let manager = DownloadManager(serverKey: LibraryDatabase.serverKey(for: client.config), settings: settings)
        self.manager = manager
        tasks = [observe(manager), watchServer(client, manager)]
        Task { await manager.start(client: client) }
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        entries = [:]; pins = []; groups = [:]; usedBytes = 0
        status = DownloadStatus()
        isOffline = false
        guard let old = manager else { return }
        manager = nil
        await old.stop()
    }

    private func observe(_ manager: DownloadManager) -> Task<Void, Never> {
        Task { [weak self] in
            var revision = -1
            for await status in manager.status {
                guard let self, !Task.isCancelled, self.manager === manager else { return }
                self.status = status
                guard status.revision != revision else { continue }
                revision = status.revision
                await reload(manager)
            }
        }
    }

    private func reload(_ manager: DownloadManager) async {
        let list = await manager.store.entries(), pins = await manager.store.pins()
        guard self.manager === manager else { return }
        var groups: [DownloadReason: Group] = [:]
        for entry in list {
            for reason in entry.reasons where reason != .song {
                groups[reason, default: Group()].ids.append(entry.id)
                if entry.state == .done { groups[reason]?.done += 1 }
                if entry.state == .failed { groups[reason]?.failed += 1 }
            }
        }
        entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        self.pins = pins
        self.groups = groups
        usedBytes = list.reduce(0) { $0 + ($1.state == .done ? $1.size : 0) }
    }

    /// Pings the server: every 10 s while it is unreachable, every minute otherwise.
    private func watchServer(_ client: SubsonicClient, _ manager: DownloadManager) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let reachable: Bool
                do { _ = try await client.ping(); reachable = true } catch { reachable = error.isCancellation }
                guard !Task.isCancelled, let model = self, model.manager === manager else { return }
                if model.isOffline == reachable {
                    model.isOffline = !reachable
                    await manager.setOffline(!reachable)
                }
                try? await Task.sleep(for: .seconds(reachable ? 60 : 10))
            }
        }
    }

    // MARK: Reads

    func fileURL(_ songID: String) -> URL? { entries[songID].flatMap { manager?.fileURL($0) } }

    /// False while offline for songs that are not downloaded.
    func isAvailable(_ song: Song) -> Bool { !isOffline || fileURL(song.id) != nil }

    func isPinned(_ reason: DownloadReason) -> Bool { pins.contains { $0.reason == reason } }

    func state(of reason: DownloadReason) -> GroupState {
        guard isPinned(reason) else { return .none }
        let group = groups[reason] ?? Group()
        if group.done == group.ids.count { return .done }
        if group.failed > 0, group.done + group.failed == group.ids.count { return .failed(group.failed) }
        let running = group.ids.reduce(0) { $0 + (status.progress[$1] ?? 0) }
        return .downloading((Double(group.done) + running) / Double(group.ids.count))
    }

    /// Small symbol for song rows: downloaded, waiting or failed.
    func badge(_ song: Song) -> String? {
        switch entries[song.id]?.state {
        case .done?: "arrow.down.circle.fill"
        case .queued?, .downloading?: "arrow.down.circle.dotted"
        case .failed?: "exclamationmark.circle"
        case nil: nil
        }
    }

    /// A downloaded album with its downloaded songs, for album pages while offline.
    func savedAlbum(_ id: String) -> Album? {
        guard case .album(let album)? = pins.first(where: { $0.reason == .album(id) }) else { return nil }
        return album.withSongs(songs(of: .album(id)).sorted { ($0.discNumber ?? 1, $0.track ?? 0) < ($1.discNumber ?? 1, $1.track ?? 0) })
    }

    func savedPlaylist(_ id: String) -> Playlist? {
        guard case .playlist(let playlist)? = pins.first(where: { $0.reason == .playlist(id) }) else { return nil }
        return playlist.withEntries(songs(of: .playlist(id)))
    }

    func songs(of reason: DownloadReason) -> [Song] { (groups[reason]?.ids ?? []).compactMap { entries[$0]?.song } }
}
