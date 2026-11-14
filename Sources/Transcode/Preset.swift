import Foundation

/// Output recipe: codec, container and which sources may be copied unchanged.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public enum Target: String, Codable, Sendable {
        case stock    // iTunesDB on the iPod
        case rockbox  // plain folder
    }

    public enum AACMode: Codable, Hashable, Sendable {
        case cvbr(bitrateKbps: Int)
        case tvbr(quality: Int)  // aac_at VBR quality, 0 (best) ... 14
    }

    public enum Codec: Codable, Hashable, Sendable {
        case aac(AACMode)
        case flac(compressionLevel: Int)
        case opus(bitrateKbps: Int)
    }

    /// Source that can be copied as is. Nil limits are not checked.
    public struct PassthroughRule: Codable, Hashable, Sendable {
        public var codec: String  // ffprobe codec_name
        public var profile: String?
        public var container: String?  // substring of ffprobe format_name
        public var maxBitrateKbps: Int?
        public var maxSampleRate: Int?
        public var maxBitsPerSample: Int?

        public init(codec: String, profile: String? = nil, container: String? = nil, maxBitrateKbps: Int? = nil,
                    maxSampleRate: Int? = nil, maxBitsPerSample: Int? = nil) {
            self.codec = codec
            self.profile = profile
            self.container = container
            self.maxBitrateKbps = maxBitrateKbps
            self.maxSampleRate = maxSampleRate
            self.maxBitsPerSample = maxBitsPerSample
        }
    }

    public var id: String
    public var name: String
    public var target: Target
    public var codec: Codec
    public var sampleRate: Int
    /// Forced sample depth (dithered); nil keeps the encoder default.
    public var bitDepth: Int?
    public var fileExtension: String
    /// ffmpeg muxer name (`-f`).
    public var format: String
    /// Bump to force re-encoding of already synced tracks.
    public var version: Int
    public var passthrough: [PassthroughRule]

    public init(id: String, name: String, target: Target, codec: Codec, sampleRate: Int = 44100, bitDepth: Int?,
                fileExtension: String, format: String, version: Int = 1, passthrough: [PassthroughRule] = []) {
        self.id = id
        self.name = name
        self.target = target
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileExtension = fileExtension
        self.format = format
        self.version = version
        self.passthrough = passthrough
    }

    public static let stockAAC = Preset(
        id: "stock-aac", name: "iPod AAC 256k", target: .stock, codec: .aac(.cvbr(bitrateKbps: 256)),
        bitDepth: 16, fileExtension: "m4a", format: "ipod",
        passthrough: [
            PassthroughRule(codec: "mp3", container: "mp3", maxSampleRate: 48000),
            PassthroughRule(codec: "aac", profile: "LC", container: "mp4", maxBitrateKbps: 320, maxSampleRate: 48000),
        ])

    public static let rockboxFLAC = Preset(
        id: "rockbox-flac", name: "FLAC 16-bit", target: .rockbox, codec: .flac(compressionLevel: 8),
        bitDepth: 16, fileExtension: "flac", format: "flac",
        passthrough: [PassthroughRule(codec: "flac", container: "flac", maxSampleRate: 44100, maxBitsPerSample: 16)])

    public static let rockboxOpus = Preset(
        id: "rockbox-opus", name: "Opus 128k", target: .rockbox, codec: .opus(bitrateKbps: 128),
        sampleRate: 48000, bitDepth: nil, fileExtension: "opus", format: "opus")

    public static let builtIns: [Preset] = [stockAAC, rockboxFLAC, rockboxOpus]

    /// True when `source` can be copied without re-encoding (never more than stereo).
    public func accepts(_ source: MediaInfo) -> Bool {
        source.channels <= 2 && passthrough.contains { rule in
            source.codec == rule.codec
                && rule.profile.map { $0 == source.profile } ?? true
                && rule.container.map { source.container.contains($0) } ?? true
                && rule.maxBitrateKbps.map { (source.bitRate ?? 0) <= $0 * 1000 } ?? true
                && rule.maxSampleRate.map { source.sampleRate <= $0 } ?? true
                && rule.maxBitsPerSample.map { source.bitsPerSample <= $0 } ?? true
        }
    }
}
