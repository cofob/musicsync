import AVFoundation
import Library
import Subsonic

/// `check:downloads`: against `scripts/big-server.py` with `BIG_MEDIA=1` and faults on (`FAULT_TRUNCATE`, `FAULT_DROP`).
/// Every finished download has the song's size and length and plays; cancel and Remove All leave no files; failures and
/// server errors read as the short messages of `FriendlyError`.
extension ShotChecks {
    static func downloads(_ model: AppModel) async {
        guard let base = model.config?.baseURL, base.host == "127.0.0.1", let client = model.client else {
            return check(false, "downloads needs MUSICSYNC_DEMO_SERVER on 127.0.0.1")
        }
        _ = await waitLong(seconds: 120) { model.albums.count > 3 && model.downloads.manager != nil }
        guard let manager = model.downloads.manager, model.albums.count > 3 else { return check(false, "albums and downloads open") }
        let downloads = model.downloads
        // Reading an album can fail on a faulty server: the user tries again.
        for album in model.albums.prefix(3) {
            for _ in 0..<5 where !downloads.isPinned(.album(album.id)) {
                model.download(album)
                _ = await waitLong(seconds: 10) { downloads.isPinned(.album(album.id)) }
            }
        }
        let settled = await waitLong(seconds: 300) {
            downloads.pins.count == 3 && !downloads.entries.isEmpty
                && downloads.entries.values.allSatisfy { $0.state == .done || $0.state == .failed }
        }
        let entries = Array(downloads.entries.values)
        let done = entries.filter { $0.state == .done }
        check(settled && done.count >= entries.count * 3 / 4, "downloads settle (\(done.count) of \(entries.count) done)")
        var bad: [String] = []
        for entry in done {
            guard let file = manager.fileURL(entry), let length = try? await AVURLAsset(url: file).load(.duration).seconds,
                  (try? await AVURLAsset(url: file).load(.isPlayable)) == true else { bad.append("\(entry.id) unreadable"); continue }
            if entry.size != Int64(entry.song.size ?? -1) { bad.append("\(entry.id) \(entry.size) of \(entry.song.size ?? 0) bytes") }
            if abs(length - Double(entry.song.duration ?? 0)) > 1 { bad.append("\(entry.id) \(Int(length)) of \(entry.song.duration ?? 0) s") }
        }
        check(bad.isEmpty, "every finished download is whole (\(bad.prefix(5)))")
        let errors = entries.compactMap(\.error)
        check(errors.allSatisfy(isFriendly), "download errors are friendly (\(Array(Set(errors)).prefix(3)))")

        if let entry = done.first {
            model.player.play([entry.song])
            check(await wait { model.player.isPlaying && model.player.elapsed > 1 }, "a downloaded song plays")
            model.player.pause()
        }

        // Cancel a running download and remove its album while it runs: only the part files of the failed songs,
        // kept for their retry, are left. Then Remove All: the folder is empty.
        let album = model.albums[3]
        func parts() -> Set<String> { Set(leftovers(manager).filter { $0.hasPrefix("part-") }) }
        let kept = parts()
        for _ in 0..<5 where !downloads.isPinned(.album(album.id)) {
            model.download(album)
            _ = await waitLong(seconds: 10) { downloads.isPinned(.album(album.id)) }
        }
        if await waitLong(seconds: 60, { downloads.entries.values.contains { $0.state == .downloading } }),
           let running = downloads.entries.values.first(where: { $0.state == .downloading }) {
            await manager.cancel(running.id)
            model.removeDownload(.album(album.id))
            check(await waitLong(seconds: 10) { !downloads.isPinned(.album(album.id)) && parts().isSubset(of: kept) },
                  "cancel and remove leave no part files (\(parts().subtracting(kept)))")
        } else { check(false, "a download to cancel") }
        model.removeAllDownloads()
        check(await waitLong(seconds: 20) { downloads.entries.isEmpty && leftovers(manager).isEmpty }, "Remove All leaves no files (\(leftovers(manager).prefix(3)))")

        // Server errors as the user reads them.
        await fault(base, "random=0&outage=6")
        try? await Task.sleep(for: .seconds(1))
        // A kept-alive connection is closed by the stub instead of refused.
        await expectMessage(client, ["The server refused the connection.", "The connection to the server was lost."], "server outage")
        try? await Task.sleep(for: .seconds(6))
        await fault(base, "auth=5")
        await expectMessage(client, ["Wrong user name or password."], "refused password")
        try? await Task.sleep(for: .seconds(5))
        await fault(base, "random=1")
    }

    /// No raw system or HTTP text.
    private static func isFriendly(_ message: String) -> Bool {
        !["NSURLErrorDomain", "HTTP status", "Unexpected server reply", "couldn’t be completed", "Server error"].contains { message.contains($0) }
    }

    private static func expectMessage(_ client: SubsonicClient, _ starts: [String], _ what: String) async {
        do {
            _ = try await client.getAlbumList2(type: "newest", size: 1)
            check(false, "\(what) fails")
        } catch {
            let message = error.friendlyMessage
            check(starts.contains { message.hasPrefix($0) }, "\(what): \(message)")
        }
    }

    /// Files and covers of the downloads folder in the demo directory.
    private static func leftovers(_ manager: DownloadManager) -> [String] {
        [manager.filesDirectory, manager.coversDirectory].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
    }

    private static func waitLong(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }

    private static func fault(_ base: URL, _ query: String) async {
        guard let url = URL(string: "fault?\(query)", relativeTo: base) else { return }
        _ = try? await URLSession.shared.data(from: url)
    }
}
