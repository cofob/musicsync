import AVFoundation
@testable import Playback
import Subsonic
import Testing

/// AutoMix measured on real songs of the public demo server, streamed as the app streams them. A dev tool, not a
/// test: it needs the network and runs for minutes, so it runs only with `MUSICSYNC_MEASURE_DEMO=1`. Downloads are kept
/// in `MUSICSYNC_MEASURE_CACHE` (else a temp folder); mixed WAV files go to `MUSICSYNC_CAPTURE_DIR`. Plays only (no
/// stars, ratings or play queue changes).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MUSICSYNC_MEASURE_DEMO"] == "1"))
struct DemoMixTests {
    private let client = SubsonicClient(baseURL: URL(string: "https://demo.navidrome.org")!, username: "demo", password: "demo")
    private let settings = PlaybackSettings()
    private let cache = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUSICSYNC_MEASURE_CACHE"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-measure").path, isDirectory: true)

    private struct Candidate {
        var song: Subsonic.Song
        var file: URL
        var analysis: SongAnalysis
    }

    /// Songs of a few albums, two per album at most, with their stream saved and analyzed as AutoMix does it.
    private func candidates(count: Int) async throws -> [Candidate] {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let albums = try await client.getAlbumList2(type: "alphabeticalByName", size: 60)
        var out: [Candidate] = []
        for album in albums where out.count < count {
            let songs = (try await client.getAlbum(id: album.id).song ?? []).filter { ($0.duration ?? 0) >= 90 && ($0.duration ?? 0) <= 420 }
            for song in songs.prefix(2) {
                let stream = settings.stream(for: song)
                let file = cache.appendingPathComponent(song.id)
                if !FileManager.default.fileExists(atPath: file.path) {
                    let url = client.streamURL(id: song.id, format: stream.format, maxBitRate: stream.maxBitRate)
                    let temp = try await AnalysisQueue.download(url, session: .shared, maxBytes: 60_000_000)
                    try FileManager.default.moveItem(at: temp, to: file)
                }
                let samples = try await PCMReader.samples(of: file, contentType: stream.contentType)
                out.append(Candidate(song: song, file: file, analysis: SongAnalysis(samples: samples)))
            }
        }
        return out
    }

    /// A cue as `Player.cue(at:)` makes it for a stream.
    private func cue(_ song: Subsonic.Song) -> Mixer.Cue {
        let stream = settings.stream(for: song)
        let url = client.streamURL(id: song.id, format: stream.format, maxBitRate: stream.maxBitRate)
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: stream.contentType.map { [AVURLAssetOverrideMIMETypeKey: $0] }))
        item.audioTimePitchAlgorithm = .spectral
        return Mixer.Cue(item: item, gain: settings.gain(for: song, inAlbumOrder: false))
    }

    /// The decoded file as mono at 44.1 kHz from `start` for `length` seconds.
    private func source(_ c: Candidate, from start: Double, length: Double) async throws -> [Float] {
        let all = try await PCMReader.samples(of: c.file, contentType: settings.stream(for: c.song).contentType, sampleRate: 44100)
        let lo = min(max(Int(start * 44100), 0), all.count), hi = min(lo + Int(length * 44100), all.count)
        return Array(all[lo..<hi])
    }

    @Test func autoMixOnDemoSongs() async throws {
        let songs = try await candidates(count: 24)
        var beat: [(Candidate, Candidate, Transition)] = [], fade: [(Candidate, Candidate, Transition)] = []
        var used = Set<String>()
        for a in songs {
            for b in songs where a.song.id != b.song.id && a.song.albumId != b.song.albumId && !used.contains(a.song.id) && !used.contains(b.song.id) {
                guard let t = AutoMix.plan(from: a.analysis, to: b.analysis, canSeek: !settings.stream(for: b.song).isConverted) else { continue }
                let matched = AutoMix.tempoMatch(a.analysis, b.analysis) != nil
                if matched, beat.count < 3 { beat.append((a, b, t)) } else if !matched, fade.count < 2 { fade.append((a, b, t)) } else { continue }
                used.formUnion([a.song.id, b.song.id])
                break
            }
        }
        print("DEMO \(songs.count) songs, \(beat.count) beat-matched and \(fade.count) faded pairs")
        for (n, (a, b, t)) in (beat + fade).enumerated() {
            let start = max(t.at - 8, 0)
            let run = MixRun(a: MixRun.Song(cue: cue(a.song), source: try await source(a, from: start, length: 40), sourceStart: start),
                             b: MixRun.Song(cue: cue(b.song), source: try await source(b, from: t.offset, length: 40), sourceStart: t.offset),
                             transition: t, bpm: n < beat.count ? a.analysis.bpm : nil)
            let result = try await run.run(wav: "demo-\(n + 1)-\(n < beat.count ? "beat" : "fade")")
            print(String(format: "DEMO %@ %@ → %@: %.1f → %.1f bpm (strength %.2f/%.2f), at %.1f s, offset %.1f s, %.1f s, rate %.4f",
                         n < beat.count ? "beat" : "fade", a.song.title, b.song.title, a.analysis.bpm, b.analysis.bpm,
                         a.analysis.beatStrength, b.analysis.beatStrength, t.at, t.offset, t.duration, t.rate))
            print("DEMO   \(result.summary)")
        }
    }
}
