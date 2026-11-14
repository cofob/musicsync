import Device
import Foundation
import ITunesDB
import Support

/// One track as shown in the iPod views.
struct DeviceTrack: Identifiable, Hashable, Sendable {
    let id: UInt32
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int
    let discNumber: Int
    let year: Int
    let duration: TimeInterval
    let plays: Int
    /// Stars, 0...5.
    let rating: Int
    let size: Int64
    /// e.g. "M4A · 256 kbps".
    let format: String
    /// Path relative to the volume root, e.g. `iPod_Control/Music/F07/ABCD.m4a`.
    let path: String
    /// ArtworkDB image id.
    let imageID: UInt32?
    let dbid: UInt64

    init(_ t: Track) {
        path = ITunesDB.relativePath(ipodLocation: t.location)
        let ext = (path as NSString).pathExtension.uppercased()
        id = t.id
        dbid = t.dbid
        title = t.title.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : t.title
        artist = t.artist
        album = t.album
        albumArtist = t.albumArtist
        trackNumber = Int(t.trackNumber)
        discNumber = Int(t.discNumber)
        year = Int(t.year)
        duration = TimeInterval(t.lengthMs) / 1000
        plays = Int(t.playCount)
        rating = Int(t.rating) / 20
        size = Int64(t.size)
        format = [ext.nilIfEmpty, t.bitrate > 0 ? "\(t.bitrate) kbps" : nil].compactMap { $0 }.joined(separator: " · ")
        imageID = t.hasArtwork && t.mhiiLink != 0 ? t.mhiiLink : nil
    }
}

/// Tracks grouped by album + (album artist or artist).
struct DeviceAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let year: Int?
    let tracks: [DeviceTrack]
    let imageID: UInt32?

    var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }

    static func group(_ tracks: [DeviceTrack]) -> [DeviceAlbum] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let groups = Dictionary(grouping: tracks) { t in
            fold(t.album) + "\u{1}" + fold(t.albumArtist.isEmpty ? t.artist : t.albumArtist)
        }
        return groups.map { key, group in
            let sorted = group.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
            let first = sorted[0]
            return DeviceAlbum(
                id: key, name: first.album, artist: first.albumArtist.isEmpty ? first.artist : first.albumArtist,
                year: sorted.map(\.year).filter { $0 > 0 }.min(), tracks: sorted,
                imageID: sorted.lazy.compactMap(\.imageID).first)
        }
        .sorted {
            let order = $0.artist.localizedStandardCompare($1.artist)
            return order == .orderedSame ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : order == .orderedAscending
        }
    }
}

struct DevicePlaylist: Identifiable, Hashable, Sendable {
    /// Index in the database; stable until the next reload.
    let id: Int
    let name: String
    let tracks: [DeviceTrack]

    var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
}

/// Everything read from the iPod in one pass.
struct DeviceSnapshot: Sendable {
    struct Capacity: Sendable { let total: Int64; let available: Int64 }
    struct Orphans: Sendable { let count: Int; let bytes: Int64 }

    let device: IPodDevice
    var name: String
    var modelName: String?
    var firmware: String?
    var serial: String?
    /// Resolved FirewireGuid; nil = not found.
    var guid: String?
    var rockbox = false
    var capacity: Capacity?
    /// Parsed database; nil when missing or corrupt (see `error`).
    var database: ITunesDB?
    var tracks: [DeviceTrack] = []
    var albums: [DeviceAlbum] = []
    var playlists: [DevicePlaylist] = []
    var musicBytes: Int64 = 0
    /// Files in `Music/Fxx` that no track references; nil when unknown.
    var orphans: Orphans?
    var artwork: DeviceArtwork?
    var error: String?

    /// Blocking; call off the main actor.
    static func load(_ device: IPodDevice, manualGuid: String?) -> DeviceSnapshot {
        var s = DeviceSnapshot(device: device, name: device.volumeName)
        s.modelName = device.modelName ?? device.sysInfo?.modelNumStr
            ?? IPodDevice.modelName(usbProductID: FirewireGuid.usbProductID(forVolume: device.mountURL),
                                    capacityBytes: (try? device.capacity())?.total)
        let extended = device.sysInfoExtended
        s.firmware = device.sysInfo?.visibleBuildID ?? extended?.visibleBuildID
        s.serial = device.sysInfo?.serialNumber ?? extended?.serialNumber
        s.guid = FirewireGuid.resolveString(for: device, manualOverride: manualGuid)
        s.rockbox = device.isRockboxInstalled
        s.capacity = (try? device.capacity()).map { Capacity(total: $0.total, available: $0.available) }

        guard FileManager.default.fileExists(atPath: device.iTunesDBURL.path) else {
            s.error = "This iPod has no iTunesDB yet."
            return s
        }
        do {
            let db = try ITunesDB.parse(DeviceFileCache.iTunesDB(of: device))
            s.database = db
            if !db.name.isEmpty { s.name = db.name }
            let all = db.tracks.map(DeviceTrack.init)
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            s.tracks = all
            s.albums = DeviceAlbum.group(all)
            s.playlists = db.playlists.enumerated().filter { !$0.element.isMaster }.map { i, p in
                DevicePlaylist(id: i, name: p.name, tracks: p.trackIDs.compactMap { byID[$0] })
            }
            s.musicBytes = all.reduce(0) { $0 + $1.size }
            // Orphans are found on demand (`DeviceModel.scanOrphans`): listing 50 folders is slow on the iPod disk.
            s.artwork = DeviceArtwork(directory: device.artworkDir,
                                      cacheDirectory: Paths.caches("ipod-artwork", device.volumeUUID ?? device.volumeName))
        } catch {
            s.error = "Cannot read the iTunesDB: \(error.localizedDescription)"
        }
        return s
    }
}
