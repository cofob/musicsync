import Device
import Foundation
import ITunesDB
import Subsonic
import Transcode

/// A song file ready to be copied to the device.
struct Prepared: Sendable {
    var file: URL
    var source: MediaInfo
    var output: MediaInfo
    var transcoded: Bool
    var gapless: GaplessInfo?
    var ext: String
    var hasLyrics = false
}

/// download -> probe -> passthrough or transcode -> probe. Runs in parallel workers; touches only the work dir.
struct TransferPipeline: Sendable {
    let client: SubsonicClient
    let ffmpeg: FFmpeg
    let workDir: URL
    /// Adds lyrics to stock iPod m4a files.
    var lyrics = false

    func prepare(_ d: DesiredSong, stage: @escaping @Sendable (ItemStage) -> Void) async throws -> Prepared {
        let expected = Int64(d.song.size ?? 0)
        stage(.downloading(0, expected))
        let downloaded = try await client.download(id: d.song.id) { done, total in
            stage(.downloading(done, total > 0 ? total : expected))
        }
        var temporary = [downloaded]
        do {
            let source = try await ffmpeg.probe(downloaded)
            var file = downloaded
            var transcoded = false
            let needsTranscode = FFmpeg.needsTranscode(source: source, preset: d.preset)
            let ext = needsTranscode ? d.preset.fileExtension : Self.passthroughExtension(source, preset: d.preset)
            let text = lyrics && d.preset.target == .stock && ext == "m4a" ? await client.plainLyrics(for: d.song) : nil
            if needsTranscode {
                stage(.transcoding(0))
                file = workDir.appendingPathComponent("\(UUID().uuidString).\(d.preset.fileExtension)")
                temporary.append(file)
                try await ffmpeg.transcode(input: downloaded, output: file, preset: d.preset, source: source, tags: d.tags,
                                           lyrics: text) { stage(.transcoding($0)) }
                transcoded = true
            } else if let text {
                file = workDir.appendingPathComponent("\(UUID().uuidString).m4a")
                temporary.append(file)
                try await ffmpeg.addLyrics(text, input: downloaded, output: file)
            }
            let output = try await ffmpeg.probe(file)
            var gapless: GaplessInfo?
            if ext == "m4a" {
                let exact = transcoded ? Int((source.durationSeconds * Double(output.sampleRate)).rounded()) : nil
                gapless = try? Gapless.read(from: file, exactSampleCount: exact)
            }
            // The caller removes `file`; only the download is dropped here when it is not the result.
            if file != downloaded { try? FileManager.default.removeItem(at: downloaded) }
            return Prepared(file: file, source: source, output: output, transcoded: transcoded, gapless: gapless, ext: ext,
                            hasLyrics: text != nil)
        } catch {
            for url in temporary { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Extension for a file copied unchanged, from its container.
    static func passthroughExtension(_ info: MediaInfo, preset: Preset) -> String {
        if info.container.contains("mp3") { return "mp3" }
        if info.container.contains("mp4") || info.container.contains("m4a") { return "m4a" }
        if info.container.contains("flac") { return "flac" }
        if info.container.contains("ogg") { return preset.fileExtension == "opus" ? "opus" : "ogg" }
        return preset.fileExtension
    }
}

/// Copies files to the device one at a time and hands out unused names.
actor DeviceCopier {
    private let device: IPodDevice
    private var used: Set<String>

    init(device: IPodDevice, used: Set<String>) {
        self.device = device
        self.used = used
    }

    /// Copies into `iPod_Control/Music/Fxx/XXXX.ext`; returns the relative path.
    func copyStock(_ file: URL, ext: String) throws -> String {
        let path = device.layout.newMusicFilePath(ext: ext, existing: used)
        used.insert(path)
        try copy(file, to: path)
        return path
    }

    /// Copies to `wanted` (or `wanted (2)`, ...) unless the path is `replacing`, which is overwritten.
    func copyRockbox(_ file: URL, wanted: String, replacing: String?) throws -> String {
        let folded = Set(used.map { $0.lowercased() })
        let url = URL(fileURLWithPath: wanted)
        let stem = wanted.dropLast(url.pathExtension.isEmpty ? 0 : url.pathExtension.count + 1)
        var path = wanted, n = 1
        while path != replacing,
              folded.contains(path.lowercased()) || FileManager.default.fileExists(atPath: device.mountURL.appendingPathComponent(path).path) {
            n += 1
            path = "\(stem) (\(n))" + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
        }
        used.insert(path)
        try copy(file, to: path, overwrite: path == replacing)
        return path
    }

    private func copy(_ file: URL, to relativePath: String, overwrite: Bool = false) throws {
        let fm = FileManager.default
        let dest = device.mountURL.appendingPathComponent(relativePath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if overwrite { try? fm.removeItem(at: dest) }
        do {
            try fm.copyItem(at: file, to: dest)
            let want = try fm.attributesOfItem(atPath: file.path)[.size] as? Int64
            let got = try fm.attributesOfItem(atPath: dest.path)[.size] as? Int64
            guard want == got else { throw CocoaError(.fileWriteOutOfSpace) }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }
}
