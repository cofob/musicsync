import Foundation
import ITunesDB

extension SyncJob {
    /// Makes the device playlists match the wanted ones. Foreign playlists are never touched.
    func reconcilePlaylists() throws {
        if usesDB { reconcileStockPlaylists() }
        try reconcileRockboxPlaylists()
        for removal in plan.playlistsToDelete {
            if let pid = removal.persistentID, let i = db.playlists.firstIndex(where: { $0.persistentId == pid && !$0.isMaster }) {
                db.playlists.remove(at: i)
                dbDirty = true
            }
            manifest.playlists[removal.serverID] = nil
            if let path = removal.m3uPath { pendingDeletes.append(path) }
            manifest.rockboxPlaylists[removal.serverID] = nil
            manifestDirty = true
        }
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

    /// `Playlists/<name>.m3u8` with paths relative to that folder.
    private func reconcileRockboxPlaylists() throws {
        let fm = FileManager.default
        for p in plan.desiredPlaylists {
            let present = p.songIDs.filter { manifest.rockboxEntries[$0] != nil }
            let paths = present.compactMap { manifest.rockboxEntries[$0]?.relativePath }
            let old = manifest.rockboxPlaylists[p.id]?.path
            let path = RockboxPaths.playlistPath(p.name)
            if paths.isEmpty {
                if let old { try? fm.removeItem(at: device.mountURL.appendingPathComponent(old)) }
                manifest.rockboxPlaylists[p.id] = nil
                manifestDirty = true
                continue
            }
            let url = device.mountURL.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(RockboxPaths.playlistContents(paths).utf8).write(to: url, options: .atomic)
            if let old, old != path { try? fm.removeItem(at: device.mountURL.appendingPathComponent(old)) }
            manifest.rockboxPlaylists[p.id] = .init(path: path, songIDs: present)
            manifestDirty = true
        }
    }
}
