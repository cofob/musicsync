import AVFoundation
import Subsonic

/// A downloaded file that is shorter than the song. Kept as done, it would play cut off or not at all.
struct IncompleteDownload: LocalizedError {
    let reason: String
    var errorDescription: String? { "The download is incomplete (\(reason))." }
}

enum DownloadCheck {
    /// Throws when an original file is smaller than the server's size, or the audio cannot be read or is far
    /// shorter than the song. Reads only the file's headers; runs off the main actor.
    static func verify(_ file: URL, song: Song, original: Bool) async throws {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if original, let expected = song.size, expected > 0, size < Int64(expected) * 99 / 100 {
            throw IncompleteDownload(reason: "\(size) of \(expected) bytes")
        }
        guard let duration = try? await AVURLAsset(url: file).load(.duration), duration.isNumeric else {
            throw IncompleteDownload(reason: "the audio cannot be read")
        }
        if let expected = song.duration, expected > 5, duration.seconds < Double(expected) * 0.8 {
            throw IncompleteDownload(reason: "\(Int(duration.seconds)) of \(expected) seconds")
        }
    }
}
