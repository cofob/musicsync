import Foundation
import Transcode

public struct SyncPlan: Sendable, Equatable {
    public struct Removal: Sendable, Equatable {
        public var songID: String
        public var entry: Manifest.Entry
        public var target: Preset.Target
    }

    /// An existing managed song that changes.
    public struct Change: Sendable, Equatable {
        public var desired: DesiredSong
        public var entry: Manifest.Entry
    }

    public var add: [DesiredSong] = []
    public var remove: [Removal] = []
    /// New file, same track (id, dbid, play counts and playlists stay). Rockbox files are replaced.
    public var reencode: [Change] = []
    /// Database-only update.
    public var retag: [Change] = []
    /// Server rating (0-5) of present stock songs whose rating changed since the last sync, or was never synced.
    public var serverRatings: [String: Int] = [:]

    public var playlistsToCreate: [DesiredPlaylist] = []
    public var playlistsToUpdate: [DesiredPlaylist] = []
    /// All wanted playlists; the engine reconciles every one of them.
    public var desiredPlaylists: [DesiredPlaylist] = []
    /// Some playlist has stock tracks or an iPod playlist must go.
    public var playlistsTouchStock = false
    /// albumID -> cover art id of every wanted album.
    public var albumCovers: [String: String] = [:]
    /// albumID -> name of wanted albums skipped because iTunes/Finder already put them on the iPod.
    public var skippedForeignAlbums: [String: String] = [:]

    /// iTunesDB tracks (by dbid) the user deleted from the iPod, foreign or managed.
    public var deleteTracks: Set<UInt64> = []
    /// New iPod name, written into the iTunesDB.
    public var rename: String?

    public var addBytes: Int64 = 0
    public var freedBytes: Int64 = 0
    public var freeBytes: Int64 = 0
    public var reserveBytes: Int64 = SyncPlanner.reserveBytes

    /// Songs added to fill the space left (`Selection.fillMostPlayed`); also counted in `add`.
    public var filledSongs = 0

    public var fits: Bool { freeBytes + freedBytes - addBytes >= reserveBytes }

    /// Space the sync could still fill, beyond the reserve.
    public var spaceLeft: Int64 { freeBytes + freedBytes - addBytes - reserveBytes }

    public var transferCount: Int { add.count + reencode.count }

    public var isEmpty: Bool {
        add.isEmpty && remove.isEmpty && deleteTracks.isEmpty && reencode.isEmpty && retag.isEmpty && serverRatings.isEmpty
            && playlistsToCreate.isEmpty && playlistsToUpdate.isEmpty && rename == nil
    }

    /// True when the iTunesDB (and so the FireWire GUID) is needed.
    public var touchesStock: Bool {
        add.contains { $0.preset.target == .stock } || remove.contains { $0.target == .stock }
            || reencode.contains { $0.desired.preset.target == .stock } || !retag.isEmpty || !serverRatings.isEmpty
            || playlistsTouchStock || !deleteTracks.isEmpty || rename != nil
    }

    public init() {}
}
