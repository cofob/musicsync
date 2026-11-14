import Foundation

/// Audio stream facts from ffprobe.
public struct MediaInfo: Hashable, Sendable {
    public var codec: String
    public var profile: String?
    public var sampleRate: Int
    public var channels: Int
    /// 0 when unknown or not applicable (lossy codecs).
    public var bitsPerSample: Int
    /// Bits per second.
    public var bitRate: Int?
    public var durationSeconds: Double
    public var size: Int64
    /// ffprobe `format_name`, e.g. "mov,mp4,m4a,3gp,3g2,mj2", "mp3", "flac".
    public var container: String

    public init(codec: String, profile: String? = nil, sampleRate: Int, channels: Int, bitsPerSample: Int = 0,
                bitRate: Int? = nil, durationSeconds: Double, size: Int64 = 0, container: String) {
        self.codec = codec
        self.profile = profile
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.bitRate = bitRate
        self.durationSeconds = durationSeconds
        self.size = size
        self.container = container
    }

    /// Parses `ffprobe -show_streams -show_format -of json`.
    public init(ffprobeJSON data: Data) throws {
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard let s = probe.streams.first(where: { $0.codec_type == "audio" }) else { throw TranscodeError.noAudioStream }
        let raw = Int(s.bits_per_raw_sample ?? "") ?? 0
        self.init(
            codec: s.codec_name ?? "", profile: s.profile, sampleRate: Int(s.sample_rate ?? "") ?? 0,
            channels: s.channels ?? 0, bitsPerSample: raw > 0 ? raw : s.bits_per_sample ?? 0,
            bitRate: Int(s.bit_rate ?? "") ?? Int(probe.format.bit_rate ?? ""),
            durationSeconds: Double(s.duration ?? "") ?? Double(probe.format.duration ?? "") ?? 0,
            size: Int64(probe.format.size ?? "") ?? 0, container: probe.format.format_name ?? "")
    }

    private struct Probe: Decodable {
        struct Stream: Decodable {
            var codec_type: String?
            var codec_name: String?
            var profile: String?
            var sample_rate: String?
            var channels: Int?
            var bits_per_sample: Int?
            var bits_per_raw_sample: String?
            var bit_rate: String?
            var duration: String?
        }
        struct Format: Decodable {
            var format_name: String?
            var duration: String?
            var size: String?
            var bit_rate: String?
        }
        var streams: [Stream]
        var format: Format
    }
}
