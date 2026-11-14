import Foundation
import Support

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
    }

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
