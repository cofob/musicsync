import Foundation

/// Original chunks of a playlist read from an existing database.
struct RawPlaylist: Sendable, Equatable {
    var header: Data
    /// Child mhods other than the name and the master sort indexes (prefs, smart rules, ...).
    var mhods: [Data]
    /// The playlist's `mhyp` as stored in the podcast section (mhsd type 3), if it is a podcast list.
    var podcastForm: Data?
}

public struct Playlist: Sendable, Equatable {
    public var persistentId: UInt64
    public var name: String
    public var isMaster: Bool
    public var trackIDs: [UInt32]
    public var timestamp: Date?
    var raw: RawPlaylist?

    public init(name: String, trackIDs: [UInt32] = [], isMaster: Bool = false) {
        persistentId = randomID()
        self.name = name
        self.isMaster = isMaster
        self.trackIDs = trackIDs
        timestamp = Date()
    }
}
