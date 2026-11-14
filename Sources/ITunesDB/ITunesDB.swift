import Foundation
import Support

/// An mhsd section this module does not interpret; re-emitted as read.
struct RawSection: Sendable, Equatable {
    var type: UInt32
    var data: Data
}

public struct ITunesDB: Sendable, Equatable {
    public var tracks: [Track]
    /// Master playlist first.
    public var playlists: [Playlist]
    /// The mhbd header bytes (unknown fields are preserved).
    public internal(set) var header: Data
    var sections: [RawSection]
    private var issuedID: UInt32 = 0

    init(tracks: [Track], playlists: [Playlist], header: Data, sections: [RawSection]) {
        self.tracks = tracks
        self.playlists = playlists
        self.header = header
        self.sections = sections
    }

    /// A new database holding only the master playlist.
    public static func empty(name: String) -> ITunesDB {
        var h = BinaryWriter()
        h.tag("mhbd"); h.u32(UInt32(Layout.headerLength)); h.zeros(Layout.headerLength - 8)
        h.patch(UInt32(1), at: 0x0C)
        h.patch(randomID(), at: 0x18)
        h.patch(UInt16(1), at: 0x20)
        h.patch(UInt16(0x656e), at: 0x46)
        h.patch(randomID(), at: 0x48)
        h.patch(Int32(TimeZone.current.secondsFromGMT()), at: 0x6C)
        return ITunesDB(tracks: [], playlists: [Playlist(name: name, isMaster: true)], header: h.data, sections: [])
    }

    enum Layout {
        static let headerLength = 0xF4
        static let version: UInt32 = 0x30
        static let firstTrackID: UInt32 = 52
    }

    /// Name of the master playlist (the iPod's name).
    public var name: String {
        get { playlists.first?.name ?? "" }
        set { if !playlists.isEmpty { playlists[0].name = newValue } }
    }

    /// Next free track id; stable across writes (`max(52, max + 1)`).
    public mutating func nextTrackID() -> UInt32 {
        issuedID = max(Layout.firstTrackID, (tracks.map(\.id).max() ?? 0) &+ 1, issuedID &+ 1)
        return issuedID
    }

    /// Adds a track (assigning id and dbid when 0) to the library and the master playlist.
    @discardableResult
    public mutating func addTrack(_ track: Track) -> UInt32 {
        var track = track
        if track.id == 0 { track.id = nextTrackID() }
        if track.dbid == 0 { track.dbid = randomID() }
        tracks.append(track)
        if !playlists.isEmpty { playlists[0].trackIDs.append(track.id) }
        return track.id
    }

    /// Removes a track from the library and from every playlist.
    public mutating func removeTrack(id: UInt32) { removeTracks(ids: [id]) }

    /// Removes tracks from the library and from every playlist, in one pass per list.
    public mutating func removeTracks(ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
    }
}
