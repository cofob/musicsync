import Foundation
import Subsonic
import Transcode

/// Output size guess from server metadata; the engine probes the real files.
enum SizeEstimate {
    /// What ffprobe would likely report for the source.
    static func mediaInfo(_ song: Song) -> MediaInfo {
        let suffix = (song.suffix ?? "").lowercased()
        let isMP4 = ["m4a", "mp4", "aac", "m4b"].contains(suffix)
        let codec = isMP4 ? ((song.bitRate ?? 0) > 500 ? "alac" : "aac") : suffix == "ogg" ? "vorbis" : suffix
        return MediaInfo(codec: codec, profile: codec == "aac" ? "LC" : nil, sampleRate: song.samplingRate ?? 44100,
                         channels: song.channelCount ?? 2, bitsPerSample: song.bitDepth ?? 0,
                         bitRate: song.bitRate.map { $0 * 1000 }, durationSeconds: Double(song.duration ?? 0),
                         size: Int64(song.size ?? 0), container: isMP4 ? "mov,mp4,m4a,3gp,3g2,mj2" : suffix)
    }

    static func bytes(_ d: DesiredSong) -> Int64 {
        let size = Int64(d.song.size ?? 0)
        if d.preset.accepts(mediaInfo(d.song)) { return size }
        guard let seconds = d.song.duration, seconds > 0 else { return size }
        let bytes = Double(seconds) * kbps(d.preset) * 125
        return Int64(bytes * 1.02) + 16_384
    }

    private static func kbps(_ preset: Preset) -> Double {
        switch preset.codec {
        case .aac(.cvbr(let k)), .opus(let k): Double(k)
        case .aac(.tvbr(let q)): max(64, 256 - Double(q) * 12)
        case .flac: 0.55 * Double(preset.sampleRate * (preset.bitDepth ?? 16) * 2) / 1000
        }
    }
}
