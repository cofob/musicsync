import Artwork
import Foundation
import ITunesDB

extension SyncJob {
    /// Writes everything that changed. Order: ArtworkDB, manifest with new entries, iTunesDB, manifest.
    ///
    /// A crash between the writes leaves either unknown-but-harmless files or manifest entries without tracks
    /// (dropped on the next run); never a database that points to missing data.
    func checkpoint(final: Bool = false) throws {
        guard dbDirty || artworkDirty || manifestDirty else { return }
        if artworkDirty, let artworkDB {
            try artworkDB.save(compactingAbove: final ? 0.25 : nil)
            artworkDirty = false
        }
        if dbDirty {
            var early = committed
            early.entries.merge(manifest.entries.filter { committed.entries[$0.key] == nil }) { a, _ in a }
            early.rockboxEntries.merge(manifest.rockboxEntries.filter { committed.rockboxEntries[$0.key] == nil }) { a, _ in a }
            if early != committed { try ManifestStore.save(early, for: device) }
            try writeDatabase()
            dbDirty = false
        }
        manifest.lastSync = Date()
        try ManifestStore.save(manifest, for: device)
        committed = manifest
        manifestDirty = false
        flushDeletes()
        sinceCheckpoint = 0
        lastCheckpoint = Date()
    }

    func checkpointIfDue() throws {
        if sinceCheckpoint >= 25 || Date().timeIntervalSince(lastCheckpoint) >= 120 { try checkpoint() }
    }

    private func writeDatabase() throws {
        guard let guid else { throw SyncError.noFirewireGuid }
        let data = try db.serialize(firewireGuid: guid)
        let reparsed: ITunesDB
        do { reparsed = try ITunesDB.parse(data) } catch { throw SyncError.verificationFailed("\(error)") }
        guard Hash58.verify(data, guid: guid) else { throw SyncError.verificationFailed("hash58 mismatch") }
        guard reparsed.tracks.map(\.id) == db.tracks.map(\.id), reparsed.playlists.count == db.playlists.count else {
            throw SyncError.verificationFailed("track or playlist list differs after writing")
        }
        try FileManager.default.atomicWrite(data, to: device.iTunesDBURL)
        if statsFilesPending {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: device.iTunesDir.path)) ?? []
            where Self.statsFiles.contains(name) || name.hasPrefix("OTGPlaylistInfo") {
                try? fm.removeItem(at: device.iTunesDir.appendingPathComponent(name))
            }
            statsFilesPending = false
        }
    }

    static let deletableRoots = ["iPod_Control/Music/", "Music/", "Playlists/"]

    /// Deletes files the written database no longer lists. Only inside the music and playlist folders.
    private func flushDeletes() {
        let fm = FileManager.default
        for path in pendingDeletes {
            let parts = path.split(separator: "/")
            guard !parts.contains(".."), Self.deletableRoots.contains(where: path.hasPrefix) else { continue }
            let url = device.mountURL.appendingPathComponent(path)
            try? fm.removeItem(at: url)
            if path.hasPrefix("Music/") { pruneEmptyFolders(from: url.deletingLastPathComponent()) }
        }
        pendingDeletes = []
    }

    /// Removes an album/artist folder that holds nothing but our `cover.jpg` and macOS litter.
    func pruneEmptyFolders(from folder: URL) {
        let fm = FileManager.default
        let root = device.mountURL.appendingPathComponent("Music").standardizedFileURL.path
        var dir = folder.standardizedFileURL
        while dir.path.hasPrefix(root + "/") {
            let litter = { (name: String) in name == "cover.jpg" || name == ".DS_Store" || name.hasPrefix("._") }
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path), names.allSatisfy(litter) else { return }
            for name in names { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            guard rmdir(dir.path) == 0 else { return }
            dir = dir.deletingLastPathComponent()
        }
    }
}
