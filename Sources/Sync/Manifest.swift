import Device
import Foundation
import Subsonic
import Support

/// What MusicSync put on a device. Lives at `iPod_Control/MusicSync/manifest.json` and travels with the iPod.
public struct Manifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Entry: Codable, Sendable, Equatable {
        /// 0 for Rockbox files.
        public var dbid: UInt64
        public var trackID: UInt32
        /// Relative to the volume root, `/`-separated.
        public var relativePath: String
        public var presetID: String
        public var presetVersion: Int
        public var albumID: String
        public var sourceSize: Int?
        public var sourceSuffix: String?
        public var sourceCreated: String?
        public var outSize: Int64
        public var fingerprint: String
        public var title: String?
    }

    public struct RockboxPlaylist: Codable, Sendable, Equatable {
        public var path: String
        /// Songs the file lists, in order.
        public var songIDs: [String]
    }

    public var version = Manifest.currentVersion
    public var serverKey = ""
    /// Stock tracks (in the iTunesDB), keyed by song id.
    public var entries: [String: Entry] = [:]
    /// Rockbox files, keyed by song id.
    public var rockboxEntries: [String: Entry] = [:]
    /// Server playlist id -> iTunesDB playlist persistent id.
    public var playlists: [String: UInt64] = [:]
    /// Server playlist id -> the `.m3u8` written for it.
    public var rockboxPlaylists: [String: RockboxPlaylist] = [:]
    /// Album id -> ArtworkDB image id.
    public var artwork: [String: UInt32] = [:]
    public var lastSync: Date?

    public init(serverKey: String = "") { self.serverKey = serverKey }

    /// Song id of the stock track with this dbid.
    func songID(dbid: UInt64) -> String? { entries.first { $0.value.dbid == dbid }?.key }
}

public extension SubsonicClient {
    /// Identifies the account songs ids belong to.
    var serverKey: String {
        var url = baseURL.absoluteString
        while url.hasSuffix("/") { url.removeLast() }
        return "\(url)|\(username)"
    }
}

public enum ManifestStore {
    public static func url(for device: IPodDevice) -> URL { device.musicSyncDir.appendingPathComponent("manifest.json") }

    /// Missing, corrupt or foreign-server manifests give an empty one plus a warning.
    /// Tracks the manifest does not know are never touched, so nothing is lost.
    public static func load(for device: IPodDevice, serverKey: String) -> (manifest: Manifest, warning: String?) {
        let url = url(for: device)
        guard let data = try? Data(contentsOf: url) else { return (Manifest(serverKey: serverKey), nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data), manifest.version <= Manifest.currentVersion else {
            try? data.write(to: url.appendingPathExtension("corrupt"))
            return (Manifest(serverKey: serverKey), "The sync manifest is unreadable. Existing tracks are treated as foreign.")
        }
        if !manifest.serverKey.isEmpty, manifest.serverKey != serverKey {
            return (Manifest(serverKey: serverKey),
                    "The iPod was synced from another server or account. Existing tracks are treated as foreign.")
        }
        var result = manifest
        result.serverKey = serverKey
        return (result, nil)
    }

    public static func save(_ manifest: Manifest, for device: IPodDevice) throws {
        try FileManager.default.createDirectory(at: device.musicSyncDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.atomicWrite(try encoder.encode(manifest), to: url(for: device))
    }
}
