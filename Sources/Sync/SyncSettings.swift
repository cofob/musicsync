import Foundation
import Support
import Transcode

/// User-tunable sync options. Persisted by the app (UserDefaults key `syncSettings`, JSON).
public struct SyncSettings: Codable, Sendable, Equatable {
    public enum SoundCheckSource: String, Codable, Sendable, CaseIterable {
        case album, track, off
    }

    /// Default preset id for new devices (see `Preset.builtIns`).
    public var presetID: String = "stock-aac"
    /// ffmpeg binary or its directory; nil = auto-detect.
    public var ffmpegPath: String?
    /// Parallel download/transcode workers.
    public var workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    public var soundCheck: SoundCheckSource = .album
    public var ejectAfterSync: Bool = false
    /// Sync whole albums: songs of selected playlists bring their albums too.
    public var fullAlbums: Bool = false
    /// Puts the server's lyrics into new stock iPod files.
    public var lyrics: Bool = true
    /// Lossless songs for the stock iPod come from the server already converted to AAC (less to download).
    public var serverConversion: Bool = false
    /// Manual FirewireGuid per volume UUID (for test images or failed detection).
    public var manualGuids: [String: String] = [:]
    /// Bitrates of the AAC and Opus presets, in kbps. Songs already on the iPod keep theirs.
    public var aacBitrate = 256
    public var opusBitrate = 128
    /// Space a sync leaves free on the iPod, in GB.
    public var keepFreeGB = 0.5
    /// Syncs by itself when an iPod connects and there are changes.
    public var autoSync = false
    /// Sends plays from the iPod's Play Counts to the server (scrobbles).
    public var sendPlayCounts = true
    /// Edge of the Rockbox `cover.jpg` in pixels.
    public var rockboxCoverSize = 500
    /// iPod name per volume UUID; a sync writes it into the iTunesDB.
    public var deviceNames: [String: String] = [:]

    public init() {}

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? presetID
        ffmpegPath = try c.decodeIfPresent(String.self, forKey: .ffmpegPath)
        workers = try c.decodeIfPresent(Int.self, forKey: .workers) ?? workers
        soundCheck = try c.decodeIfPresent(SoundCheckSource.self, forKey: .soundCheck) ?? soundCheck
        ejectAfterSync = try c.decodeIfPresent(Bool.self, forKey: .ejectAfterSync) ?? ejectAfterSync
        fullAlbums = try c.decodeIfPresent(Bool.self, forKey: .fullAlbums) ?? fullAlbums
        lyrics = try c.decodeIfPresent(Bool.self, forKey: .lyrics) ?? lyrics
        serverConversion = try c.decodeIfPresent(Bool.self, forKey: .serverConversion) ?? serverConversion
        manualGuids = try c.decodeIfPresent([String: String].self, forKey: .manualGuids) ?? manualGuids
        aacBitrate = try c.decodeIfPresent(Int.self, forKey: .aacBitrate) ?? aacBitrate
        opusBitrate = try c.decodeIfPresent(Int.self, forKey: .opusBitrate) ?? opusBitrate
        keepFreeGB = try c.decodeIfPresent(Double.self, forKey: .keepFreeGB) ?? keepFreeGB
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? autoSync
        sendPlayCounts = try c.decodeIfPresent(Bool.self, forKey: .sendPlayCounts) ?? sendPlayCounts
        rockboxCoverSize = try c.decodeIfPresent(Int.self, forKey: .rockboxCoverSize) ?? rockboxCoverSize
        deviceNames = try c.decodeIfPresent([String: String].self, forKey: .deviceNames) ?? deviceNames
    }

    /// The built-in presets with the chosen bitrates.
    public var presets: [Preset] {
        Preset.builtIns.map { preset in
            var preset = preset
            switch preset.codec {
            case .aac(.cvbr): preset.codec = .aac(.cvbr(bitrateKbps: aacBitrate))
            case .opus: preset.codec = .opus(bitrateKbps: opusBitrate)
            default: break
            }
            return preset
        }
    }

    public var reserveBytes: Int64 { Int64(max(0, keepFreeGB) * 1_000_000_000) }

    public static let defaultsKey = "syncSettings"

    public static func load(from defaults: UserDefaults = .app) -> SyncSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(SyncSettings.self, from: data) else { return SyncSettings() }
        return value
    }

    public func save(to defaults: UserDefaults = .app) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
