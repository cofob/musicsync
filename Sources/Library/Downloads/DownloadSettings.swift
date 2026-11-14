import Foundation
import Subsonic
import Support

/// Settings > Downloads. Persisted by the app (UserDefaults key `downloadSettings`, JSON).
public struct DownloadSettings: Codable, Equatable, Sendable {
    /// Original file, or a server conversion. Opus is left out: AVFoundation cannot play Ogg files.
    public enum Quality: String, Codable, CaseIterable, Sendable {
        case original, aac, mp3
    }

    public var quality = Quality.original
    /// For converted files, in kbps.
    public var maxBitRate = 256
    /// New downloads stop above this size; 0 means no limit.
    public var storageLimitGB = 0.0
    /// Files downloaded at the same time.
    public var concurrency = 2

    public init() {}

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DownloadSettings()
        quality = try c.decodeIfPresent(Quality.self, forKey: .quality) ?? d.quality
        maxBitRate = try c.decodeIfPresent(Int.self, forKey: .maxBitRate) ?? d.maxBitRate
        storageLimitGB = try c.decodeIfPresent(Double.self, forKey: .storageLimitGB) ?? d.storageLimitGB
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? d.concurrency
    }

    public static let defaultsKey = "downloadSettings"

    public static func load(from defaults: UserDefaults = .app) -> DownloadSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(DownloadSettings.self, from: data) else { return DownloadSettings() }
        return value
    }

    public func save(to defaults: UserDefaults = .app) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    var limitBytes: Int64? { storageLimitGB > 0 ? Int64(storageLimitGB * 1_000_000_000) : nil }

    /// Suffixes AVFoundation plays; other originals are converted to mp3, as the player streams them.
    static let playableSuffixes: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff"]

    /// What to ask the server for one song.
    func plan(for song: Song) -> DownloadPlan {
        let suffix = (song.suffix ?? "").lowercased()
        switch quality {
        case .original where Self.playableSuffixes.contains(suffix):
            return DownloadPlan(format: nil, maxBitRate: nil, suffix: suffix, bitRate: song.bitRate)
        case .original: return DownloadPlan(format: "mp3", maxBitRate: 320, suffix: "mp3", bitRate: 320)
        case .aac: return DownloadPlan(format: "aac", maxBitRate: maxBitRate, suffix: "aac", bitRate: maxBitRate)
        case .mp3: return DownloadPlan(format: "mp3", maxBitRate: maxBitRate, suffix: "mp3", bitRate: maxBitRate)
        }
    }
}

/// Request parameters and the resulting file type of one download.
struct DownloadPlan: Equatable {
    var format: String?
    var maxBitRate: Int?
    var suffix: String
    var bitRate: Int?

    /// Expected file size, for the storage checks.
    func estimate(_ song: Song) -> Int64 {
        if format == nil, let size = song.size { return Int64(size) }
        return Int64(song.duration ?? 300) * Int64(bitRate ?? 320) * 125
    }
}
