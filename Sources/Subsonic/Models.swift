import Foundation

// All extra fields are optional: servers differ in what they send.

public struct Artist: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let albumCount: Int?
    public let coverArt: String?
    public let artistImageUrl: String?
    public let starred: String?
    public let musicBrainzId: String?
    public let sortName: String?
    /// Present in `getArtist` replies.
    public let album: [Album]?
}

public struct ArtistIndex: Codable, Hashable, Sendable {
    public let name: String
    public let artist: [Artist]?
}

public struct Album: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let artist: String?
    public let artistId: String?
    public let songCount: Int?
    public let duration: Int?
    public let year: Int?
    public let genre: String?
    public let coverArt: String?
    public let playCount: Int?
    public let starred: String?
    public let created: String?
    public let musicBrainzId: String?
    public let isCompilation: Bool?
    public let sortName: String?
    public let displayArtist: String?
    /// Last play date (OpenSubsonic `played`).
    public let played: String?
    /// Present in `getAlbum` replies.
    public let song: [Song]?
}

public struct ReplayGain: Codable, Hashable, Sendable {
    public let trackGain: Double?
    public let albumGain: Double?
    public let trackPeak: Double?
    public let albumPeak: Double?
    public let baseGain: Double?
    public let fallbackGain: Double?
}

public struct Song: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let parent: String?
    public let title: String
    public let album: String?
    public let albumId: String?
    public let artist: String?
    public let artistId: String?
    public let albumArtist: String?
    public let displayArtist: String?
    public let displayAlbumArtist: String?
    public let track: Int?
    public let discNumber: Int?
    public let year: Int?
    public let genre: String?
    public let size: Int?
    public let suffix: String?
    public let contentType: String?
    public let duration: Int?
    public let bitRate: Int?
    public let bitDepth: Int?
    public let samplingRate: Int?
    public let channelCount: Int?
    public let coverArt: String?
    public let playCount: Int?
    public let userRating: Int?
    public let starred: String?
    public let replayGain: ReplayGain?
    public let created: String?
    public let musicBrainzId: String?
    public let path: String?
}

public struct Playlist: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let comment: String?
    public let owner: String?
    public let isPublic: Bool?
    public let songCount: Int?
    public let duration: Int?
    public let created: String?
    public let changed: String?
    public let coverArt: String?
    /// Navidrome: true for smart playlists and playlists of other users.
    public let readonly: Bool?
    /// Smart playlists: the time their song list is rebuilt.
    public let validUntil: String?
    /// Present in `getPlaylist` replies.
    public let entry: [Song]?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, created, changed, coverArt, readonly, validUntil, entry
        case isPublic = "public"
    }
}

public struct SearchResult3: Codable, Hashable, Sendable {
    public let artist: [Artist]
    public let album: [Album]
    public let song: [Song]

    public init(artist: [Artist], album: [Album], song: [Song]) {
        self.artist = artist
        self.album = album
        self.song = song
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decodeIfPresent([Artist].self, forKey: .artist) ?? []
        album = try c.decodeIfPresent([Album].self, forKey: .album) ?? []
        song = try c.decodeIfPresent([Song].self, forKey: .song) ?? []
    }
}

public struct ScanStatus: Codable, Hashable, Sendable {
    public let scanning: Bool
    public let count: Int?
    public let folderCount: Int?
    public let lastScan: String?
    public let scanType: String?
}

public struct OpenSubsonicExtension: Codable, Hashable, Sendable {
    public let name: String
    public let versions: [Int]
}

public struct ServerInfo: Codable, Hashable, Sendable {
    public let version: String
    public let type: String?
    public let serverVersion: String?
    public let openSubsonic: Bool?
}

// MARK: - Helpers

public extension Song {
    /// Source format, e.g. "FLAC 24/96" for lossless or "MP3 320" for lossy.
    var sourceFormat: String {
        let name = (suffix ?? "?").uppercased()
        if let bits = bitDepth, bits > 0, let rate = samplingRate, rate > 0 {
            return "\(name) \(bits)/\(rate % 1000 == 0 ? "\(rate / 1000)" : String(format: "%.1f", Double(rate) / 1000))"
        }
        if let bitRate, bitRate > 0 { return "\(name) \(bitRate)" }
        return name
    }

    /// Artist shown for the track.
    var artistName: String? { displayArtist ?? artist }
}

public extension Album {
    /// Artist shown for the album.
    var artistName: String? { displayArtist ?? artist }
}


public extension Album {
    /// Copy of the album with its track list replaced.
    func withSongs(_ songs: [Song]?) -> Album {
        Album(id: id, name: name, artist: artist, artistId: artistId, songCount: songCount, duration: duration, year: year,
              genre: genre, coverArt: coverArt, playCount: playCount, starred: starred, created: created,
              musicBrainzId: musicBrainzId, isCompilation: isCompilation, sortName: sortName, displayArtist: displayArtist,
              played: played, song: songs)
    }
}

public extension Playlist {
    /// Copy of the playlist with its entries replaced.
    func withEntries(_ entries: [Song]?) -> Playlist {
        Playlist(id: id, name: name, comment: comment, owner: owner, isPublic: isPublic, songCount: songCount,
                 duration: duration, created: created, changed: changed, coverArt: coverArt, readonly: readonly,
                 validUntil: validUntil, entry: entries)
    }

    /// Copy with a new name and description, e.g. while a rename is sent.
    func renamed(_ name: String, comment: String?) -> Playlist {
        Playlist(id: id, name: name, comment: comment, owner: owner, isPublic: isPublic, songCount: songCount,
                 duration: duration, created: created, changed: changed, coverArt: coverArt, readonly: readonly,
                 validUntil: validUntil, entry: entry)
    }
}
