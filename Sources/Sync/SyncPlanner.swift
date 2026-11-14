import Foundation
import Transcode

public struct PlannerInput: Sendable {
    public var desired: [DesiredSong]
    public var playlists: [DesiredPlaylist]
    public var manifest: Manifest
    public var library: DeviceLibrary
    public var freeBytes: Int64

    public init(desired: [DesiredSong], playlists: [DesiredPlaylist] = [], manifest: Manifest,
                library: DeviceLibrary, freeBytes: Int64) {
        self.desired = desired
        self.playlists = playlists
        self.manifest = manifest
        self.library = library
        self.freeBytes = freeBytes
    }
}

/// Pure diff of what is wanted against what MusicSync already put on the device.
/// Sync only adds and updates: songs and playlists that are no longer selected stay on the device.
/// Deleting is an explicit action (`SyncPlan.deleteTracks`); the selection lives on the Mac, so an empty one
/// (new Mac, fresh install) must not empty the iPod.
public enum SyncPlanner {
    public static let reserveBytes: Int64 = 500_000_000

    public static func plan(_ input: PlannerInput) -> SyncPlan {
        var plan = SyncPlan()
        plan.freeBytes = input.freeBytes
        let manifest = input.manifest
        let library = input.library

        /// Entries whose track or file is really on the device. Stale ones are ignored.
        func present(_ id: String) -> (Manifest.Entry, Preset.Target)? {
            if let e = manifest.entries[id], library.dbids.contains(e.dbid) { return (e, .stock) }
            if let e = manifest.rockboxEntries[id], library.rockboxPaths.contains(e.relativePath) { return (e, .rockbox) }
            return nil
        }

        var seen = Set<String>()
        let desired = input.desired.filter { seen.insert($0.id).inserted }
        let skipped = foreignAlbums(desired, library: library) { present($0) != nil }
        for d in desired {
            if !d.albumID.isEmpty { plan.albumCovers[d.albumID] = d.coverArtID ?? plan.albumCovers[d.albumID] }
            guard let (entry, target) = present(d.id) else {
                if skipped.contains(d.albumID) { plan.skippedForeignAlbums[d.albumID] = d.tags.album } else { plan.add.append(d) }
                continue
            }
            if target != d.preset.target {
                plan.remove.append(.init(songID: d.id, entry: entry, target: target))
                plan.add.append(d)
            } else if needsReencode(entry, d) || (target == .rockbox && entry.fingerprint != d.fingerprint) {
                plan.reencode.append(.init(desired: d, entry: entry))
            } else if entry.fingerprint != d.fingerprint {
                plan.retag.append(.init(desired: d, entry: entry))
            }
        }

        plan.addBytes = (plan.add + plan.reencode.map(\.desired)).reduce(0) { $0 + SizeEstimate.bytes($1) }
        plan.freedBytes = plan.remove.reduce(0) { $0 + $1.entry.outSize } + plan.reencode.reduce(0) { $0 + $1.entry.outSize }
        let stock = desired.filter { $0.preset.target == .stock && !skipped.contains($0.albumID) }
        let rockbox = desired.filter { $0.preset.target == .rockbox }
        planPlaylists(&plan, input, stockSongs: Set(stock.map(\.id)), rockboxSongs: Set(rockbox.map(\.id)))
        return plan
    }

    /// Wanted albums with no managed track that iTunes/Finder already put on the device.
    /// Syncing them would make duplicates, so they are skipped.
    static func foreignAlbums(_ desired: [DesiredSong], library: DeviceLibrary, isPresent: (String) -> Bool) -> Set<String> {
        let foreign = Matcher.foreignAlbums(library)
        guard !foreign.isEmpty else { return [] }
        return Set(Dictionary(grouping: desired, by: \.albumID).compactMap { id, songs in
            guard !id.isEmpty, !songs.contains(where: { isPresent($0.id) }) else { return nil }
            let t = songs[0].tags
            let artist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
            return Matcher.isForeign(foreign, artist: artist, album: t.album, songCount: songs.count) ? id : nil
        })
    }

    static func needsReencode(_ e: Manifest.Entry, _ d: DesiredSong) -> Bool {
        func changed<T: Equatable>(_ old: T?, _ new: T?) -> Bool { old != nil && new != nil && old != new }
        return e.presetID != d.preset.id || e.presetVersion != d.preset.version
            || changed(e.sourceSize, d.song.size)
            || changed(e.sourceSuffix?.lowercased(), d.song.suffix?.lowercased())
            || changed(e.sourceCreated, d.song.created)
    }

    private static func planPlaylists(_ plan: inout SyncPlan, _ input: PlannerInput, stockSongs: Set<String>, rockboxSongs: Set<String>) {
        let manifest = input.manifest
        let current = Dictionary(input.library.playlists.map { ($0.persistentID, $0) }) { a, _ in a }
        let songByTrackID = Dictionary(manifest.entries.map { ($0.value.trackID, $0.key) }) { a, _ in a }
        plan.desiredPlaylists = input.playlists
        let paths = RockboxPaths.playlistPaths(for: input.playlists, recorded: manifest.rockboxPlaylists)
        plan.playlistsTouchStock = !manifest.playlists.isEmpty
            || input.playlists.contains { $0.songIDs.contains(where: stockSongs.contains) }
        for p in input.playlists {
            let wanted = p.songIDs.filter(stockSongs.contains)
            let rockbox = p.songIDs.filter(rockboxSongs.contains)
            if wanted.isEmpty && rockbox.isEmpty { continue }
            let existing = manifest.playlists[p.id].flatMap { current[$0] }
            let record = manifest.rockboxPlaylists[p.id]
            let isNew = (!wanted.isEmpty && existing == nil) || (wanted.isEmpty && record == nil)
            let stockChanged = existing.map { $0.name != p.name || $0.trackIDs.compactMap { songByTrackID[$0] } != wanted } ?? false
            let rockboxChanged = record.map { $0.songIDs != rockbox || $0.path != paths[p.id] } ?? !rockbox.isEmpty
            if isNew { plan.playlistsToCreate.append(p) } else if stockChanged || rockboxChanged { plan.playlistsToUpdate.append(p) }
        }
    }
}
