import Foundation
import ITunesDB

extension SyncJob {
    /// Makes the device playlists match the wanted ones. Foreign playlists are never touched.
    func reconcilePlaylists() {
        if usesDB { reconcileStockPlaylists() }
        reconcileRockboxPlaylists()
    }

    private func reconcileStockPlaylists() {
        let present = Set(db.tracks.map(\.id))
        for p in plan.desiredPlaylists {
            let ids = p.songIDs.compactMap { manifest.entries[$0]?.trackID }.filter(present.contains)
            let existing = manifest.playlists[p.id].flatMap { pid in db.playlists.firstIndex { $0.persistentId == pid && !$0.isMaster } }
            switch (existing, ids.isEmpty) {
            case (let i?, true):
                db.playlists.remove(at: i)
                manifest.playlists[p.id] = nil
            case (let i?, false):
                guard db.playlists[i].name != p.name || db.playlists[i].trackIDs != ids else { continue }
                db.playlists[i].name = p.name
                db.playlists[i].trackIDs = ids
            case (nil, false):
                let playlist = Playlist(name: p.name, trackIDs: ids)
                db.playlists.append(playlist)
                manifest.playlists[p.id] = playlist.persistentId
            case (nil, true): continue
            }
            dbDirty = true
            manifestDirty = true
        }
    }

    /// `Playlists/<name>.m3u8` (see `RockboxPaths.playlistPaths`) with paths relative to that folder.
    private func reconcileRockboxPlaylists() {
        let fm = FileManager.default
        let m3uPaths = RockboxPaths.playlistPaths(for: plan.desiredPlaylists, recorded: manifest.rockboxPlaylists)
        let written = Set(plan.desiredPlaylists.filter { $0.songIDs.contains { manifest.rockboxEntries[$0] != nil } }
            .compactMap { m3uPaths[$0.id]?.lowercased() })
        /// Never deletes a path that a playlist of this run owns.
        func removeFile(_ old: String?) {
            if let old, !written.contains(old.lowercased()) { try? fm.removeItem(at: device.mountURL.appendingPathComponent(old)) }
        }
        for p in plan.desiredPlaylists {
            let present = p.songIDs.filter { manifest.rockboxEntries[$0] != nil }
            let paths = present.compactMap { manifest.rockboxEntries[$0]?.relativePath }
            let old = manifest.rockboxPlaylists[p.id]?.path
            let path = m3uPaths[p.id]!
            if paths.isEmpty {
                removeFile(old)
                manifest.rockboxPlaylists[p.id] = nil
                manifestDirty = true
                continue
            }
            let url = device.mountURL.appendingPathComponent(path)
            let data = Data(RockboxPaths.playlistContents(paths).utf8)
            let record = Manifest.RockboxPlaylist(path: path, songIDs: present)
            if manifest.rockboxPlaylists[p.id] == record, (try? Data(contentsOf: url)) == data { continue }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { warn("Playlist \(p.name) was not written: \(error.localizedDescription)"); continue }
            removeFile(old)
            manifest.rockboxPlaylists[p.id] = record
            manifestDirty = true
        }
    }
}
