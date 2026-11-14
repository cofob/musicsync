import Foundation

public enum TranscodeError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case noAudioStream
    case probeFailed(String)
    case ffmpegFailed(status: Int32, stderr: String)
    case invalidMP4(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: "ffmpeg/ffprobe not found"
        case .noAudioStream: "No audio stream"
        case .probeFailed(let m): "ffprobe failed: \(m)"
        case .ffmpegFailed(let s, let m): "ffmpeg exited with \(s): \(m)"
        case .invalidMP4(let m): "Invalid MP4: \(m)"
        }
    }
}

/// Wrapper around the external ffmpeg/ffprobe binaries.
public struct FFmpeg: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Search order: explicit setting (a directory or the ffmpeg binary) → /opt/homebrew/bin → /usr/local/bin → PATH.
    public static func locate(explicitPath: String? = nil) -> FFmpeg? {
        var dirs: [URL] = []
        if let p = explicitPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            let url = URL(fileURLWithPath: p)
            dirs.append(isDir.boolValue ? url : url.deletingLastPathComponent())
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        return dirs.lazy.map { FFmpeg(ffmpeg: $0.appendingPathComponent("ffmpeg"), ffprobe: $0.appendingPathComponent("ffprobe")) }
            .first { $0.isAvailable }
    }

    public var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: ffmpeg.path) && fm.isExecutableFile(atPath: ffprobe.path)
    }

    /// First line of `ffmpeg -version`.
    public func version() async throws -> String {
        let out = try await runProcess(ffmpeg, ["-hide_banner", "-version"])
        return String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
    }

    public func hasEncoder(_ name: String) async throws -> Bool {
        let out = try await runProcess(ffmpeg, ["-hide_banner", "-encoders"])
        return String(decoding: out.stdout, as: UTF8.self).split(separator: "\n")
            .contains { $0.split(separator: " ").dropFirst().first == Substring(name) }
    }

    /// True when the installed ffmpeg has the encoder `preset` needs (e.g. `aac_at`).
    public func supports(_ preset: Preset) async throws -> Bool {
        try await hasEncoder(preset.codec.encoderName)
    }

    public func probe(_ url: URL) async throws -> MediaInfo {
        let out = try await runProcess(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
        guard out.status == 0 else { throw TranscodeError.probeFailed(out.stderr) }
        return try MediaInfo(ffprobeJSON: out.stdout)
    }

    /// True when `source` must be re-encoded for `preset`.
    public static func needsTranscode(source: MediaInfo, preset: Preset) -> Bool { !preset.accepts(source) }

    /// Encodes `input` into `output`; `progress` gets 0...1. Partial output is removed on failure or cancellation.
    public func transcode(input: URL, output: URL, preset: Preset, source: MediaInfo, tags: TrackTags,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let args = Self.arguments(input: input, output: output, preset: preset, source: source, tags: tags)
        let total = source.durationSeconds
        do {
            let result = try await runProcess(ffmpeg, args) { line in
                guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), total > 0 else { return }
                progress(min(max(us / 1e6 / total, 0), 1))
            }
            guard result.status == 0 else { throw TranscodeError.ffmpegFailed(status: result.status, stderr: result.stderr) }
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// ffmpeg arguments (without the executable) for one track.
    public static func arguments(input: URL, output: URL, preset: Preset, source: MediaInfo,
                                 tags: TrackTags) -> [String] {
        var a = ["-y", "-nostdin", "-hide_banner", "-v", "error", "-progress", "pipe:1",
                 "-i", input.path, "-map", "0:a:0", "-map_metadata", "-1"]
        let depth = preset.bitDepth
        if source.sampleRate != preset.sampleRate || depth.map({ source.bitsPerSample > $0 }) == true {
            a += ["-af", "aresample=\(preset.sampleRate):filter_size=64:phase_shift=10:cutoff=0.97:dither_method=triangular_hp"]
        }
        if depth == 16 { a += ["-sample_fmt", "s16"] }
        a += preset.codec.encoderArguments
        for (key, value) in tags.metadata(vorbis: !preset.format.hasPrefix("ipod")) { a += ["-metadata", "\(key)=\(value)"] }
        if preset.format == "ipod" { a += ["-movflags", "+faststart"] }
        a += ["-f", preset.format, output.path]
        return a
    }
}

extension Preset.Codec {
    var encoderName: String {
        switch self {
        case .aac: "aac_at"
        case .flac: "flac"
        case .opus: "libopus"
        }
    }

    var encoderArguments: [String] {
        switch self {
        case .aac(.cvbr(let kbps)):
            ["-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", "\(kbps)k", "-aac_at_quality", "0"]
        case .aac(.tvbr(let quality)):
            ["-c:a", "aac_at", "-aac_at_mode", "vbr", "-q:a", "\(quality)", "-aac_at_quality", "0"]
        case .flac(let level):
            ["-c:a", "flac", "-compression_level", "\(level)"]
        case .opus(let kbps):
            ["-c:a", "libopus", "-b:a", "\(kbps)k", "-vbr", "on"]
        }
    }
}
