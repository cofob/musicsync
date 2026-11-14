import Foundation
import Support

/// Settings > Playback. Persisted by the app (UserDefaults key `playbackSettings`, JSON).
public struct PlaybackSettings: Codable, Equatable, Sendable {
    public enum SoundCheck: String, Codable, CaseIterable, Sendable {
        case off, track, album
    }

    /// How one song goes into the next. Off plays songs gapless; AutoMix blends them on the beat.
    public enum Transitions: String, Codable, CaseIterable, Sendable {
        case off, crossfade, autoMix
    }

    public var transitions = Transitions.off
    /// Length of the crossfade, 1–12 s.
    public var crossfadeSeconds = 6.0
    public var soundCheck = SoundCheck.off
    /// Added to the ReplayGain value, in dB.
    public var preAmp = 0.0
    /// Lowers the gain so that the song's peak stays below full scale.
    public var preventClipping = true
    public var quality = StreamQuality.original
    /// For converted streams, in kbps.
    public var maxBitRate = 256
    /// Seeks in converted streams with a new stream from that time (OpenSubsonic `transcodeOffset`).
    public var transcodeOffset = true
    /// Playback rate, 0.5–2; the pitch stays.
    public var speed = 1.0

    public init() {}

    /// Before AutoMix, transitions were a crossfade switch.
    private enum OldKeys: CodingKey { case crossfade }

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlaybackSettings()
        let crossfade = try decoder.container(keyedBy: OldKeys.self).decodeIfPresent(Bool.self, forKey: .crossfade)
        transitions = try c.decodeIfPresent(Transitions.self, forKey: .transitions)
            ?? crossfade.map { $0 ? .crossfade : .off } ?? d.transitions
        crossfadeSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? d.crossfadeSeconds
        soundCheck = try c.decodeIfPresent(SoundCheck.self, forKey: .soundCheck) ?? d.soundCheck
        preAmp = try c.decodeIfPresent(Double.self, forKey: .preAmp) ?? d.preAmp
        preventClipping = try c.decodeIfPresent(Bool.self, forKey: .preventClipping) ?? d.preventClipping
        quality = try c.decodeIfPresent(StreamQuality.self, forKey: .quality) ?? d.quality
        maxBitRate = try c.decodeIfPresent(Int.self, forKey: .maxBitRate) ?? d.maxBitRate
        transcodeOffset = try c.decodeIfPresent(Bool.self, forKey: .transcodeOffset) ?? d.transcodeOffset
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
    }

    public static let defaultsKey = "playbackSettings"

    public static func load(from defaults: UserDefaults = .app) -> PlaybackSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else { return PlaybackSettings() }
        return value
    }

    public func save(to defaults: UserDefaults = .app) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
