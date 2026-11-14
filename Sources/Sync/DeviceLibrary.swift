import Device
import Foundation
import ITunesDB

public struct DeviceTrack: Sendable, Identifiable, Hashable {
    public let id: UInt32
    public let dbid: UInt64
    public let title, artist, album, albumArtist: String
    public let size: Int64
    public let lengthMs: UInt32
    public let trackNumber: UInt32
    public let discNumber: UInt32
    public let year: UInt32
    public let location: String
    /// Server song id when MusicSync put the track there.
    public let songID: String?

    public var isManaged: Bool { songID != nil }
    /// Album artist, else artist: the grouping artist.
    public var groupArtist: String { albumArtist.isEmpty ? artist : albumArtist }
}

public struct DeviceAlbum: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let artist: String
    public let year: UInt32
    public let tracks: [DeviceTrack]

    public var size: Int64 { tracks.reduce(0) { $0 + $1.size } }
    public var managedCount: Int { tracks.filter(\.isManaged).count }
    public var foreignCount: Int { tracks.count - managedCount }
}

public struct DevicePlaylist: Sendable, Hashable {
    public let persistentID: UInt64
    public let name: String
    public let trackIDs: [UInt32]
}

/// Read-only snapshot of what is on the iPod.
public struct DeviceLibrary: Sendable {
    public let name: String
    public let tracks: [DeviceTrack]
    public let albums: [DeviceAlbum]
    /// Without the master playlist.
    public let playlists: [DevicePlaylist]
    /// Rockbox files from the manifest that exist on disk.
    public let rockboxPaths: Set<String>
    public let dbids: Set<UInt64>

    public var totalSize: Int64 { tracks.reduce(0) { $0 + $1.size } }
    public var managedSize: Int64 { tracks.filter(\.isManaged).reduce(0) { $0 + $1.size } }
    public var foreignSize: Int64 { totalSize - managedSize }

    public init(db: ITunesDB, manifest: Manifest, rockboxPaths: Set<String> = []) {
        let songIDs = Dictionary(manifest.entries.map { ($0.value.dbid, $0.key) }) { a, _ in a }
        tracks = db.tracks.map {
            DeviceTrack(id: $0.id, dbid: $0.dbid, title: $0.title, artist: $0.artist, album: $0.album,
                        albumArtist: $0.albumArtist, size: Int64($0.size), lengthMs: $0.lengthMs,
                        trackNumber: $0.trackNumber, discNumber: $0.discNumber, year: $0.year,
                        location: $0.location, songID: songIDs[$0.dbid])
        }
        albums = Dictionary(grouping: tracks) { "\($0.groupArtist)\u{1F}\($0.album)" }.map { key, tracks in
            let sorted = tracks.sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
            return DeviceAlbum(id: key, name: sorted[0].album, artist: sorted[0].groupArtist,
                               year: sorted.map(\.year).max() ?? 0, tracks: sorted)
        }.sorted { ($0.artist.lowercased(), $0.name.lowercased()) < ($1.artist.lowercased(), $1.name.lowercased()) }
        playlists = db.playlists.dropFirst().map { DevicePlaylist(persistentID: $0.persistentId, name: $0.name, trackIDs: $0.trackIDs) }
        name = db.name
        self.rockboxPaths = rockboxPaths
        dbids = Set(db.tracks.map(\.dbid))
    }

    /// Parses the device database; an iPod without one gives an empty library.
    /// `cacheDirectory` keeps a Mac copy of the database (see `DeviceFileCache`); nil reads the device.
    public static func load(device: IPodDevice, manifest: Manifest,
                            cacheDirectory: URL? = DeviceFileCache.standardDirectory) throws -> DeviceLibrary {
        let fm = FileManager.default
        let db = fm.fileExists(atPath: device.iTunesDBURL.path)
            ? try ITunesDB.parse(cacheDirectory.map { try DeviceFileCache.iTunesDB(of: device, directory: $0) }
                ?? Data(contentsOf: device.iTunesDBURL)) : ITunesDB.empty(name: device.volumeName)
        let rockbox = Set(manifest.rockboxEntries.values.map(\.relativePath)
            .filter { fm.fileExists(atPath: device.mountURL.appendingPathComponent($0).path) })
        return DeviceLibrary(db: db, manifest: manifest, rockboxPaths: rockbox)
    }
}
