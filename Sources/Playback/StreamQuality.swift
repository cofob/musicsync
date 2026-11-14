import Subsonic

/// Original file, or a server conversion. Opus is left out: AVFoundation cannot play Ogg files.
public enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case original, aac, mp3
}

/// Parameters of one `stream` request.
public struct StreamRequest: Equatable, Sendable {
    /// "raw" for the original file, else the conversion format.
    public var format: String
    public var maxBitRate: Int?
    /// Stream URLs have no file extension; AVFoundation is told the type.
    public var contentType: String?

    public init(format: String, maxBitRate: Int? = nil, contentType: String? = nil) {
        self.format = format
        self.maxBitRate = maxBitRate
        self.contentType = contentType
    }

    public var isConverted: Bool { format != "raw" }

    /// "Original", "AAC 256 kbps".
    public var title: String {
        isConverted ? [format.uppercased(), maxBitRate.map { "\($0) kbps" }].compactMap { $0 }.joined(separator: " ") : "Original"
    }
}

public extension PlaybackSettings {
    /// Suffixes AVFoundation plays; other originals are converted to mp3.
    static let playableSuffixes: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff"]

    /// The settings to stream with: on a metered network the metered quality, when one is set.
    func network(metered: Bool) -> PlaybackSettings {
        guard metered, let meteredQuality else { return self }
        var settings = self
        settings.quality = meteredQuality
        settings.maxBitRate = meteredMaxBitRate
        return settings
    }

    /// What to stream for `song`. `fallback` is set after the first choice failed to play: mp3 then.
    func stream(for song: Song, fallback: Bool = false) -> StreamRequest {
        let playable = Self.playableSuffixes.contains((song.suffix ?? "").lowercased())
        switch quality {
        case .original where playable && !fallback: return StreamRequest(format: "raw", contentType: song.contentType)
        case .aac where !fallback: return StreamRequest(format: "aac", maxBitRate: maxBitRate, contentType: "audio/aac")
        case .original: return StreamRequest(format: "mp3", maxBitRate: 320, contentType: "audio/mpeg")
        case .aac, .mp3: return StreamRequest(format: "mp3", maxBitRate: maxBitRate, contentType: "audio/mpeg")
        }
    }
}
