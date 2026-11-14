import Artwork
import Foundation
import ITunesDB

extension SyncJob {
    /// Loads manifest, databases and play statistics; drops manifest entries the device no longer has.
    func readDevice() async throws {
        let loaded = ManifestStore.load(for: device, serverKey: client.serverKey)
        manifest = loaded.manifest
        committed = loaded.manifest
        if let warning = loaded.warning { warn(warning) }

        if usesDB {
            let url = device.iTunesDBURL
            if FileManager.default.fileExists(atPath: url.path) {
                do { db = try ITunesDB.parse(Data(contentsOf: url)) } catch { throw SyncError.databaseUnreadable("\(error)") }
            } else {
                db = ITunesDB.empty(name: device.volumeName)
            }
            do { artworkDB = try ArtworkDB.load(artworkDirectory: device.artworkDir) } catch {
                warn("ArtworkDB is unreadable, covers are skipped: \(error)")
            }
            await mergePlayStatistics()
            pruneStale()
        }
        let fm = FileManager.default
        for (id, entry) in manifest.rockboxEntries where !fm.fileExists(atPath: device.mountURL.appendingPathComponent(entry.relativePath).path) {
            manifest.rockboxEntries[id] = nil
            manifestDirty = true
        }
    }

    /// Play Counts and On-The-Go lists go into the database first, before any track is added or removed.
    private func mergePlayStatistics() async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: device.iTunesDir.path)) ?? []
        guard Self.hasPlayStatistics(device) else { return }
        statsFilesPending = true
        dbDirty = true

        if let data = try? Data(contentsOf: device.playCountsURL) {
            do {
                let counts = try PlayCounts.parse(data)
                if counts.entries.count == db.tracks.count {
                    let deltas = db.merge(counts)
                    await scrobbler.enqueue(scrobbleRequests(deltas), source: data)
                } else {
                    warn("Play Counts does not match the database (\(counts.entries.count) vs \(db.tracks.count) tracks), discarded. A copy is kept in the Mac backup.")
                }
            } catch { warn("Play Counts is unreadable, discarded (a copy is kept in the Mac backup): \(error)") }
        }
        let lists = names.filter { $0.hasPrefix("OTGPlaylistInfo") }.sorted().compactMap { name in
            (try? Data(contentsOf: device.iTunesDir.appendingPathComponent(name))).flatMap { try? OTGPlaylists.parse($0) }
        }
        let day = Date().formatted(.iso8601.year().month().day())
        db.addOTGPlaylists(lists) { lists.count > 1 ? "On-The-Go \(day) #\($0 + 1)" : "On-The-Go \(day)" }
    }

    static let statsFiles: Set<String> = ["Play Counts", "iTunesStats", "PlayCounts.plist"]

    /// N plays of a managed track become N timestamps, one track length apart.
    private func scrobbleRequests(_ deltas: [PlayDelta]) -> [ScrobbleRequest] {
        let tracks = Dictionary(db.tracks.map { ($0.id, $0) }) { a, _ in a }
        return deltas.flatMap { delta -> [ScrobbleRequest] in
            guard let track = tracks[delta.trackID], let songID = manifest.songID(dbid: track.dbid) else { return [] }
            return Scrobbler.timestamps(plays: Int(delta.plays), lastPlayed: delta.lastPlayed, duration: Double(track.lengthMs) / 1000)
                .map { ScrobbleRequest(songID: songID, time: $0) }
        }
    }

    /// Entries whose track or artwork vanished from the device. The next plan re-adds the songs.
    private func pruneStale() {
        let dbids = Set(db.tracks.map(\.dbid))
        for (id, entry) in manifest.entries where !dbids.contains(entry.dbid) {
            manifest.entries[id] = nil
            manifestDirty = true
        }
        let persistent = Set(db.playlists.map(\.persistentId))
        for (id, pid) in manifest.playlists where !persistent.contains(pid) {
            manifest.playlists[id] = nil
            manifestDirty = true
        }
        if let artworkDB {
            let images = Set(artworkDB.images.map(\.id))
            for (id, image) in manifest.artwork where !images.contains(image) {
                manifest.artwork[id] = nil
                manifestDirty = true
            }
        }
    }

    // MARK: Removal and retagging

    func removeAndRetag() {
        var stock = Set<UInt64>()
        for removal in plan.remove {
            switch removal.target {
            case .stock:
                manifest.entries[removal.songID] = nil
                stock.insert(removal.entry.dbid)
            case .rockbox:
                manifest.rockboxEntries[removal.songID] = nil
                pendingDeletes.append(removal.entry.relativePath)
            }
            manifestDirty = true
            summary.removed += 1
        }
        let doomed = db.tracks.filter { stock.contains($0.dbid) || plan.deleteTracks.contains($0.dbid) }
        for track in doomed {
            pendingDeletes.append(ITunesDB.relativePath(ipodLocation: track.location))
            if !stock.contains(track.dbid) { summary.removed += 1 }
        }
        if !doomed.isEmpty {
            db.removeTracks(ids: Set(doomed.map(\.id)))
            dbDirty = true
        }
        for (id, entry) in manifest.entries where plan.deleteTracks.contains(entry.dbid) {
            manifest.entries[id] = nil
            manifestDirty = true
        }
        let index = Dictionary(db.tracks.indices.map { (db.tracks[$0].dbid, $0) }) { a, _ in a }
        for change in plan.retag {
            guard let i = index[change.entry.dbid],
                  var entry = manifest.entries[change.desired.id] else { continue }
            TrackBuilder.applyTags(change.desired, to: &db.tracks[i])
            entry.fingerprint = change.desired.fingerprint
            entry.title = change.desired.tags.title
            manifest.entries[change.desired.id] = entry
            dbDirty = true
            summary.retagged += 1
        }
    }
}
