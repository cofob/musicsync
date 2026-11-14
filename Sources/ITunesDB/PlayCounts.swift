import Foundation
import Support

/// One record of `iPod_Control/iTunes/Play Counts`; record `i` belongs to the `i`-th track of the database.
public struct PlayCountEntry: Sendable, Equatable {
    public var playCount: UInt32
    public var lastPlayed: Date?
    public var bookmark: UInt32
    /// Absent in old (12-byte) records.
    public var rating: UInt32?
    public var skipCount: UInt32
    public var lastSkipped: Date?

    public init(playCount: UInt32 = 0, lastPlayed: Date? = nil, bookmark: UInt32 = 0, rating: UInt32? = nil,
                skipCount: UInt32 = 0, lastSkipped: Date? = nil) {
        self.playCount = playCount; self.lastPlayed = lastPlayed; self.bookmark = bookmark
        self.rating = rating; self.skipCount = skipCount; self.lastSkipped = lastSkipped
    }
}

/// Plays reported by the iPod for one track, ready for scrobbling.
public struct PlayDelta: Sendable, Equatable {
    public var trackID: UInt32
    public var plays: UInt32
    public var lastPlayed: Date?
}

public struct PlayCounts: Sendable, Equatable {
    public var entries: [PlayCountEntry]

    public init(entries: [PlayCountEntry]) { self.entries = entries }

    /// Parses a `mhdp` file (record sizes 0x0C, 0x10, 0x14 or 0x1C).
    public static func parse(_ data: Data) throws -> PlayCounts {
        let r = BinaryReader(data)
        guard data.count >= 16, (try? r.tag(at: 0)) == "mhdp" else { throw ITunesDBError.corrupt("not a Play Counts file") }
        let headerLength = try r.int(4), size = try r.int(8), count = try r.int(12)
        guard size >= 0x0C else { throw ITunesDBError.corrupt("Play Counts record size \(size)") }
        guard count <= (data.count - headerLength) / size else { throw ITunesDBError.corrupt("Play Counts record count \(count)") }
        let entries = try (0..<count).map { i -> PlayCountEntry in
            let o = headerLength + i * size
            return PlayCountEntry(
                playCount: try r.u32(at: o), lastPlayed: MacTime.date(try r.u32(at: o + 4)), bookmark: try r.u32(at: o + 8),
                rating: size >= 0x10 ? try r.u32(at: o + 12) : nil,
                skipCount: size >= 0x1C ? try r.u32(at: o + 20) : 0,
                lastSkipped: size >= 0x1C ? MacTime.date(try r.u32(at: o + 24)) : nil)
        }
        return PlayCounts(entries: entries)
    }
}

extension ITunesDB {
    /// Folds iPod statistics into the tracks (libgpod rules). Call before any track is added or removed.
    /// Returns the tracks that were played since the last sync.
    @discardableResult
    public mutating func merge(_ playCounts: PlayCounts) -> [PlayDelta] {
        var deltas: [PlayDelta] = []
        for (i, entry) in playCounts.entries.enumerated() where i < tracks.count {
            if let rating = entry.rating { tracks[i].rating = UInt8(min(rating, 100)) }
            if let played = entry.lastPlayed { tracks[i].timePlayed = played }
            if entry.bookmark != 0 { tracks[i].bookmarkTime = entry.bookmark }
            tracks[i].playCount &+= entry.playCount
            tracks[i].skipCount &+= entry.skipCount
            if let skipped = entry.lastSkipped { tracks[i].lastSkipped = skipped }
            guard entry.playCount > 0 else { continue }
            tracks[i].markUnplayed = 1
            deltas.append(PlayDelta(trackID: tracks[i].id, plays: entry.playCount, lastPlayed: entry.lastPlayed))
        }
        return deltas
    }
}

/// `OTGPlaylistInfo*` files (`mhpo`): lists of track positions in the database.
public enum OTGPlaylists {
    public static func parse(_ data: Data) throws -> [UInt32] {
        let r = BinaryReader(data)
        guard data.count >= 16, (try? r.tag(at: 0)) == "mhpo" else { throw ITunesDBError.corrupt("not an OTG playlist file") }
        let headerLength = try r.int(4), size = try r.int(8), count = try r.int(12)
        guard size >= 4 else { throw ITunesDBError.corrupt("OTG record size \(size)") }
        guard count <= (data.count - headerLength) / size else { throw ITunesDBError.corrupt("OTG record count \(count)") }
        return try (0..<count).map { try r.u32(at: headerLength + $0 * size) }
    }
}

extension ITunesDB {
    /// Turns OTG position lists (indexes into `tracks`) into playlists. Call before tracks are added or removed.
    @discardableResult
    public mutating func addOTGPlaylists(_ lists: [[UInt32]], name: (Int) -> String = { "On-The-Go \($0 + 1)" }) -> [Playlist] {
        let added = lists.enumerated().compactMap { n, positions -> Playlist? in
            let ids = positions.compactMap { Int($0) < tracks.count ? tracks[Int($0)].id : nil }
            return ids.isEmpty ? nil : Playlist(name: name(n), trackIDs: ids)
        }
        playlists += added
        return added
    }
}
