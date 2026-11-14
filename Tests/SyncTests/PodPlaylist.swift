import struct ITunesDB.Playlist

/// `Playlist` exists in both ITunesDB and Subsonic; tests use this name for the iTunesDB one.
typealias PodPlaylist = Playlist

extension PodPlaylist {
    init(persistentID: UInt64, name: String, trackIDs: [UInt32]) {
        self.init(name: name, trackIDs: trackIDs)
        persistentId = persistentID
    }
}
