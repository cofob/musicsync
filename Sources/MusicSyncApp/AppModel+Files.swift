import AppKit
import CoreTransferable
import Subsonic
import Transcode
import UniformTypeIdentifiers

/// Which file of a song to save or share: the original, or a server conversion.
enum SongFileVersion: CaseIterable {
    case original, mp3, aac

    var title: String {
        switch self {
        case .original: "Original"
        case .mp3: "MP3"
        case .aac: "AAC"
        }
    }

    /// Server `format`; nil for the original file.
    var format: String? {
        switch self {
        case .original: nil
        case .mp3: "mp3"
        case .aac: "aac"
        }
    }
}

/// Song files for "Save to Folder" and "Share File". Failures go to `report(_:)`.
extension AppModel {
    /// A temporary file "Artist - Title.ext" of the song. The original comes from the offline download when it has one.
    func songFile(_ song: Song, _ version: SongFileVersion) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = (song.suffix ?? "mp3").lowercased()
        if version == .original, downloads.entries[song.id]?.format?.lowercased() == suffix, let local = downloads.fileURL(song.id) {
            let file = dir.appendingPathComponent(Self.fileName(song, ext: suffix))
            try FileManager.default.copyItem(at: local, to: file)
            return file
        }
        guard let client else { throw URLError(.notConnectedToInternet) }
        let maxBitRate = version == .original ? nil : downloads.settings.maxBitRate
        let downloaded = try await client.download(id: song.id, format: version.format, maxBitRate: maxBitRate)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        switch version {
        case .original, .mp3:
            let file = dir.appendingPathComponent(Self.fileName(song, ext: version == .mp3 ? "mp3" : suffix))
            try FileManager.default.moveItem(at: downloaded, to: file)
            return file
        case .aac:
            // The server sends ADTS AAC: put into m4a without encoding again, when ffmpeg is there.
            if let ffmpeg = FFmpeg.locate(explicitPath: syncSettings.ffmpegPath) {
                let file = dir.appendingPathComponent(Self.fileName(song, ext: "m4a"))
                try await ffmpeg.remux(input: downloaded, output: file)
                return file
            }
            let file = dir.appendingPathComponent(Self.fileName(song, ext: "aac"))
            try FileManager.default.moveItem(at: downloaded, to: file)
            return file
        }
    }

    /// Asks for a folder, then writes the files one by one. A name that is taken gets " 2", " 3"…
    func saveToFolder(_ songs: [Song], _ version: SongFileVersion) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Save \(songs.count == 1 ? "the song" : "\(songs.count) songs") (\(version.title))"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            var saved: [URL] = []
            for song in songs {
                do {
                    let file = try await songFile(song, version)
                    let target = Self.free(folder.appendingPathComponent(file.lastPathComponent))
                    try FileManager.default.moveItem(at: file, to: target)
                    saved.append(target)
                } catch { report(error) }
            }
            if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        }
    }

    /// "Artist - Title.ext", without the characters a file name cannot hold.
    static func fileName(_ song: Song, ext: String) -> String {
        let name = [song.artistName, song.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + ext
    }

    /// The URL, or the first "name N.ext" next to it that does not exist.
    private static func free(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// What `ShareLink` hands to a sharing service. The file is made only when a service is picked.
struct SharedSongFile: Transferable {
    let song: Song
    let version: SongFileVersion
    let model: AppModel

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { (item: SharedSongFile) in
            SentTransferredFile(try await item.model.songFile(item.song, item.version))
        }
    }
}
