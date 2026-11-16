import Artwork
import Foundation
import ITunesDB

extension SyncJob {
    /// Loads manifest, databases and play statistics; drops manifest entries the device no longer has.
    func readDevice() async throws {
        let loaded = try ManifestStore.read(for: device, serverKey: client.serverKey)
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
            await mergeRatings()
            if let name = plan.rename, db.name != name {
                db.name = name
                dbDirty = true
            }
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
                    if settings.sendPlayCounts { await scrobbler.enqueue(scrobbleRequests(deltas), source: data) }
                } else {
                    warn("Play Counts does not match the database (\(counts.entries.count) vs \(db.tracks.count) tracks), discarded with the On-The-Go playlists. A copy is kept in the Mac backup.")
                    return
                }
            } catch { warn("Play Counts is unreadable, discarded (a copy is kept in the Mac backup): \(error)") }
        }
        let files = names.filter { $0.hasPrefix("OTGPlaylistInfo") }.sorted()
            .compactMap { try? Data(contentsOf: device.iTunesDir.appendingPathComponent($0)) }
        let lists = files.compactMap { try? OTGPlaylists.parse($0) }
        let day = Date().formatted(.iso8601.year().month().day())
        let name = { (n: Int) in lists.count > 1 ? "On-The-Go \(day) #\(n + 1)" : "On-The-Go \(day)" }
        await sendOnTheGo(lists, name: name, source: files.reduce(Data(), +))
        db.addOTGPlaylists(lists, name: name)
    }

    /// On-The-Go songs become server stars and playlists, as the settings say.
    private func sendOnTheGo(_ lists: [[UInt32]], name: (Int) -> String, source: Data) async {
        let songs = songIDsByDbid()
        let ids = lists.map { $0.compactMap { Int($0) < db.tracks.count ? songs[db.tracks[Int($0)].dbid] : nil } }
        let stars = settings.starSource == .onTheGo ? Dictionary(ids.joined().map { ($0, true) }) { a, _ in a } : [:]
        let playlists = settings.uploadOnTheGo
            ? ids.enumerated().filter { !$0.element.isEmpty }.map { PendingPlaylist(name: name($0.offset), songIDs: $0.element) } : []
        guard !stars.isEmpty || !playlists.isEmpty else { return }
        await scrobbler.enqueue(stars: stars, playlists: playlists, source: source)
    }

    private func songIDsByDbid() -> [UInt64: String] {
        Dictionary(manifest.entries.map { ($0.value.dbid, $0.key) }) { a, _ in a }
    }

    /// Three-way rating merge against the rating of the last sync: a change on the iPod wins and goes to the server,
    /// else a change on the server goes to the iPod.
    private func mergeRatings() async {
        let index = Dictionary(db.tracks.indices.map { (db.tracks[$0].dbid, $0) }) { a, _ in a }
        var ratings: [String: Int] = [:], stars: [String: Bool] = [:]
        for (id, var entry) in manifest.entries {
            guard let i = index[entry.dbid], let server = plan.serverRatings[id] ?? entry.rating else { continue }
            // Never synced: an unrated iPod track takes the server rating, a rated one wins.
            let ipod = Int(db.tracks[i].rating) / 20, base = entry.rating ?? (ipod == 0 ? 0 : server)
            if ipod != base {
                if settings.syncRatings, ipod != server { ratings[id] = ipod }
                if settings.starSource == .fiveStars, ipod == 5 || entry.rating == 5 { stars[id] = ipod == 5 }
                entry.rating = ipod
            } else if settings.syncRatings, server != ipod {
                db.tracks[i].rating = UInt8(server * 20)
                entry.rating = server
                dbDirty = true
            } else {
                entry.rating = ipod
            }
            guard entry != manifest.entries[id] else { continue }
            manifest.entries[id] = entry
            manifestDirty = true
        }
        if !ratings.isEmpty || !stars.isEmpty { await scrobbler.enqueue(ratings: ratings, stars: stars) }
    }

    static let statsFiles: Set<String> = ["Play Counts", "iTunesStats", "PlayCounts.plist"]

    /// N plays of a managed track become N timestamps, one track length apart.
    private func scrobbleRequests(_ deltas: [PlayDelta]) -> [ScrobbleRequest] {
        let tracks = Dictionary(db.tracks.map { ($0.id, $0) }) { a, _ in a }
        let songs = songIDsByDbid()
        return deltas.flatMap { delta -> [ScrobbleRequest] in
            guard let track = tracks[delta.trackID], let songID = songs[track.dbid] else { return [] }
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
